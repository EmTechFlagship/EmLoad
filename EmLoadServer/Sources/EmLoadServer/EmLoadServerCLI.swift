import Darwin
import Foundation
import SideSign

private let usage = """
Usage:
  emloadserver pair --udid <UDID> --output <pairing-file.plist> [--record-dir <directory>]
  emloadserver login [--apple-id <email>] [--server <name-or-https-url>]
  emloadserver anisette-servers
  emloadserver proxy [--upstream <url>] [--bind <host>] [--port <port>] [--token <secret> | --open]
  emloadserver account
  emloadserver logout
  emloadserver reset-anisette

Apple ID passwords are requested securely in the terminal and are never saved.
The authenticated session and Mac-ADI identity are stored in the macOS Keychain.

Commands:
  pair             Pair and validate an iPhone, then export its private pairing record.
  login            Authenticate with Apple, then install EmLoadStoreCompanion on a USB-connected device.
  anisette-servers List supported HTTPS Mac-ADI servers from SideStore's registry.
  proxy            Forward anisette v3 for other people, using their own identifier.
  account          Show the Apple ID associated with the saved host session.
  logout           Remove the saved Apple authentication session.
  reset-anisette   Remove the saved Mac-ADI identity; the next login may require 2FA.

Run 'emloadserver <command> --help' for command-specific options.
"""

public struct EmLoadServerCLI {
    public static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            exit(EXIT_FAILURE)
        }

        if command == "--help" || command == "-h" || command == "help" {
            print(usage)
            return
        }

        do {
            switch command {
            case "pair":
                if arguments.dropFirst().contains("--help") {
                    print(usage)
                    return
                }
                let pairCommand = try PairCommand.parse(arguments: Array(arguments.dropFirst()))
                try pairCommand.run()
                print("Device paired and validated.")
                print("Private pairing record saved to \(pairCommand.outputURL.path)")
                print("Treat this file like a credential; transfer it only to your own EmLoadStore device.")
            case "login":
                if arguments.dropFirst().contains("--help") {
                    print("""
                    Usage: emloadserver login [--apple-id <email>] [--server <name-or-https-url>]

                    The password is requested through a no-echo terminal prompt. If --server is
                    omitted, SideStore (New) is selected when available. Pass an http or https
                    URL to use an anisette proxy instead of a registry server. The endpoint is
                    not changed automatically after a failed request. When an iPhone or iPad is
                    connected by USB, EmLoadStoreCompanion is signed with this Apple ID and
                    installed on that device.
                    """)
                    return
                }
                try await signIn(arguments: Array(arguments.dropFirst()))
            case "anisette-servers":
                guard arguments.count == 1 else {
                    throw CLIError.unexpectedArguments(command)
                }
                let servers = try await AnisetteServerRegistry.load()
                for server in servers {
                    print("\(server.name)\t\(server.address)")
                }
            case "proxy":
                if arguments.dropFirst().contains("--help") {
                    print("""
                    Usage: emloadserver proxy [--upstream <url>] [--bind <host>] [--port <port>] [--token <secret> | --open]

                    Forwards SideStore anisette v3 (client_info, get_headers, and the provisioning
                    WebSocket) to an upstream server. Each caller sends their own identifier.
                    The proxy does not read the Apple ID, development certificate, or anisette
                    identity saved in this Mac's Keychain.

                    The default upstream is SideStore (New). The default bind is 0.0.0.0 port 1741.
                    A random URL token is required unless --open is set. Give other people the
                    printed server URL and have them pass it to emloadserver login --server, or set
                    EMLOAD_ANISETTE_SERVER for the EmLoad Python client.
                    """)
                    return
                }
                let proxyCommand = try ProxyCommand.parse(arguments: Array(arguments.dropFirst()))
                try await AnisetteProxy(command: proxyCommand).run()
            case "account":
                guard arguments.count == 1 else {
                    throw CLIError.unexpectedArguments(command)
                }
                if let session = try AppleAccountService.savedSession() {
                    print("Signed in as \(session.account.appleID)")
                } else {
                    print("No Apple ID session is saved on this Mac.")
                }
            case "logout":
                guard arguments.count == 1 else {
                    throw CLIError.unexpectedArguments(command)
                }
                try AppleAccountService.signOut()
                print("Apple ID session removed from this Mac.")
            case "reset-anisette":
                guard arguments.count == 1 else {
                    throw CLIError.unexpectedArguments(command)
                }
                try AppleAccountService.resetAnisetteIdentity()
                print("Saved Mac-ADI identity removed. The next sign-in may require two-factor verification.")
            default:
                throw CLIError.unknownCommand(command)
            }
        } catch {
            let message = error.localizedDescription
            if message.contains("-80045") {
                fputs(
                    "emloadserver: \(message)\nApple's response can have multiple causes; no client-side fix is guaranteed. Keep the same server selected. If you choose to retry, reset the Anisette identity at most once with 'emloadserver reset-anisette', then wait before trying again to avoid Apple's security limits.\n",
                    stderr
                )
            } else {
                fputs("emloadserver: \(message)\n", stderr)
            }
            exit(EXIT_FAILURE)
        }
    }

    private static func signIn(arguments: [String]) async throws {
        let options = try LoginOptions.parse(arguments: arguments)
        let appleID: String
        if let providedAppleID = options.appleID {
            appleID = providedAppleID
        } else {
            guard let enteredAppleID = prompt("Apple ID email: "),
                  !enteredAppleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.inputCancelled
            }
            appleID = enteredAppleID
        }

        let server: AnisetteServer
        if let requested = options.server?.trimmingCharacters(in: .whitespacesAndNewlines),
           requested.contains("://") {
            guard let custom = AnisetteServerRegistry.customEndpoint(from: requested) else {
                throw CLIError.invalidProxyURL
            }
            server = custom
            print("Using anisette proxy \(server.address).")
            print("The Apple ID entered next is yours. The proxy does not supply this Mac's saved account or certificate.")
        } else {
            let servers = try await AnisetteServerRegistry.load()
            let preferredServer = options.server == nil
                ? try AppleAccountService.selectedAnisetteServer()
                : nil
            server = try AnisetteServerRegistry.select(
                server: options.server,
                preferredAddress: preferredServer,
                from: servers
            )
            print("Using \(server.name) (\(server.address)).")
        }

        guard let passwordPointer = getpass("Apple ID password: ") else {
            throw CLIError.inputCancelled
        }
        let password = String(cString: passwordPointer)
        memset(passwordPointer, 0, strlen(passwordPointer))
        guard !password.isEmpty else {
            throw CLIError.emptyPassword
        }

        let session = try await AppleAccountService.signIn(
            appleID: appleID,
            password: password,
            server: server,
            verificationHandler: verificationResponse
        )
        print("Signed in as \(session.account.appleID). Session saved in the macOS Keychain.")
        try await installCompanion(session: session)
    }

    private static func installCompanion(session: AuthSession) async throws {
        let devices: [ConnectedDevice]
        do {
            devices = try USBDeviceScanner().connectedDevices()
        } catch let error as SideloadError where error.isDiscoveryFailure {
            fputs("emloadserver: \(error.localizedDescription)\n", stderr)
            return
        }

        guard !devices.isEmpty else {
            print("No iPhone or iPad is connected by USB, so EmLoadStoreCompanion was not installed.")
            return
        }

        let names = devices.map { "\($0.name) (\($0.udid))" }.joined(separator: ", ")
        print("Installing EmLoadStoreCompanion on \(names).")
        try await CompanionSideload().install(session: session, devices: devices)
        for device in devices {
            print("Installed EmLoadStoreCompanion on \(device.name).")
        }
    }

    private static func verificationResponse(for request: TwoFactorRequest) async throws -> TwoFactorResponse {
        switch request {
        case .selectDeliveryMethod(let preferredMode, let phoneNumbers):
            print("Apple requires two-factor verification.")
            print("1. Approve on a trusted Apple device")
            for (index, phone) in phoneNumbers.enumerated() {
                print("\(index + 2). Text a code to \(phone.number)")
                print("\(index + phoneNumbers.count + 2). Call \(phone.number)")
            }
            let defaultChoice = preferredMode == .trustedDevice || phoneNumbers.isEmpty ? "1" : "2"
            guard let choice = prompt("Choose a method [\(defaultChoice), or 0 to cancel]: ") else {
                return .cancel
            }
            if choice == "0" { return .cancel }
            if choice == "1" { return .requestTrustedDevice }
            if let index = Int(choice), index >= 2, index - 2 < phoneNumbers.count {
                return .requestSMS(phoneID: phoneNumbers[index - 2].id)
            }
            let firstVoiceChoice = phoneNumbers.count + 2
            if let index = Int(choice),
               index >= firstVoiceChoice,
               index - firstVoiceChoice < phoneNumbers.count {
                return .requestVoice(phoneID: phoneNumbers[index - firstVoiceChoice].id)
            }
            print("Invalid selection.")
            return .cancel
        case .trustedDevice(let error):
            if let error { fputs("\(error)\n", stderr) }
            guard let code = prompt("Code from trusted Apple device (or 0 to cancel): "),
                  code != "0" else {
                return .cancel
            }
            return .verificationCode(code)
        case .sms(let phoneNumbers, _, let error):
            if let error { fputs("\(error)\n", stderr) }
            if !phoneNumbers.isEmpty {
                print("A verification code was requested for a trusted phone number.")
            }
            guard let code = prompt("Text-message code (or 0 to cancel): "),
                  code != "0" else {
                return .cancel
            }
            return .verificationCode(code)
        case .voice(_, _, let error):
            if let error { fputs("\(error)\n", stderr) }
            guard let code = prompt("Phone-call code (or 0 to cancel): "),
                  code != "0" else {
                return .cancel
            }
            return .verificationCode(code)
        }
    }

    private static func prompt(_ message: String) -> String? {
        print(message, terminator: "")
        fflush(stdout)
        return readLine()
    }
}

