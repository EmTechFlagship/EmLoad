import Foundation
import Security
import SideSign

struct AppleAccountService {
    private static let keychain = AccountKeychain()
    private static let sessionAccount = "apple-session"
    fileprivate static let anisetteAccount = "anisette-state"
    fileprivate static let serverAccount = "anisette-server"
    fileprivate static let signingAccount = "development-certificate"

    static func signIn(
        appleID: String,
        password: String,
        server: AnisetteServer,
        verificationHandler: @escaping DeveloperPortal.VerificationHandler
    ) async throws -> AuthSession {
        guard let serverURL = server.endpoint else {
            throw AccountServiceError.invalidServer
        }

        if server.kind == 2 {
            try keychain.save(server.address, account: serverAccount)
        }
        let manager = try makeAnisetteManager(serverURL: serverURL)
        let identity = try keychain.loadAnisetteIdentity(for: server.address)
        let anisetteResult = try await manager.fetchAnisetteData(
            identifier: identity.identifier,
            existingAdiBlob: identity.adiBlob
        )
        if let newAdiBlob = anisetteResult.newAdiBlob {
            try keychain.save(
                AnisetteIdentity(server: server.address, identifier: identity.identifier, adiBlob: newAdiBlob),
                account: anisetteAccount
            )
        }

        let session = try await DeveloperPortal().authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisetteResult.data,
            xcodeVersion: "26.0",
            verificationHandler: verificationHandler
        )
        try keychain.save(session, account: sessionAccount)
        return session
    }

    static func savedSession() throws -> AuthSession? {
        try keychain.load(AuthSession.self, account: sessionAccount)
    }

    static func signOut() throws {
        try keychain.delete(account: sessionAccount)
    }

    static func selectedAnisetteServer() throws -> String? {
        try keychain.load(String.self, account: serverAccount)
    }

    static func resetAnisetteIdentity() throws {
        try keychain.delete(account: anisetteAccount)
    }

    static func savedSigningIdentity() throws -> KeyStore? {
        guard let material = try keychain.load(SigningMaterial.self, account: signingAccount) else {
            return nil
        }
        return try KeyStore(p12Data: material.p12, password: material.password)
    }

    static func saveSigningIdentity(_ keyStore: KeyStore) throws {
        let password = UUID().uuidString + UUID().uuidString
        let material = SigningMaterial(
            password: password,
            p12: try keyStore.exportP12(password: password)
        )
        try keychain.save(material, account: signingAccount)
    }

    private static func makeAnisetteManager(serverURL: URL) throws -> AnisetteDataManager {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let anisetteDirectory = supportDirectory.appendingPathComponent(
            "EmLoadServer/Anisette",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: anisetteDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: anisetteDirectory.path
        )
        return AnisetteDataManager(
            mode: .remote(server: serverURL),
            baseDirectory: anisetteDirectory
        )
    }
}

private struct SigningMaterial: Codable {
    let password: String
    let p12: Data
}

private struct AnisetteIdentity: Codable {
    let server: String
    let identifier: UUID
    let adiBlob: Data?
}

private struct AccountKeychain {
    private let service = "com.emiry.EmLoadServer"

    func loadAnisetteIdentity(for server: String) throws -> AnisetteIdentity {
        if let saved = try load(AnisetteIdentity.self, account: AppleAccountService.anisetteAccount),
           saved.server == server {
            return saved
        }

        let fresh = AnisetteIdentity(server: server, identifier: UUID(), adiBlob: nil)
        try save(fresh, account: AppleAccountService.anisetteAccount)
        return fresh
    }

    func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, attributes)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw AccountServiceError.keychain(status)
        }

        var insertion = query
        insertion[kSecValueData as String] = data
        let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard insertionStatus == errSecSuccess else {
            throw AccountServiceError.keychain(insertionStatus)
        }
    }

    func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AccountServiceError.keychain(status)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AccountServiceError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum AccountServiceError: LocalizedError {
    case invalidServer
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return "Choose a supported HTTPS Mac-ADI server from SideStore's registry."
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain operation failed with status \(status)."
        }
    }
}
