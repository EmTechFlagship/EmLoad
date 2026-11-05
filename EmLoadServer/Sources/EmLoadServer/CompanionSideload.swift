import Foundation
import SideSign

struct ConnectedDevice: Equatable {
    let udid: String
    let name: String
    let type: DeviceType
}

enum USBDeviceList {
    static func udids(from output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.range(of: #"^[A-Fa-f0-9]{8,40}(-[A-Fa-f0-9]{8,16})?$"#, options: .regularExpression) != nil else {
                return nil
            }
            return value
        }
    }

    static func infoValue(from output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("ERROR") else { return nil }
        return value
    }

    static func deviceType(productType: String) -> DeviceType {
        productType.lowercased().hasPrefix("ipad") ? .iPad : .iPhone
    }

    static func preferredTeam(in teams: [Team]) -> Team? {
        teams.first { $0.type == .free }
            ?? teams.first { $0.type == .individual }
            ?? teams.first
    }
}

struct ShellOutput: Equatable {
    let status: Int32
    let output: String
}

struct ShellCommand {
    var executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var environment = Self.defaultEnvironment()

    private static func defaultEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let existingPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let preferredPaths = [
            "\(home)/.local/bin",
            "\(home)/.local/opt/libimobiledevice/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let additions = preferredPaths.filter { path in
            !existingPaths.contains(path)
                && FileManager.default.fileExists(atPath: path)
        }
        environment["PATH"] = (additions + existingPaths).joined(separator: ":")
        return environment
    }

    func run(_ arguments: [String]) throws -> ShellOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw SideloadError.couldNotStart(arguments.first ?? "command", error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShellOutput(status: process.terminationStatus, output: output)
    }
}

struct USBDeviceScanner {
    var shell = ShellCommand()

    func connectedDevices() throws -> [ConnectedDevice] {
        let listed = try shell.run(["idevice_id", "-l"])
        if Self.commandIsMissing(listed) {
            throw SideloadError.missingTool("idevice_id")
        }
        guard listed.status == 0 else {
            throw SideloadError.deviceListFailed(listed.output)
        }

        return USBDeviceList.udids(from: listed.output).map { udid in
            let name = deviceValue(udid: udid, key: "DeviceName") ?? "iPhone"
            let productType = deviceValue(udid: udid, key: "ProductType") ?? "iPhone"
            return ConnectedDevice(
                udid: udid,
                name: name,
                type: USBDeviceList.deviceType(productType: productType)
            )
        }
    }

    private func deviceValue(udid: String, key: String) -> String? {
        guard let result = try? shell.run(["ideviceinfo", "-u", udid, "-k", key]),
              result.status == 0 else {
            return nil
        }
        return USBDeviceList.infoValue(from: result.output)
    }

    static func commandIsMissing(_ result: ShellOutput) -> Bool {
        result.status == 127 || result.output.localizedCaseInsensitiveContains("command not found")
    }
}

struct CompanionLocator {
    static let bundleIdentifier = "com.emiry.EmLoad"
    static let environmentKey = "EMLOADSERVER_COMPANION"

