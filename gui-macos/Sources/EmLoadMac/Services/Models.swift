import AppKit
import Foundation

// MARK: - JSON helpers

enum JSON {
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let flag = value as? Bool { return flag }
        return nil
    }

    static func dict(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }

    static func strings(_ value: Any?) -> [String] {
        guard let rows = value as? [Any] else { return [] }
        return rows.compactMap { string($0) }
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = string(value), !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Devices

struct Device: Identifiable, Hashable {
    let udid: String
    let name: String?
    let model: String?
    let osVersion: String?
    let connection: String?
    let responded: Bool

    var id: String { udid }

    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Unnamed device"
        }
        return name
    }

    var subtitle: String {
        "\(model ?? "unknown model") · iOS \(osVersion ?? "?")"
    }

    var connectionLabel: String {
        guard let connection, !connection.isEmpty else { return "unknown" }
        return connection.uppercased()
    }

    var shortUDID: String {
        udid.count > 12 ? String(udid.prefix(8)) + "…" : udid
    }

    static func list(from value: Any) -> [Device] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let serial = JSON.string(row["serial"]), !serial.isEmpty else { return nil }
            let info = JSON.dict(row["info"]) ?? [:]
            return Device(
                udid: serial,
                name: JSON.string(info["DeviceName"]),
                model: JSON.string(info["ProductType"]),
                osVersion: JSON.string(info["ProductVersion"]),
                connection: JSON.string(row["connection_type"]),
                responded: !info.isEmpty
            )
        }
    }
}

// MARK: - Library

struct LibraryApp: Identifiable, Hashable {
    let bundleId: String
    let name: String?
    let installedAt: Date?
    let expiresAt: Date?
    let daysLeft: Double?
    let expired: Bool
    let icon: String?
    let udid: String?

    var id: String { bundleId }

    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return bundleId
        }
        return name
    }

    var expiresText: String {
        guard let expiresAt else { return "no expiry recorded" }
        return Self.dateFormatter.string(from: expiresAt)
    }

    var timeLeftText: String {
        guard let daysLeft else { return "-" }
        if expired || daysLeft <= 0 { return "expired" }
        if daysLeft < 1 { return "\(max(0, Int(daysLeft * 24)))h left" }
        return String(format: "%.1fd left", daysLeft)
    }

    var compactStatus: String {
        expiresAt == nil ? "no expiry recorded" : "expires \(expiresText) · \(timeLeftText)"
    }

    static func list(from value: Any) -> [LibraryApp] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let bundleId = JSON.string(row["bundle_id"]), !bundleId.isEmpty else { return nil }
            return LibraryApp(
                bundleId: bundleId,
                name: JSON.string(row["name"]),
                installedAt: JSON.date(row["installed_at"]),
                expiresAt: JSON.date(row["expires_at"]),
                daysLeft: JSON.double(row["days_left"]),
                expired: JSON.bool(row["expired"]) ?? false,
                icon: JSON.string(row["icon"]),
                udid: JSON.string(row["udid"])
            )
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - IPA

struct IpaSummary {
    let path: String
    let appBundle: String?
    let displayName: String?
    let bundleId: String?
    let version: String?
    let build: String?
    let minimumOS: String?
    let platform: String?
    let encrypted: Bool
    let extensions: [String]
    let icon: String?

    init(dictionary: [String: Any], path: String) {
        self.path = path
        appBundle = JSON.string(dictionary["app_bundle"])
        displayName = JSON.string(dictionary["display_name"])
        bundleId = JSON.string(dictionary["bundle_id"])
        version = JSON.string(dictionary["version"])
        build = JSON.string(dictionary["build"])
        minimumOS = JSON.string(dictionary["minimum_os"])
        platform = JSON.string(dictionary["platform"])
        encrypted = JSON.bool(dictionary["encrypted"]) ?? false
        extensions = JSON.strings(dictionary["extensions"])
        icon = JSON.string(dictionary["icon"])
    }

    var fileName: String { (path as NSString).lastPathComponent }
}

// MARK: - Account

struct AccountStatus {
    let authenticated: Bool
    let email: String?
    let teamId: String?
    let hasAuthToken: Bool
    let accountCount: Int

    init(dictionary: [String: Any]) {
        authenticated = JSON.bool(dictionary["authenticated"]) ?? false
        email = JSON.string(dictionary["email"])
        teamId = JSON.string(dictionary["team_id"])
        hasAuthToken = JSON.bool(dictionary["has_auth_token"]) ?? false
        accountCount = JSON.int(dictionary["account_count"]) ?? 0
    }
}

// MARK: - Signing

struct SigningStatus {
    let available: Bool
    let path: String?
    let version: String?
    let error: String?

    init(dictionary: [String: Any]) {
        available = JSON.bool(dictionary["available"]) ?? false
        path = JSON.string(dictionary["path"])
        version = JSON.string(dictionary["version"])
        error = JSON.string(dictionary["error"])
    }
}

// MARK: - Settings

struct SettingsSnapshot {
    var connection = "auto"
    var signedDir = ""
    var keepSigned = false
    var emstoreServer = false
    var dataDir = ""
    var configFile = ""

