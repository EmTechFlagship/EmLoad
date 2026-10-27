import Foundation
import Combine

struct ImportedIPA: Codable, Identifiable {
    let id: UUID
    let name: String
    let storedFileName: String
    let importedAt: Date

    init(name: String, storedFileName: String) {
        id = UUID()
        self.name = name
        self.storedFileName = storedFileName
        importedAt = Date()
    }
}

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [ImportedIPA] = []
    @Published private(set) var hasPairingRecord = false
    @Published var errorMessage: String?

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let indexURL: URL
    private let pairingRecordURL: URL

    init() {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directoryURL = applicationSupport.appendingPathComponent("EmLoadStore/IPAs", isDirectory: true)
        indexURL = applicationSupport.appendingPathComponent("EmLoadStore/library.json")
        pairingRecordURL = applicationSupport.appendingPathComponent("EmLoadStore/pairing-record.plist")
        hasPairingRecord = fileManager.fileExists(atPath: pairingRecordURL.path)

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: indexURL.path) {
                apps = try JSONDecoder().decode([ImportedIPA].self, from: Data(contentsOf: indexURL))
            }
        } catch {
            errorMessage = "Could not load your IPA library: \(error.localizedDescription)"
        }
    }

    func importIPA(from sourceURL: URL) throws {
        guard sourceURL.pathExtension.lowercased() == "ipa" else {
            throw LibraryError.unsupportedFile
        }

        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let storedFileName = "\(UUID().uuidString).ipa"
        let destinationURL = directoryURL.appendingPathComponent(storedFileName)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let imported = ImportedIPA(
            name: sourceURL.deletingPathExtension().lastPathComponent,
            storedFileName: storedFileName
        )
        let updatedApps = [imported] + apps

        do {
            try persist(updatedApps)
            apps = updatedApps
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    func remove(_ app: ImportedIPA) throws {
        let updatedApps = apps.filter { $0.id != app.id }
        try persist(updatedApps)
        apps = updatedApps

        let fileURL = directoryURL.appendingPathComponent(app.storedFileName)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    func importPairingRecord(from sourceURL: URL) throws {
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= 1_048_576 else {
            throw LibraryError.invalidPairingRecord
        }

        let data = try Data(contentsOf: sourceURL)
        guard
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              propertyList is [String: Any] else {
            throw LibraryError.invalidPairingRecord
        }

        try fileManager.createDirectory(
            at: pairingRecordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: pairingRecordURL, options: .atomic)
        #if os(iOS)
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: pairingRecordURL.path
            )
        } catch {
            try? fileManager.removeItem(at: pairingRecordURL)
            throw error
        }
        #endif
        hasPairingRecord = true
    }

    private func persist(_ apps: [ImportedIPA]) throws {
        let data = try JSONEncoder().encode(apps)
        try fileManager.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: indexURL, options: .atomic)
    }

    private enum LibraryError: LocalizedError {
        case unsupportedFile
        case invalidPairingRecord

        var errorDescription: String? {
            switch self {
            case .unsupportedFile:
                return "Choose an .ipa file."
            case .invalidPairingRecord:
                return "Choose a valid libimobiledevice pairing record in property-list format."
            }
        }
    }
}
