import CryptoKit
import Foundation
import Network

/// Receives an IPA from the paired EmLoad iOS app and installs it through USB.
/// Pairing-file private keys authenticate requests; no open upload endpoint is exposed.
public final class IPAImportServer: @unchecked Sendable {
    public static let shared = IPAImportServer()
    public static let serviceType = "_emload._tcp"

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.emiry.EmLoadServer.ipa-import", qos: .userInitiated)
    private var listener: NWListener?
    private var usedNonces = Set<String>()

    private init() {}

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else { return }

        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: "EmLoadServer", type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            Task { await self.handle(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("EmLoadServer IPA import listener failed: \(error.localizedDescription)\n", stderr)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        print("EmLoadServer IPA import Bonjour service started.")
    }

    public func stop() {
        lock.lock()
        let current = listener
        listener = nil
        usedNonces.removeAll()
        lock.unlock()
        current?.cancel()
    }

    private func handle(_ connection: NWConnection) async {
        defer { connection.cancel() }
        let io = IPAConnectionIO(connection: connection)
        var temporaryIPA: URL?
        defer {
            if let temporaryIPA { try? FileManager.default.removeItem(at: temporaryIPA) }
        }

        do {
            var buffer = Data()
            var parsed: (HTTPRequestHead, Int)?
            while parsed == nil {
                guard buffer.count <= 16_384, let chunk = try await io.receive() else {
                    throw IPAImportError.badRequest
                }
                buffer.append(chunk)
                parsed = try HTTPHeadParser.parse(buffer)
            }
            guard let (head, bodyStart) = parsed else { throw IPAImportError.badRequest }
            let path = head.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            guard path == "/v1/identity" || path == "/v1/install" else {
                try await io.send(response(status: 404, message: "EmLoad import endpoint not found."))
                return
            }
            guard (path == "/v1/identity" && head.method == "GET")
                    || (path == "/v1/install" && head.method == "POST") else {
                try await io.send(response(status: 405, message: "Unsupported request method."))
                return
            }

            let udid = head.headers["x-emload-udid"] ?? ""
            let nonce = head.headers["x-emload-nonce"] ?? ""
            let length = Int(head.headers["content-length"] ?? (head.method == "GET" ? "0" : "-1")) ?? -1
            guard udid.range(of: #"^[A-Fa-f0-9]{8,40}(-[A-Fa-f0-9]{8,16})?$"#, options: .regularExpression) != nil,
                  nonce.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil,
                  length >= 0,
                  length <= 1_073_741_824,
                  let pairingKey = try AppleAccountService.ipaImportPairingKey(for: udid),
                  Self.verifyHeaderAuthentication(head: head, path: path, udid: udid, nonce: nonce, length: length, pairingKey: pairingKey),
                  self.consume(nonce) else {
                try await io.send(response(status: 401, message: "This request is not from a paired EmLoad iOS device."))
                return
            }

            let ipaURL: URL
            let bodyDigest: Data
            if path == "/v1/install" {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("EmLoad-Import-\(UUID().uuidString).ipa")
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw IPAImportError.storage
                }
                temporaryIPA = url
                bodyDigest = try await writeBody(
                    buffer: Data(buffer.dropFirst(bodyStart)),
                    contentLength: length,
                    to: url,
                    io: io
                )
                ipaURL = url
            } else {
                guard length == 0 else { throw IPAImportError.badRequest }
                bodyDigest = Data(SHA256.hash(data: Data()))
                ipaURL = URL(fileURLWithPath: "/dev/null")
            }

            guard Self.verifyBodyAuthentication(head: head, path: path, udid: udid, nonce: nonce, digest: bodyDigest, pairingKey: pairingKey) else {
                try await io.send(response(status: 401, message: "The IPA upload failed its pairing integrity check."))
                return
            }

            if path == "/v1/identity" {
                let identity = try await EmLoadiOSSetup.identityTransfer()
                let payload = try JSONEncoder().encode(identity)
                let sealed = try IPAImportCrypto.seal(payload, pairingKey: pairingKey, udid: udid)
                let json = try JSONSerialization.data(withJSONObject: ["sealedIdentity": sealed.base64EncodedString()])
                try await io.send(response(status: 200, contentType: "application/json", body: json))
            } else {
                try await EmLoadiOSSetup.installIPA(at: ipaURL, for: udid)
                let json = try JSONSerialization.data(withJSONObject: ["message": "IPA signed and installed."])
                try await io.send(response(status: 200, contentType: "application/json", body: json))
            }
        } catch {
            fputs("EmLoadServer IPA import request failed: \(error.localizedDescription)\n", stderr)
            let message = error.localizedDescription
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            try? await io.send(response(status: 400, message: message))
        }
    }

    private func writeBody(buffer: Data, contentLength: Int, to url: URL, io: IPAConnectionIO) async throws -> Data {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var written = 0

        func append(_ chunk: Data) throws {
            let remaining = contentLength - written
            guard remaining > 0 else { return }
            let part = chunk.prefix(remaining)
            guard !part.isEmpty else { return }
            try handle.write(contentsOf: part)
            hasher.update(data: part)
            written += part.count
        }

        try append(buffer)
        while written < contentLength {
            guard let chunk = try await io.receive() else { throw IPAImportError.badRequest }
            try append(chunk)
        }
        return Data(hasher.finalize())
    }

    private func consume(_ nonce: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !usedNonces.contains(nonce) else { return false }
        usedNonces.insert(nonce)
        if usedNonces.count > 4096 {
            usedNonces.removeAll(keepingCapacity: true)
            usedNonces.insert(nonce)
        }
        return true
    }

    private static func verifyHeaderAuthentication(
        head: HTTPRequestHead,
        path: String,
        udid: String,
        nonce: String,
        length: Int,
        pairingKey: Data
    ) -> Bool {
        guard let encoded = head.headers["x-emload-auth"],
              let signature = Data(base64Encoded: encoded) else { return false }
        let message = Data("EmLoadIPA-v1\n\(head.method)\n\(path)\n\(udid.lowercased())\n\(nonce)\n\(length)".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: message,
            using: IPAImportCrypto.authenticationKey(pairingKey: pairingKey, udid: udid)
        )
    }

    private static func verifyBodyAuthentication(
        head: HTTPRequestHead,
        path: String,
        udid: String,
        nonce: String,
        digest: Data,
        pairingKey: Data
    ) -> Bool {
        guard let encoded = head.headers["x-emload-body-auth"],
              let signature = Data(base64Encoded: encoded) else { return false }
        var message = Data("EmLoadIPA-body-v1\n\(path)\n\(udid.lowercased())\n\(nonce)\n".utf8)
        message.append(digest)
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: message,
            using: IPAImportCrypto.authenticationKey(pairingKey: pairingKey, udid: udid)
        )
    }