    var environment: [String: String]
    var searchRoots: [URL]
    var fileManager: FileManager
    var buildProject: (URL) throws -> URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default,
        buildProject: ((URL) throws -> URL)? = nil
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.searchRoots = searchRoots ?? Self.defaultSearchRoots(fileManager: fileManager)
        self.buildProject = buildProject ?? Self.buildWithXcode
    }

    func locate() throws -> URL {
        if let override = environment[Self.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else {
                throw SideloadError.companionNotFound(url.path)
            }
            return url
        }

        for root in searchRoots {
            for candidate in Self.candidates(in: root) where fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        for root in searchRoots {
            let project = root.appendingPathComponent("AltStore.xcodeproj")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return try buildProject(project)
            }
        }

        throw SideloadError.companionNotFound(nil)
    }

    /// Build from the checked-out EmLoad iOS Xcode project for this install.
    /// Existing .app and .ipa outputs are deliberately ignored so each install
    /// click gets a fresh build in its own private workspace.
    func buildFresh(in workspace: URL) throws -> URL {
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        for root in searchRoots {
            let project = root.appendingPathComponent("AltStore.xcodeproj", isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let buildSource = workspace.appendingPathComponent("EmLoadiOS", isDirectory: true)
                try fileManager.createDirectory(at: buildSource, withIntermediateDirectories: true)
                for item in [
                    "AltStore.xcodeproj", "AltStore", "AltWidget", "Shared", "SideBackup",
                    "SideStore", "Dependencies", "xcconfigs", "Build.xcconfig", "Makefile",
                    "SideStore.conf"
                ] {
                    let source = root.appendingPathComponent(item)
                    guard fileManager.fileExists(atPath: source.path) else {
                        throw SideloadError.companionNotFound(source.path)
                    }
                    try fileManager.copyItem(
                        at: source,
                        to: buildSource.appendingPathComponent(item)
                    )
                }
                for package in ["SideSign", "minimuxer"] {
                    let gitPointer = buildSource
                        .appendingPathComponent("Dependencies", isDirectory: true)
                        .appendingPathComponent(package, isDirectory: true)
                        .appendingPathComponent(".git")
                    if fileManager.fileExists(atPath: gitPointer.path) {
                        try fileManager.removeItem(at: gitPointer)
                    }
                }
                let buildProject = buildSource.appendingPathComponent("AltStore.xcodeproj", isDirectory: true)
                return try Self.buildWithXcode(projectURL: buildProject, productsDirectory: workspace)
            }
        }
        throw SideloadError.companionNotFound(nil)
    }

    static func candidates(in root: URL) -> [URL] {
        [
            root.appendingPathComponent("build/Release-iphoneos/SideStore.app"),
            root.appendingPathComponent("build/Debug-iphoneos/SideStore.app"),
            root.appendingPathComponent("artifacts/EmLoad.ipa"),
            root.appendingPathComponent("EmLoad.ipa"),
            root.appendingPathComponent("SideStore.app"),
            root.appendingPathComponent("EmLoad.app")
        ]
    }

    static func ancestors(of url: URL, limit: Int = 8) -> [URL] {
        var current = url.standardizedFileURL
        var results: [URL] = []
        for _ in 0..<limit {
            results.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return results
    }

    static func defaultSearchRoots(fileManager: FileManager) -> [URL] {
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        var seeds = ancestors(of: current) + ancestors(of: executable)
        if let bundledProject = Bundle.main.resourceURL?.appendingPathComponent("EmLoadiOS", isDirectory: true) {
            seeds.append(bundledProject)
        }
        if let root = ProcessInfo.processInfo.environment["EMLOAD_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !root.isEmpty {
            seeds.append(URL(fileURLWithPath: root, isDirectory: true))
        }
        let home = fileManager.homeDirectoryForCurrentUser
        seeds.append(home.appendingPathComponent("EmLoad", isDirectory: true))
        seeds.append(home.appendingPathComponent("Developer/EmLoad", isDirectory: true))

        var seen = Set<String>()
        var roots: [URL] = []
        for seed in seeds {
            for candidate in [seed, seed.appendingPathComponent("EmLoadiOS", isDirectory: true)] {
                let path = candidate.standardizedFileURL.path
                if seen.insert(path).inserted {
                    roots.append(candidate.standardizedFileURL)
                }
            }
        }
        return roots
    }

    static func buildWithXcode(projectURL: URL) throws -> URL {
        let products = projectURL.deletingLastPathComponent().appendingPathComponent("build", isDirectory: true)
        return try buildWithXcode(projectURL: projectURL, productsDirectory: products)
    }

    static func buildWithXcode(projectURL: URL, productsDirectory products: URL) throws -> URL {
        let derivedData = products.appendingPathComponent("DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(
            at: products,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: derivedData,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let result = try ShellCommand().run([
            "xcodebuild",
            "-project", projectURL.path,
            "-scheme", "SideStore",
            "-configuration", "Release",
            "-sdk", "iphoneos",
            "-derivedDataPath", derivedData.path,
            "CODE_SIGNING_ALLOWED=NO",
            "CODE_SIGNING_REQUIRED=NO",
            "CODE_SIGN_IDENTITY=",
            "SYMROOT=\(products.path)",
            "clean",
            "build"
        ])
        guard result.status == 0 else {
            throw SideloadError.buildFailed(Self.tail(result.output))
        }
        let app = products.appendingPathComponent("Release-iphoneos/SideStore.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw SideloadError.companionNotFound(app.path)
        }
        return app
    }

    static func alignBundleIdentifier(of appURL: URL, to bundleIdentifier: String) throws {
        guard !bundleIdentifier.contains("*") else { return }
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainersAndLeaves,
            format: &format
        ) as? [String: Any] else {
            throw SideloadError.invalidCompanion("\(infoURL.path) is not a property-list dictionary.")
        }
        plist["CFBundleIdentifier"] = bundleIdentifier
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: infoURL, options: .atomic)
    }

    private static func tail(_ output: String) -> String {
        let allLines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let errors = allLines.filter { $0.localizedCaseInsensitiveContains("error:") }.suffix(8)
        let tail = allLines.suffix(12)
        var seen = Set<String>()
        let lines = (Array(errors) + Array(tail)).filter { seen.insert($0).inserted }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "xcodebuild failed." : text
    }
}