struct LoginOptions: Equatable {
    let appleID: String?
    let server: String?

    static func parse(arguments: [String]) throws -> LoginOptions {
        var appleID: String?
        var server: String?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else {
                throw CLIError.missingValue(option)
            }
            let value = arguments[index + 1]
            switch option {
            case "--apple-id":
                guard appleID == nil else { throw CLIError.duplicateOption(option) }
                appleID = value
            case "--server":
                guard server == nil else { throw CLIError.duplicateOption(option) }
                server = value
            default:
                throw CLIError.unknownOption(option)
            }
            index += 2
        }
        return LoginOptions(appleID: appleID, server: server)
    }
}

private enum CLIError: LocalizedError {
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case duplicateOption(String)
    case unexpectedArguments(String)
    case inputCancelled
    case emptyPassword
    case invalidProxyURL

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "Unknown command: \(command). Run 'emloadserver --help' for usage."
        case .unknownOption(let option):
            return "Unknown option: \(option)."
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .duplicateOption(let option):
            return "Option \(option) may only be provided once."
        case .unexpectedArguments(let command):
            return "The \(command) command does not accept arguments."
        case .inputCancelled:
            return "Input cancelled."
        case .emptyPassword:
            return "The password cannot be empty."
        case .invalidProxyURL:
            return "A custom anisette server must be an http or https URL without a username, password, or fragment."
        }
    }
}