    private func response(status: Int, message: String) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data("{}".utf8)
        return response(status: status, contentType: "application/json", body: body)
    }

    private func response(status: Int, contentType: String, body: Data) -> Data {
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Error")
        var result = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        result.append(body)
        return result
    }
}

enum IPAImportCrypto {
    static func authenticationKey(pairingKey: Data, udid: String) -> SymmetricKey {
        let base = SymmetricKey(data: Data(SHA256.hash(data: pairingKey)))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: base,
            salt: Data(udid.lowercased().utf8),
            info: Data("EmLoad IPA import authentication v1".utf8),
            outputByteCount: 32
        )
    }

    static func seal(_ data: Data, pairingKey: Data, udid: String) throws -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(SHA256.hash(data: pairingKey))),
            salt: Data(udid.lowercased().utf8),
            info: Data("EmLoad IPA identity transfer v1".utf8),
            outputByteCount: 32
        )
        let box = try AES.GCM.seal(data, using: key, authenticating: Data(udid.lowercased().utf8))
        guard let combined = box.combined else { throw IPAImportError.crypto }
        return combined
    }
}

private enum IPAImportError: LocalizedError {
    case badRequest
    case storage
    case crypto

    var errorDescription: String? {
        switch self {
        case .badRequest: return "The iOS IPA upload was incomplete or malformed."
        case .storage: return "EmLoadServer could not create a temporary IPA file."
        case .crypto: return "EmLoadServer could not protect the identity transfer."
        }
    }
}

private final class IPAConnectionIO: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.emiry.EmLoadServer.ipa-import.socket")

    init(connection: NWConnection) { self.connection = connection }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        }
    }

    func receive() async throws -> Data? {
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error); return }
                    if let data, !data.isEmpty { continuation.resume(returning: data); return }
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
            if let chunk, chunk.isEmpty { continue }
            return chunk
        }
    }
}