struct CompanionSideload {
    var shell = ShellCommand()
    var locator = CompanionLocator()
    var portal = DeveloperPortal()

    func install(
        session: AuthSession,
        devices: [ConnectedDevice],
        progress: ((Double?, String) -> Void)? = nil
    ) async throws {
        guard !devices.isEmpty else { return }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmLoad-Install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        defer { try? FileManager.default.removeItem(at: workspace) }

        progress?(0.04, "Checking Apple developer account…")
        let teams = try await portal.fetchTeams(for: session.account, session: session.session)
        guard let team = USBDeviceList.preferredTeam(in: teams) else {
            throw SideloadError.noTeam
        }

        progress?(0.12, "Preparing signing identity…")
        let keyStore = try await signingIdentity(for: team, session: session.session)
        for (index, device) in devices.enumerated() {
            try pair(device)
            try await register(device, team: team, session: session.session)
            let completed = Double(index + 1) / Double(devices.count)
            progress?(0.22 + completed * 0.12, "Pairing \(device.name)…")
        }

        progress?(0.38, "Preparing app identifier…")
        let appID = try await ensureAppID(
            bundleIdentifier: CompanionLocator.bundleIdentifier,
            suggestedName: "EmLoadiOS Companion",
            existing: try await portal.fetchAppIDs(for: team, session: session.session),
            team: team,
            session: session.session
        )
        progress?(0.48, "Preparing device provisioning profile…")
        let profile = try await portal.downloadProvisioningProfile(
            for: appID,
            deviceType: .iPhone,
            team: team,
            session: session.session
        )
        try ensureProfileIncludes(devices, profile: profile)

        // Do all Apple Developer Portal work before the potentially long first
        // Xcode dependency build, so an expiring Apple session does not leave an
        // otherwise successful install waiting on a stale portal session.
        let xcodeProducts = workspace.appendingPathComponent("XcodeProducts", isDirectory: true)
        progress?(nil, "Building EmLoad with Xcode…")
        let companion = try locator.buildFresh(in: xcodeProducts)
        progress?(0.78, "Xcode build complete. Preparing signed IPA…")

        let signedDirectory = workspace.appendingPathComponent("SignedIPA", isDirectory: true)
        try FileManager.default.createDirectory(
            at: signedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        progress?(nil, "Signing the IPA…")
        let ipa = try await signedIPA(
            from: companion,
            profile: profile,
            team: team,
            keyStore: keyStore,
            workDirectory: signedDirectory
        )
        progress?(0.90, "Signed IPA ready. Installing…")
        for (index, device) in devices.enumerated() {
            progress?(nil, "Installing on \(device.name)…")
            try install(ipa, on: device)
            let completed = Double(index + 1) / Double(devices.count)
            progress?(0.90 + completed * 0.10, "Installed on \(device.name)")
        }
    }

    func identityTransfer(session: AuthSession) async throws -> EmLoadIdentityTransfer {
        let teams = try await portal.fetchTeams(for: session.account, session: session.session)
        guard let team = USBDeviceList.preferredTeam(in: teams) else {
            throw SideloadError.noTeam
        }
        let keyStore = try await signingIdentity(for: team, session: session.session)
        let password = UUID().uuidString + UUID().uuidString
        let p12 = try keyStore.exportP12(password: password)
        return EmLoadIdentityTransfer(
            authSession: session,
            team: team,
            certificate: p12,
            certificatePassword: password
        )
    }

    func installIPA(
        at ipaURL: URL,
        on device: ConnectedDevice,
        session: AuthSession,
        progress: ((String) -> Void)? = nil
    ) async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmLoad-IPA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        defer { try? FileManager.default.removeItem(at: workspace) }

        progress?("Checking Apple developer account…")
        let teams = try await portal.fetchTeams(for: session.account, session: session.session)
        guard let team = USBDeviceList.preferredTeam(in: teams) else {
            throw SideloadError.noTeam
        }
        let keyStore = try await signingIdentity(for: team, session: session.session)

        progress?("Preparing device registration…")
        try pair(device)
        try await register(device, team: team, session: session.session)

        progress?("Reading IPA…")
        let appURL = try FileManager.default.unzipAppBundle(at: ipaURL, to: workspace)
        guard let appBundle = AppBundle(fileURL: appURL) else {
            throw SideloadError.invalidIPA("The archive does not contain a valid iOS application.")
        }

        var bundleIDs = [appBundle.bundleIdentifier]
        bundleIDs.append(contentsOf: appBundle.appExtensions.map(\.bundleIdentifier))
        var seenBundleIDs = Set<String>()
        bundleIDs = bundleIDs.filter { seenBundleIDs.insert($0).inserted }
        guard !bundleIDs.isEmpty, bundleIDs.allSatisfy({ !$0.isEmpty && !$0.contains("*") }) else {
            throw SideloadError.invalidIPA("The IPA contains an invalid bundle identifier.")
        }

        progress?("Preparing app identifiers and profiles…")
        let existingIDs = try await portal.fetchAppIDs(for: team, session: session.session)
        var profiles: [ProvisioningProfile] = []
        for bundleID in bundleIDs {
            let appID = try await ensureAppID(
                bundleIdentifier: bundleID,
                suggestedName: bundleID,
                existing: existingIDs,
                team: team,
                session: session.session
            )
            let profile = try await portal.downloadProvisioningProfile(
                for: appID,
                deviceType: device.type,
                team: team,
                session: session.session
            )
            try ensureProfileIncludes([device], profile: profile)
            profiles.append(profile)
        }

        progress?("Signing IPA…")
        let signer = AppBundleSigner(team: team, keyStore: keyStore)
        try await signer.signApp(at: appURL, provisioningProfiles: profiles)
        let signedIPA = try FileManager.default.zipAppBundle(at: appURL)

        progress?("Installing on \(device.name)…")
        try install(signedIPA, on: device)
    }

