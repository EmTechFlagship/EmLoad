import Foundation
import SideSign

/// The part of EmLoadServer the EmLoad window calls: Apple ID sign-in, companion
/// install, and pairing-record export. Passwords stay in memory for the request.
public enum EmLoadStoreSetup {
    public struct Account: Equatable, Sendable {
        public let appleID: String

        public init(appleID: String) {
            self.appleID = appleID
        }
    }

    public struct Phone: Equatable, Sendable, Identifiable {
        public let id: String
        public let number: String
    }

    public struct Device: Equatable, Sendable {
        public let udid: String
        public let name: String
        public let productType: String

        public init(udid: String, name: String, productType: String) {
            self.udid = udid
            self.name = name
            self.productType = productType
        }
    }

    public enum Challenge: Equatable, Sendable {
        case chooseMethod(preferTrustedDevice: Bool, phones: [Phone])
        case trustedDeviceCode(error: String?)
        case smsCode(number: String?, error: String?)
        case voiceCode(number: String?, error: String?)
    }

    public enum Answer: Sendable {
        case trustedDevice
        case sms(id: String)
        case voice(id: String)
        case code(String)
        case cancel
    }

    public static func savedAccount() throws -> Account? {
        guard let session = try AppleAccountService.savedSession() else { return nil }
        return Account(appleID: session.account.appleID)
    }

    public static func signOut() throws {
        try AppleAccountService.signOut()
    }

    public static func signIn(
        appleID: String,
        password: String,
        server requestedServer: String? = nil,
        respond: @escaping @Sendable (Challenge) async -> Answer
    ) async throws -> Account {
        let server = try await resolveServer(requestedServer)
        let session = try await AppleAccountService.signIn(
            appleID: appleID,
            password: password,
            server: server,
            verificationHandler: { request in
                let answer = await respond(Challenge(request))
                return answer.portalResponse
            }
        )
        return Account(appleID: session.account.appleID)
    }

    public static func installCompanion(on devices: [Device]) async throws {
        guard !devices.isEmpty else { return }
        guard let session = try AppleAccountService.savedSession() else {
            throw SetupError.notSignedIn
        }
        let connected = devices.map { device in
            ConnectedDevice(
                udid: device.udid,
                name: device.name,
                type: USBDeviceList.deviceType(productType: device.productType)
            )
        }
        try await CompanionSideload().install(session: session, devices: connected)
    }

    /// Pair and validate `udid`, then write a new owner-only pairing record.
    /// Existing files are left untouched.
    public static func exportPairing(udid: String, to output: URL) throws {
        let command = PairCommand(udid: udid, outputURL: output, recordDirectoryURL: nil)
        try command.run()
    }

    private static func resolveServer(_ requested: String?) async throws -> AnisetteServer {
        if let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
           requested.contains("://") {
            guard let custom = AnisetteServerRegistry.customEndpoint(from: requested) else {
                throw SetupError.invalidServer
            }
            return custom
        }

        let servers = try await AnisetteServerRegistry.load()
        let preferred = requested == nil ? try AppleAccountService.selectedAnisetteServer() : nil
        return try AnisetteServerRegistry.select(
            server: requested,
            preferredAddress: preferred,
            from: servers
        )
    }
}

public enum SetupError: LocalizedError {
    case notSignedIn
    case invalidServer

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with the Apple ID that should sign EmLoadStoreCompanion."
        case .invalidServer:
            return "A custom anisette server must be an http or https URL without a username, password, or fragment."
        }
    }
}

private extension EmLoadStoreSetup.Challenge {
    init(_ request: TwoFactorRequest) {
        switch request {
        case .selectDeliveryMethod(let preferredMode, let phoneNumbers):
            self = .chooseMethod(
                preferTrustedDevice: preferredMode == .trustedDevice || phoneNumbers.isEmpty,
                phones: phoneNumbers.map { EmLoadStoreSetup.Phone(id: $0.id, number: $0.number) }
            )
        case .trustedDevice(let error):
            self = .trustedDeviceCode(error: error)
        case .sms(let phoneNumbers, let activeID, let error):
            let number = phoneNumbers.first { $0.id == activeID }?.number
            self = .smsCode(number: number, error: error)
        case .voice(let phoneNumbers, let activeID, let error):
            let number = phoneNumbers.first { $0.id == activeID }?.number
            self = .voiceCode(number: number, error: error)
        }
    }
}

private extension EmLoadStoreSetup.Answer {
    var portalResponse: TwoFactorResponse {
        switch self {
        case .trustedDevice:
            return .requestTrustedDevice
        case .sms(let id):
            return .requestSMS(phoneID: id)
        case .voice(let id):
            return .requestVoice(phoneID: id)
        case .code(let code):
            return .verificationCode(code)
        case .cancel:
            return .cancel
        }
    }
}