    init() {}

    init(dictionary: [String: Any]) {
        connection = JSON.string(dictionary["connection"]) ?? "auto"
        signedDir = JSON.string(dictionary["signed_dir"]) ?? ""
        keepSigned = JSON.bool(dictionary["keep_signed"]) ?? false
        emstoreServer = JSON.bool(dictionary["emstore_server"]) ?? false
        dataDir = JSON.string(dictionary["data_dir"]) ?? ""
        configFile = JSON.string(dictionary["config_file"]) ?? ""
    }
}

// MARK: - EmSideStore

struct EmStoreDevice: Identifiable {
    let udid: String
    let name: String?
    let connection: String?
    let installed: Bool?
    let version: String?

    var id: String { udid }

    var displayName: String {
        guard let name, !name.isEmpty else { return udid }
        return name
    }

    var installedText: String {
        switch installed {
        case true?:
            if let version, !version.isEmpty { return "SideStore \(version) installed" }
            return "SideStore installed"
        case false?:
            return "SideStore not installed"
        case nil:
            return "Install state unavailable"
        }
    }
}

struct EmStoreStatus {
    let bundleId: String
    let repo: String
    let account: AccountStatus
    let ipas: [String]
    let devices: [EmStoreDevice]

    init(dictionary: [String: Any]) {
        bundleId = JSON.string(dictionary["bundle_id"]) ?? "com.SideStore.SideStore"
        repo = JSON.string(dictionary["repo"]) ?? "embabyty/EmStore"
        account = AccountStatus(dictionary: JSON.dict(dictionary["account"]) ?? [:])
        ipas = JSON.strings(dictionary["ipa"])
        let rows = JSON.array(dictionary["devices"]) ?? []
        devices = rows.compactMap { row in
            guard let udid = JSON.string(row["udid"]), !udid.isEmpty else { return nil }
            return EmStoreDevice(
                udid: udid,
                name: JSON.string(row["name"]),
                connection: JSON.string(row["connection"]),
                installed: JSON.bool(row["emstore_installed"]),
                version: JSON.string(row["emstore_version"])
            )
        }
    }

    func device(for udid: String) -> EmStoreDevice? {
        devices.first { $0.udid == udid }
    }
}

// MARK: - JIT

struct JitApp: Identifiable, Hashable {
    let bundleId: String
    let name: String?
    let version: String?

    var id: String { bundleId }

    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return bundleId
        }
        return name
    }

    var versionText: String {
        guard let version, !version.isEmpty else { return "" }
        return version
    }

    static func list(from value: Any) -> [JitApp] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let bundleId = JSON.string(row["bundle_id"]), !bundleId.isEmpty else { return nil }
            return JitApp(
                bundleId: bundleId,
                name: JSON.string(row["name"]),
                version: JSON.string(row["version"])
            )
        }
    }
}

// MARK: - Diagnostics

struct DoctorCheck: Identifiable {
    let name: String
    let status: String
    let message: String

    var id: String { "\(name)-\(message)" }

    var symbol: String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "warn": return "exclamationmark.triangle.fill"
        case "error": return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }

    static func list(from value: Any) -> [DoctorCheck] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.map { row in
            DoctorCheck(
                name: JSON.string(row["name"]) ?? "?",
                status: JSON.string(row["status"]) ?? "?",
                message: JSON.string(row["message"]) ?? ""
            )
        }
    }
}

// MARK: - Misc tweaks

struct TweakGroup {
    let group: String
    let title: String
    let subtitle: String
    let controls: [TweakControl]

    init(dictionary: [String: Any]) {
        group = JSON.string(dictionary["group"]) ?? ""
        title = JSON.string(dictionary["title"]) ?? "Tweaks"
        subtitle = JSON.string(dictionary["subtitle"]) ?? ""
        let rows = dictionary["controls"] as? [[String: Any]] ?? []
        controls = rows.map(TweakControl.init)
    }
}

struct TweakControl: Identifiable {
    let id: String
    let kind: String
    let label: String?
    let text: String?
    let placeholder: String?
    let invert: Bool
    let state: String?
    let value: Any?
    let keys: [String]
    let minimum: Int?
    let maximum: Int?

    init(dictionary: [String: Any]) {
        id = JSON.string(dictionary["id"]) ?? UUID().uuidString
        kind = JSON.string(dictionary["kind"]) ?? "label"
        label = JSON.string(dictionary["label"])
        text = JSON.string(dictionary["text"])
        placeholder = JSON.string(dictionary["placeholder"])
        invert = JSON.bool(dictionary["invert"]) ?? false
        state = JSON.string(dictionary["state"])
        value = dictionary["value"]
        keys = JSON.strings(dictionary["keys"])
        minimum = JSON.int(dictionary["min"])
        maximum = JSON.int(dictionary["max"])
    }
}

// MARK: - Small UI helpers

enum DataURI {
    static func image(from uri: String?) -> NSImage? {
        guard let uri, let comma = uri.firstIndex(of: ",") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return NSImage(data: data)
    }
}