    private func signingIdentity(for team: Team, session: Session) async throws -> KeyStore {
        if let saved = try AppleAccountService.savedSigningIdentity() {
            let certificates = try await portal.fetchCertificates(for: team, session: session)
            let serial = saved.certificate.serialNumberHex
            if certificates.contains(where: { $0.serialNumberHex.caseInsensitiveCompare(serial) == .orderedSame }) {
                return saved
            }
        }

        let sanitizedHost = String(
            ProcessInfo.processInfo.hostName.prefix(40).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        )
        let machineName = sanitizedHost.isEmpty ? "EmLoadServer" : "EmLoadServer-\(sanitizedHost)"
        let created = try await portal.addCertificate(
            machineName: machineName,
            type: .development,
            to: team,
            session: session
        )
        try AppleAccountService.saveSigningIdentity(created)
        return created
    }

    private func register(_ device: ConnectedDevice, team: Team, session: Session) async throws {
        let name = String(device.name.prefix(50))
        do {
            _ = try await portal.registerDevice(
                name: name.isEmpty ? "iPhone" : name,
                identifier: device.udid,
                type: device.type,
                team: team,
                session: session
            )
        } catch DeveloperPortalError.deviceAlreadyRegistered {
            return
        }
    }

    private func ensureAppID(
        bundleIdentifier: String,
        suggestedName: String,
        existing: [AppID],
        team: Team,
        session: Session
    ) async throws -> AppID {
        if let match = existing.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }) {
            return match
        }
        do {
            return try await portal.addAppID(
                withName: String(suggestedName.prefix(50)),
                bundleIdentifier: bundleIdentifier,
                team: team,
                session: session
            )
        } catch DeveloperPortalError.bundleIdentifierUnavailable {
            let refreshed = try await portal.fetchAppIDs(for: team, session: session)
            if let match = refreshed.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }) {
                return match
            }
            throw SideloadError.appIDUnavailable(bundleIdentifier)
        }
    }

    private func ensureProfileIncludes(_ devices: [ConnectedDevice], profile: ProvisioningProfile) throws {
        guard !profile.deviceIDs.isEmpty else { return }
        let allowed = Set(profile.deviceIDs.map { Self.normalize($0) })
        for device in devices where !allowed.contains(Self.normalize(device.udid)) {
            throw SideloadError.deviceNotInProfile(device.name)
        }
    }

    private func signedIPA(
        from companion: URL,
        profile: ProvisioningProfile,
        team: Team,
        keyStore: KeyStore,
        workDirectory work: URL
    ) async throws -> URL {
        let appURL: URL
        if companion.pathExtension.lowercased() == "ipa" {
            appURL = try FileManager.default.unzipAppBundle(at: companion, to: work)
        } else {
            let destination = work.appendingPathComponent("EmLoad.app", isDirectory: true)
            try FileManager.default.copyItem(at: companion, to: destination)
            appURL = destination
        }
        try CompanionLocator.alignBundleIdentifier(of: appURL, to: profile.bundleIdentifier)
        if let source = CompanionIcon.bundledSource() {
            try CompanionIcon.apply(to: appURL, source: source, shell: shell)
        }
        let signer = AppBundleSigner(team: team, keyStore: keyStore)
        try await signer.signApp(at: appURL, provisioningProfiles: [profile])
        return try FileManager.default.zipAppBundle(at: appURL)
    }

    private func pair(_ device: ConnectedDevice) throws {
        try requireSuccess(
            try shell.run(["idevicepair", "-u", device.udid, "pair"]),
            missing: "idevicepair",
            failure: SideloadError.pairFailed
        )
        try requireSuccess(
            try shell.run(["idevicepair", "-u", device.udid, "validate"]),
            missing: "idevicepair",
            failure: SideloadError.pairFailed
        )
    }

    private func install(_ ipa: URL, on device: ConnectedDevice) throws {
        let installer = try shell.run(["ideviceinstaller", "-u", device.udid, "install", ipa.path])
        if installer.status == 0 { return }
        if USBDeviceScanner.commandIsMissing(installer) {
            let devicectl = try shell.run([
                "xcrun", "devicectl", "device", "install", "app",
                "--device", device.udid,
                ipa.path
            ])
            if devicectl.status == 0 { return }
            throw SideloadError.installFailed(device.name, Self.detail(devicectl.output))
        }
        throw SideloadError.installFailed(device.name, Self.detail(installer.output))
    }

    private func requireSuccess(
        _ result: ShellOutput,
        missing tool: String,
        failure: (String) -> SideloadError
    ) throws {
        if result.status == 0 { return }
        if USBDeviceScanner.commandIsMissing(result) {
            throw SideloadError.missingTool(tool)
        }
        throw failure(Self.detail(result.output))
    }

    private static func normalize(_ udid: String) -> String {
        udid.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func detail(_ output: String) -> String {
        output.isEmpty ? "The installer returned a non-zero status." : output
    }
}

