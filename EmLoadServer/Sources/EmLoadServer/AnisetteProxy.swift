import CommonCrypto
import Foundation
import Network
import Security

/// Forwards SideStore anisette v3 traffic.
///
/// Callers send their own identifier and adi.pb. This process does not read or
/// write the Apple ID session, development certificate, or anisette identity
/// stored in the Mac Keychain.
struct ProxyCommand: Equatable {
    var upstream: URL
    var bindHost: String
    var port: UInt16
    var token: String?

    static let defaultPort: UInt16 = 1741
    static let defaultBindHost = "0.0.0.0"

    static func parse(arguments: [String]) throws -> ProxyCommand {
        var upstream = URL(string: AnisetteServerRegistry.defaultAddress)
        var bindHost = defaultBindHost
        var port = defaultPort
        var token: String?
        var open = false
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--open":
                open = true
                index += 1
            case "--upstream", "--bind", "--port", "--token":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw ProxyCommandError.missingValue(option)
                }
                let value = arguments[index + 1]
                switch option {
                case "--upstream":
                    guard upstream == URL(string: AnisetteServerRegistry.defaultAddress) else {
                        throw ProxyCommandError.duplicateOption(option)
                    }
                    upstream = try Self.validatedUpstream(value)
                case "--bind":
                    guard bindHost == defaultBindHost else { throw ProxyCommandError.duplicateOption(option) }
                    guard !value.isEmpty, !value.contains("/") else {
                        throw ProxyCommandError.invalidBindHost
                    }
                    bindHost = value
                case "--port":
                    guard port == defaultPort else { throw ProxyCommandError.duplicateOption(option) }
                    guard let parsed = UInt16(value), parsed > 0 else {
                        throw ProxyCommandError.invalidPort
                    }
                    port = parsed
                case "--token":
                    guard token == nil else { throw ProxyCommandError.duplicateOption(option) }
                    guard Self.isPathToken(value) else { throw ProxyCommandError.invalidToken }
                    token = value
                default:
                    break
                }
                index += 2
            default:
                throw ProxyCommandError.unknownOption(option)
            }
        }

        if open && token != nil {
            throw ProxyCommandError.conflictingAccess
        }
        guard let upstream else { throw ProxyCommandError.invalidUpstream }
        return ProxyCommand(
            upstream: upstream,
            bindHost: bindHost,
            port: port,
            token: open ? nil : (token ?? Self.makeToken())
        )
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isPathToken(_ token: String) -> Bool {
        guard (16...128).contains(token.count) else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            CharacterSet.anisetteProxyToken.contains(scalar)
        }
    }

    static func clientURL(bindHost: String, port: UInt16, token: String?) -> String {
        let host = (bindHost == "0.0.0.0" || bindHost == "::") ? "<this-mac>" : bindHost
        let suffix = token.map { "/\($0)" } ?? ""
        return "http://\(host):\(port)\(suffix)"
    }

    private static func validatedUpstream(_ value: String) throws -> URL {
        guard let server = AnisetteServerRegistry.customEndpoint(from: value) else {
            throw ProxyCommandError.invalidUpstream
        }
        guard let url = server.endpoint else { throw ProxyCommandError.invalidUpstream }
        return url
    }
}

enum ProxyCommandError: LocalizedError {
    case unknownOption(String)
    case missingValue(String)
    case duplicateOption(String)
    case invalidUpstream
    case invalidBindHost
    case invalidPort
    case invalidToken
    case conflictingAccess

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option):
            return "Unknown option: \(option)."
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .duplicateOption(let option):
            return "Option \(option) may only be provided once."
        case .invalidUpstream:
            return "The upstream anisette server must be an http or https URL without a username, password, or fragment."
        case .invalidBindHost:
            return "The bind address must be a host such as 0.0.0.0 or 127.0.0.1."
        case .invalidPort:
            return "The port must be an integer from 1 to 65535."
        case .invalidToken:
            return "The token must be 16 to 128 characters and use only letters, numbers, hyphens, and underscores."
        case .conflictingAccess:
            return "Use either --token or --open, not both."
        }
    }
}

