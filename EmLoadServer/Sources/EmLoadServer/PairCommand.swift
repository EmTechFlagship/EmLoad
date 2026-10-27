import Foundation
import Darwin

struct PairCommand {
    let udid: String
    let outputURL: URL
    let recordDirectoryURL: URL?

    static func parse(arguments: [String]) throws -> PairCommand {
        var udid: String?
        var outputPath: String?
        var recordDirectoryPath: String?
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw PairCommandError.missingValue(option)
            }

            let value = arguments[index + 1]
            switch option {
            case "--udid":
                udid = value
            case "--output":
                outputPath = value
            case "--record-dir":
                recordDirectoryPath = value
            default:
                throw PairCommandError.unknownOption(option)
            }
            index += 2
        }

        guard let udid else {
            throw PairCommandError.missingOption("--udid")
        }
        guard udid.range(of: #"^[A-Fa-f0-9]{8,40}(-[A-Fa-f0-9]{8,16})?$"#, options: .regularExpression) != nil else {
            throw PairCommandError.invalidUDID
        }
        guard let outputPath, !outputPath.isEmpty else {
            throw PairCommandError.missingOption("--output")
        }

        return PairCommand(
            udid: udid,
            outputURL: URL(fileURLWithPath: outputPath).standardizedFileURL,
            recordDirectoryURL: recordDirectoryPath.map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            }
        )
    }

    func run(
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let pairTool = executableURL ?? URL(fileURLWithPath: "/usr/bin/env")
        let commandPrefix = executableURL == nil ? ["idevicepair"] : []

        try runProcess(
            executable: pairTool,
            arguments: commandPrefix + ["-u", udid, "pair"],
            environment: environment
        )
        try runProcess(
            executable: pairTool,
            arguments: commandPrefix + ["-u", udid, "validate"],
            environment: environment
        )

        let recordURL = try pairingRecordURL(environment: environment)
        let attributes = try FileManager.default.attributesOfItem(atPath: recordURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= 1_048_576 else {
            throw PairCommandError.invalidPairingRecord(recordURL.path)
        }
        let record = try Data(contentsOf: recordURL)
        guard let propertyList = try? PropertyListSerialization.propertyList(from: record, options: [], format: nil),
              propertyList is [String: Any] else {
            throw PairCommandError.invalidPairingRecord(recordURL.path)
        }

        try writePrivateFile(record, to: outputURL)
    }

    private func pairingRecordURL(environment: [String: String]) throws -> URL {
        let directories: [URL]
        if let recordDirectoryURL {
            directories = [recordDirectoryURL]
        } else if let configuredDirectory = environment["EMLOADSERVER_LOCKDOWN_DIR"] {
            directories = [URL(fileURLWithPath: configuredDirectory, isDirectory: true)]
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            directories = [
                URL(fileURLWithPath: "/var/db/lockdown", isDirectory: true),
                home.appendingPathComponent(".config/libimobiledevice", isDirectory: true),
                home.appendingPathComponent(".local/share/libimobiledevice", isDirectory: true)
            ]
        }

        for directory in directories {
            let candidate = directory.appendingPathComponent("\(udid).plist")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw PairCommandError.pairingRecordNotFound(udid)
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw PairCommandError.couldNotStart(error.localizedDescription)
        }

        let standardOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let details = String(
                data: standardOutput,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PairCommandError.toolFailed(
                status: process.terminationStatus,
                details: details.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    private func writePrivateFile(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PairCommandError.outputDirectoryMissing(parent.path)
        }

        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PairCommandError.couldNotCreateOutput(url.path, errno)
        }

        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var bytesRemaining = buffer.count
                var currentAddress = baseAddress
                while bytesRemaining > 0 {
                    let bytesWritten = write(descriptor, currentAddress, bytesRemaining)
                    guard bytesWritten > 0 else {
                        throw PairCommandError.couldNotWriteOutput(url.path, errno)
                    }
                    bytesRemaining -= bytesWritten
                    currentAddress = currentAddress.advanced(by: bytesWritten)
                }
            }
            guard close(descriptor) == 0 else {
                throw PairCommandError.couldNotWriteOutput(url.path, errno)
            }
        } catch {
            _ = close(descriptor)
            _ = unlink(url.path)
            throw error
        }
    }
}

enum PairCommandError: LocalizedError {
    case missingValue(String)
    case missingOption(String)
    case unknownOption(String)
    case invalidUDID
    case couldNotStart(String)
    case toolFailed(status: Int32, details: String?)
    case pairingRecordNotFound(String)
    case invalidPairingRecord(String)
    case outputDirectoryMissing(String)
    case couldNotCreateOutput(String, Int32)
    case couldNotWriteOutput(String, Int32)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .missingOption(let option):
            return "Required option \(option) was not provided."
        case .unknownOption(let option):
            return "Unknown option: \(option)."
        case .invalidUDID:
            return "The UDID must be 8–40 hexadecimal characters, optionally followed by a hyphen and 8–16 more."
        case .couldNotStart(let reason):
            return "Could not start idevicepair: \(reason)"
        case .toolFailed(let status, let details):
            return "idevicepair failed with status \(status).\(details.map { " \($0)" } ?? "")"
        case .pairingRecordNotFound(let udid):
            return "Pairing succeeded, but no pairing record for \(udid) was found. Use --record-dir to specify the libimobiledevice lockdown directory."
        case .invalidPairingRecord(let path):
            return "The pairing record at \(path) is not a valid property-list dictionary."
        case .outputDirectoryMissing(let path):
            return "The output directory does not exist: \(path)"
        case .couldNotCreateOutput(let path, let code):
            return "Could not create \(path): \(String(cString: strerror(code))). The file may already exist."
        case .couldNotWriteOutput(let path, let code):
            return "Could not write \(path): \(String(cString: strerror(code)))."
        }
    }
}