enum CompanionIcon {
    static let resourceName = "EmLoadiOS"

    struct Slot {
        let filename: String
        let pixels: Int
    }

    static let slots = [
        Slot(filename: "AppIcon60x60@2x.png", pixels: 120),
        Slot(filename: "AppIcon60x60@3x.png", pixels: 180),
        Slot(filename: "AppIcon76x76@2x~ipad.png", pixels: 152),
        Slot(filename: "AppIcon83.5x83.5@2x~ipad.png", pixels: 167)
    ]

    static func bundledSource() -> URL? {
        Bundle.module.url(forResource: resourceName, withExtension: "png", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: resourceName, withExtension: "png")
    }

    static func apply(
        to appURL: URL,
        source: URL,
        shell: ShellCommand = ShellCommand(),
        fileManager: FileManager = .default
    ) throws {
        for slot in slots {
            let destination = appURL.appendingPathComponent(slot.filename)
            let result = try shell.run([
                "sips",
                "-z", String(slot.pixels), String(slot.pixels),
                source.path,
                "--out", destination.path
            ])
            guard result.status == 0, fileManager.fileExists(atPath: destination.path) else {
                let details = result.output.isEmpty ? "sips could not write \(slot.filename)." : result.output
                throw SideloadError.iconFailed(details)
            }
        }

        let catalog = appURL.appendingPathComponent("Assets.car")
        if fileManager.fileExists(atPath: catalog.path) {
            try fileManager.removeItem(at: catalog)
        }
        try removeCatalogIconName(from: appURL.appendingPathComponent("Info.plist"))
    }