enum ProxyPathDecision: Equatable {
    case http(String)
    case webSocket(String)
    case unauthorized
    case notFound
}

enum AnisetteProxyRouter {
    static let clientInfo = "/v3/client_info"
    static let getHeaders = "/v3/get_headers"
    static let provisioningSession = "/v3/provisioning_session"

    static func decide(method: String, target: String, token: String?) -> ProxyPathDecision {
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        guard !path.contains("\\"), !path.contains("%") else { return .notFound }
        let stripped: String
        if let token {
            let prefix = "/" + token
            guard path == prefix || path.hasPrefix(prefix + "/") else { return .unauthorized }
            let remainder = String(path.dropFirst(prefix.count))
            stripped = remainder.isEmpty ? "/" : remainder
        } else {
            stripped = path.isEmpty ? "/" : path
        }

        switch (method.uppercased(), stripped) {
        case ("GET", clientInfo):
            return .http(clientInfo)
        case ("POST", getHeaders):
            return .http(getHeaders)
        case ("GET", provisioningSession):
            return .webSocket(provisioningSession)
        default:
            return .notFound
        }
    }

    static func upstreamURL(base: URL, path: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum WebSocketHandshake {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func acceptKey(for clientKey: String) -> String {
        let input = Data((clientKey + guid).utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        input.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(input.count), &digest)
        }
        return Data(digest).base64EncodedString()
    }

    static func response(clientKey: String) -> Data {
        let text = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKey(for: clientKey))\r
        \r

        """
        return Data(text.utf8)
    }
}

struct WebSocketFrame: Equatable {
    var opcode: UInt8
    var payload: Data
}

struct WebSocketFrameDecoder {
    private var buffer = Data()
    private let maxPayload: Int

    init(maxPayload: Int = 1_048_576) {
        self.maxPayload = maxPayload
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() throws -> WebSocketFrame? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[0]
        let second = buffer[1]
        let opcode = first & 0x0F
        let masked = second & 0x80 != 0
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for index in 2..<10 {
                length = (length << 8) | Int(buffer[index])
            }
            offset = 10
        }
        guard length >= 0, length <= maxPayload else {
            throw ProxyServeError.messageTooLarge
        }
        let maskLength = masked ? 4 : 0
        guard buffer.count >= offset + maskLength + length else { return nil }
        let mask = masked ? Array(buffer[offset..<(offset + 4)]) : []
        let start = offset + maskLength
        var payload = Data(buffer[start..<(start + length)])
        if masked {
            for index in payload.indices {
                payload[index] ^= mask[(index - payload.startIndex) % 4]
            }
        }
        buffer.removeFirst(start + length)
        guard first & 0x80 != 0 else { throw ProxyServeError.fragmentedFrame }
        return WebSocketFrame(opcode: opcode, payload: payload)
    }
}

enum WebSocketFrames {
    static func serverFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            var remaining = count
            var bytes = [UInt8](repeating: 0, count: 8)
            for index in stride(from: 7, through: 0, by: -1) {
                bytes[index] = UInt8(remaining & 0xFF)
                remaining >>= 8
            }
            frame.append(contentsOf: bytes)
        }
        frame.append(payload)
        return frame
    }
}

struct HTTPRequestHead {
    var method: String
    var target: String
    var headers: [String: String]
}

enum HTTPHeadParser {
    static func parse(_ data: Data) throws -> (HTTPRequestHead, Int)? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<marker.lowerBound)
        guard headerData.count <= 16_384 else { throw ProxyServeError.headersTooLarge }
        guard let text = String(data: headerData, encoding: .utf8) else {
            throw ProxyServeError.badRequest
        }
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.first else { throw ProxyServeError.badRequest }
        let parts = start.split(separator: " ")
        guard parts.count >= 2 else { throw ProxyServeError.badRequest }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw ProxyServeError.badRequest }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (
            HTTPRequestHead(method: String(parts[0]), target: String(parts[1]), headers: headers),
            marker.upperBound
        )
    }
}

enum ProxyServeError: Error {
    case badRequest
    case headersTooLarge
    case bodyTooLarge
    case messageTooLarge
    case fragmentedFrame
    case upstream(String)
}

final class AnisetteProxy {
    let command: ProxyCommand
    private let session: URLSession

    init(command: ProxyCommand, session: URLSession = .shared) {
        self.command = command
        self.session = session
    }

    func run() async throws {
        guard let port = NWEndpoint.Port(rawValue: command.port) else {
            throw ProxyCommandError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if command.bindHost == "127.0.0.1" || command.bindHost == "localhost" {
            parameters.requiredInterfaceType = .loopback
        }
        let listener = try NWListener(using: parameters, on: port)
        let failure = ProxyFailure()
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                failure.set(error)
            }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                await self.serve(connection)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        print(banner(), terminator: "")
        while failure.current() == nil {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        listener.cancel()
        if let error = failure.current() {
            throw error
        }
    }

    func banner() -> String {
        let access = command.token == nil
            ? "This listener is open. Anyone who can reach the port can use the upstream anisette server."
            : "Other people use the server URL below with their own EmLoad or emloadserver. It is not an Apple ID or a certificate."
        return """
        EmLoad anisette proxy is listening.
        \(access)
        Requests are forwarded with the caller's own identifier. This process does not use the Apple ID, signing certificate, or anisette identity saved on this Mac.
        Upstream: \(command.upstream.absoluteString)
        Server URL: \(ProxyCommand.clientURL(bindHost: command.bindHost, port: command.port, token: command.token))

        """
    }

    private func serve(_ connection: NWConnection) async {
        let io = ConnectionIO(connection: connection)
        do {
            try await serveHTTP(io)
        } catch {
            await sendStatus(400, message: "Bad request.", over: io)
        }
        connection.cancel()
    }

    private func serveHTTP(_ io: ConnectionIO) async throws {
        var buffer = Data()
        while try HTTPHeadParser.parse(buffer) == nil {
            guard buffer.count <= 16_384, let chunk = try await io.receive() else {
                throw ProxyServeError.badRequest
            }
            buffer.append(chunk)
        }
        guard let (head, bodyStart) = try HTTPHeadParser.parse(buffer) else {
            throw ProxyServeError.badRequest
        }
        var body = Data(buffer.dropFirst(bodyStart))
        let length = Int(head.headers["content-length"] ?? "") ?? 0
        guard length >= 0, length <= 1_048_576 else { throw ProxyServeError.bodyTooLarge }
        while body.count < length {
            guard let chunk = try await io.receive() else { throw ProxyServeError.badRequest }
            body.append(chunk)
        }
        let leftover = Data(body.dropFirst(length))
        if body.count > length {
            body = body.prefix(length)
        }

        switch AnisetteProxyRouter.decide(method: head.method, target: head.target, token: command.token) {
        case .unauthorized:
            await sendStatus(401, message: "This proxy requires its server token in the URL path.", over: io)
        case .notFound:
            await sendStatus(404, message: "This proxy only forwards v3 client_info, get_headers, and provisioning_session.", over: io)
        case .http(let path):
            try await forwardHTTP(head: head, body: body, path: path, io: io)
        case .webSocket(let path):
            try await forwardWebSocket(head: head, path: path, io: io, alreadyReceived: leftover)
        }
    }

    private func forwardHTTP(head: HTTPRequestHead, body: Data, path: String, io: ConnectionIO) async throws {
        guard let url = AnisetteProxyRouter.upstreamURL(base: command.upstream, path: path) else {
            throw ProxyServeError.upstream("invalid upstream URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = head.method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !body.isEmpty {
            request.httpBody = body
        }
        if let contentType = head.headers["content-type"] {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("EmLoadServer-Proxy", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if path == AnisetteProxyRouter.getHeaders {
                let payload = Data("{\"result\":\"GetHeadersError\",\"message\":\"The anisette proxy could not reach its upstream server.\"}".utf8)
                try await io.send(httpResponse(status: 200, contentType: "application/json", body: payload))
                return
            }
            await sendStatus(502, message: "The anisette proxy could not reach its upstream server.", over: io)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        let rawType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        let contentType = rawType.contains("\r") || rawType.contains("\n") ? "application/json" : rawType
        try await io.send(httpResponse(status: status, contentType: contentType, body: data))
    }

    private func forwardWebSocket(
        head: HTTPRequestHead,
        path: String,
        io: ConnectionIO,
        alreadyReceived: Data
    ) async throws {
        guard head.headers["upgrade"]?.lowercased() == "websocket",
              let clientKey = head.headers["sec-websocket-key"],
              !clientKey.isEmpty else {
            await sendStatus(426, message: "provisioning_session requires a WebSocket upgrade.", over: io)
            return
        }
        guard let httpURL = AnisetteProxyRouter.upstreamURL(base: command.upstream, path: path),
              var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            throw ProxyServeError.upstream("invalid upstream URL")
        }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw ProxyServeError.upstream("invalid upstream scheme")
        }
        guard let webSocketURL = components.url else {
            throw ProxyServeError.upstream("invalid upstream URL")
        }

        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        try await io.send(WebSocketHandshake.response(clientKey: clientKey))

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.pumpClient(io: io, task: task, alreadyReceived: alreadyReceived)
            }
            group.addTask {
                await self.pumpUpstream(io: io, task: task)
            }
            await group.next()
            group.cancelAll()
        }
        task.cancel(with: .goingAway, reason: nil)
    }

    private func pumpClient(io: ConnectionIO, task: URLSessionWebSocketTask, alreadyReceived: Data) async {
        var decoder = WebSocketFrameDecoder()
        decoder.append(alreadyReceived)
        while true {
            do {
                while let frame = try decoder.next() {
                    switch frame.opcode {
                    case 0x1:
                        guard let text = String(data: frame.payload, encoding: .utf8) else { return }
                        try await task.send(.string(text))
                    case 0x2:
                        try await task.send(.data(frame.payload))
                    case 0x8:
                        return
                    case 0x9:
                        try await io.send(WebSocketFrames.serverFrame(opcode: 0xA, payload: frame.payload))
                    case 0xA:
                        break
                    default:
                        return
                    }
                }
                guard let chunk = try await io.receive() else { return }
                decoder.append(chunk)
            } catch {
                return
            }
        }
    }

    private func pumpUpstream(io: ConnectionIO, task: URLSessionWebSocketTask) async {
        while true {
            do {
                switch try await task.receive() {
                case .string(let text):
                    try await io.send(WebSocketFrames.serverFrame(opcode: 0x1, payload: Data(text.utf8)))
                case .data(let data):
                    try await io.send(WebSocketFrames.serverFrame(opcode: 0x2, payload: data))
                @unknown default:
                    return
                }
            } catch {
                return
            }
        }
    }

    private func sendStatus(_ status: Int, message: String, over io: ConnectionIO) async {
        let payload = Data("{\"result\":\"GetHeadersError\",\"message\":\"\(message)\"}".utf8)
        try? await io.send(httpResponse(status: status, contentType: "application/json", body: payload))
    }

    private func httpResponse(status: Int, contentType: String, body: Data) -> Data {
        let reason: String
        switch status {
        case 101: reason = "Switching Protocols"
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 426: reason = "Upgrade Required"
        case 502: reason = "Bad Gateway"
        default: reason = "Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

private final class ProxyFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func current() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

private final class ConnectionIO: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "emload.anisette-proxy.socket")

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    func receive() async throws -> Data? {
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                        return
                    }
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
            if let chunk, chunk.isEmpty {
                continue
            }
            return chunk
        }
    }
}

private extension CharacterSet {
    static let anisetteProxyToken = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}
