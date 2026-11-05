import Foundation
import SideSign

public struct EmLoadIdentityTransfer: Codable, Sendable {
    public let authSession: AuthSession
    public let team: Team
    public let certificate: Data
    public let certificatePassword: String
}

/// The part of EmLoadServer the EmLoad window calls: Apple ID sign-in, companion
/// install, and pairing-record export. Passwords stay in memory for the request.
public enum EmLoadiOSSetup {
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

    public static func installCompanion(
        on devices: [Device],
        progress: ((Double?, String) -> Void)? = nil
    ) async throws {
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
        try await CompanionSideload().install(session: session, devices: connected, progress: progress)
    }

    /// Pair and validate `udid`, then write a new owner-only pairing record.
    /// Existing files are left untouched.
    public static func exportPairing(udid: String, to output: URL) throws {
        let command = PairCommand(udid: udid, outputURL: output, recordDirectoryURL: nil)
        try command.run()
        let data = try Data(contentsOf: output)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let storedUDID = plist["UDID"] as? String,
              let hostPrivateKey = plist["HostPrivateKey"] as? Data,
              !hostPrivateKey.isEmpty else {
            throw SetupError.invalidPairingFile
        }
        try AppleAccountService.saveIPAImportPairingKey(hostPrivateKey, for: storedUDID)
    }

    public static func identityTransfer() async throws -> EmLoadIdentityTransfer {
        guard let session = try AppleAccountService.savedSession() else {
            throw SetupError.notSignedIn
        }
        return try await CompanionSideload().identityTransfer(session: session)
    }

    public static func installIPA(
        at ipaURL: URL,
        for udid: String,
        progress: ((String) -> Void)? = nil
    ) async throws {
        guard let session = try AppleAccountService.savedSession() else {
            throw SetupError.notSignedIn
        }
        guard try AppleAccountService.ipaImportPairingKey(for: udid)?.isEmpty == false else {
            throw SetupError.deviceNotPaired
        }
        let devices = try USBDeviceScanner().connectedDevices()
        let normalized = udid.replacingOccurrences(of: "-", with: "").lowercased()
        guard let device = devices.first(where: {
            $0.udid.replacingOccurrences(of: "-", with: "").lowercased() == normalized
        }) else {
            throw SetupError.deviceNotConnected
        }
        try await CompanionSideload().installIPA(at: ipaURL, on: device, session: session, progress: progress)
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
    case invalidPairingFile
    case deviceNotPaired
    case deviceNotConnected

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with the Apple ID that should sign EmLoad."
        case .invalidServer:
            return "A custom anisette server must be an http or https URL without a username, password, or fragment."
        case .invalidPairingFile:
            return "The pairing file does not contain the expected device credentials. Pair the device again and export a fresh file."
        case .deviceNotPaired:
            return "This device has not been paired with EmLoadServer. Re-export and import its pairing file from EmLoad iOS Setup."
        case .deviceNotConnected:
            return "The paired iPhone or iPad is not connected to this Mac by USB."
        }
    }
}

private extension EmLoadiOSSetup.Challenge {
    init(_ request: TwoFactorRequest) {
        switch request {
        case .selectDeliveryMethod(let preferredMode, let phoneNumbers):
            self = .chooseMethod(
                preferTrustedDevice: preferredMode == .trustedDevice || phoneNumbers.isEmpty,
                phones: phoneNumbers.map { EmLoadiOSSetup.Phone(id: $0.id, number: $0.number) }
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

private extension EmLoadiOSSetup.Answer {
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