    static func removeCatalogIconName(from infoURL: URL) throws {
        let data = try Data(contentsOf: infoURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: .mutableContainersAndLeaves,
            format: &format
        ) as? [String: Any] else {
            throw SideloadError.iconFailed("\(infoURL.lastPathComponent) is not a property-list dictionary.")
        }
        plist["CFBundleIcons"] = iconDictionary(files: ["AppIcon60x60"])
        plist["CFBundleIcons~ipad"] = iconDictionary(files: ["AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5"])
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try updated.write(to: infoURL, options: .atomic)
    }

    private static func iconDictionary(files: [String]) -> [String: Any] {
        ["CFBundlePrimaryIcon": ["CFBundleIconFiles": files]]
    }
}

enum SideloadError: LocalizedError {
    case missingTool(String)
    case deviceListFailed(String)
    case companionNotFound(String?)
    case buildFailed(String)
    case invalidCompanion(String)
    case invalidIPA(String)
    case noTeam
    case appIDUnavailable(String)
    case deviceNotInProfile(String)
    case pairFailed(String)
    case installFailed(String, String)
    case iconFailed(String)
    case couldNotStart(String, String)

    var isDiscoveryFailure: Bool {
        switch self {
        case .missingTool, .deviceListFailed:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingTool(let tool):
            return "\(tool) is not installed, so a USB-connected iPhone or iPad could not be checked. Install libimobiledevice and ideviceinstaller, then sign in again with the device connected."
        case .deviceListFailed(let details):
            return "Could not list USB devices. \(details)"
        case .companionNotFound(let path):
            return path.map { "EmLoad was not found at \($0)." }
                ?? "The EmLoad iOS Xcode project was not found. Reinstall EmLoad Desktop or set EMLOAD_ROOT to an EmLoad source checkout."
        case .buildFailed(let details):
            return "Could not build EmLoad. \(details)"
        case .invalidCompanion(let details):
            return details
        case .invalidIPA(let details):
            return details
        case .noTeam:
            return "This Apple ID is not a member of a development team, so EmLoad could not be signed."
        case .appIDUnavailable(let bundleIdentifier):
            return "Apple would not register the App ID \(bundleIdentifier)."
        case .deviceNotInProfile(let name):
            return "The provisioning profile does not include \(name)."
        case .pairFailed(let details):
            return "Could not pair the connected device. Unlock it, approve the Trust prompt, and sign in again. \(details)"
        case .installFailed(let name, let details):
            return "Could not install EmLoad on \(name). \(details)"
        case .iconFailed(let details):
            return "Could not apply the EmLoad icon. \(details)"
        case .couldNotStart(let tool, let reason):
            return "Could not start \(tool): \(reason)"
        }
    }
}
