import AppKit
import Darwin
import Foundation

/// A GitHub release version such as `0.1.0-beta2`.
struct ReleaseVersion: Equatable, Comparable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int
    /// `beta`, `rc`, `alpha`, or `preview`. Nil is a final release.
    var prereleaseKind: String?
    var prereleaseNumber: Int

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard let prereleaseKind else { return core }
        return "\(core)-\(prereleaseKind)\(prereleaseNumber)"
    }

    /// `EmLoadRelease` when the release build stamped one, otherwise the short version.
    static func current(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> ReleaseVersion {
        if let stamped = info["EmLoadRelease"] as? String, let parsed = parse(stamped) {
            return parsed
        }
        if let short = info["CFBundleShortVersionString"] as? String, let parsed = parse(short) {
            return parsed
        }
        return ReleaseVersion(major: 0, minor: 0, patch: 0, prereleaseKind: nil, prereleaseNumber: 0)
    }

    static func parse(_ raw: String) -> ReleaseVersion? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") {
            text.removeFirst()
        }
        let pattern = #"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.]+))?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let major = int(text, match.range(at: 1)),
              let minor = int(text, match.range(at: 2)),
              let patch = int(text, match.range(at: 3))
        else { return nil }

        var kind: String?
        var number = 0
        if match.range(at: 4).location != NSNotFound, let ident = slice(text, match.range(at: 4)) {
            let cleaned = ident.replacingOccurrences(of: ".", with: "")
            let letters = cleaned.prefix { $0.isLetter }.lowercased()
            let digits = cleaned.drop { $0.isLetter }
            guard !letters.isEmpty else { return nil }
            kind = String(letters)
            number = Int(digits) ?? 0
        }
        return ReleaseVersion(
            major: major,
            minor: minor,
            patch: patch,
            prereleaseKind: kind,
            prereleaseNumber: number
        )
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let core = (lhs.major, lhs.minor, lhs.patch)
        let other = (rhs.major, rhs.minor, rhs.patch)
        if core != other { return core < other }
        switch (lhs.prereleaseKind, rhs.prereleaseKind) {
        case (nil, nil):
            return false
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case let (left?, right?):
            let leftRank = rank(left)
            let rightRank = rank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            if left != right { return left < right }
            return lhs.prereleaseNumber < rhs.prereleaseNumber
        }
    }

    private static func rank(_ kind: String) -> Int {
        switch kind {
        case "alpha", "a": return 0
        case "beta", "b": return 1
        case "preview": return 2
        case "rc": return 3
        default: return 1
        }
    }

    private static func int(_ text: String, _ range: NSRange) -> Int? {
        guard let slice = slice(text, range) else { return nil }
        return Int(slice)
    }

    private static func slice(_ text: String, _ range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}

struct AppUpdate: Identifiable, Equatable {
    var id: String { tag }
    var tag: String
    var title: String
    var notes: String
    var htmlURL: URL
    var assetName: String
    var downloadURL: URL
    var version: ReleaseVersion
    var prerelease: Bool
}

struct GitHubReleaseAsset: Equatable {
    var name: String
    var url: String
}

struct GitHubRelease: Equatable {
    var tagName: String
    var name: String
    var body: String
    var prerelease: Bool
    var draft: Bool
    var htmlURL: String
    var assets: [GitHubReleaseAsset]
}

enum UpdateApplyResult: Equatable {
    case relaunching
    case savedToDownloads(URL)
}

enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

enum AppUpdateChecker {
    static let repository = "EmTechFlagship/EmLoadServer"
    static let releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func latest(newerThan current: ReleaseVersion) async throws -> AppUpdate? {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 20
        request.setValue("EmLoad", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UpdateError.message("GitHub returned HTTP \(status) while checking for updates.")
        }
        let releases = try parseReleases(data)
        return select(releases: releases, current: current, architecture: architecture)
    }

    static func parseReleases(_ data: Data) throws -> [GitHubRelease] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let error = object as? [String: Any] {
            let message = (error["message"] as? String) ?? "GitHub returned an unexpected response."
            throw UpdateError.message(message)
        }
        guard let rows = object as? [[String: Any]] else {
            throw UpdateError.message("GitHub returned an unexpected release list.")
        }
        return rows.compactMap(parseRelease)
    }

    static func select(
        releases: [GitHubRelease],
        current: ReleaseVersion,
        architecture: String
    ) -> AppUpdate? {
        let ranked = releases.compactMap { release -> (ReleaseVersion, GitHubRelease)? in
            guard !release.draft, let version = ReleaseVersion.parse(release.tagName), version > current else {
                return nil
            }
            return (version, release)
        }.sorted { $0.0 > $1.0 }

        for (version, release) in ranked {
            guard let asset = chooseAsset(from: release.assets, architecture: architecture),
                  let downloadURL = URL(string: asset.url),
                  isTrustedDownload(downloadURL),
                  let htmlURL = URL(string: release.htmlURL)
            else { continue }
            let title = release.name.isEmpty ? "EmLoad \(version.description)" : release.name
            return AppUpdate(
                tag: release.tagName,
                title: title,
                notes: notes(from: release.body),
                htmlURL: htmlURL,
                assetName: asset.name,
                downloadURL: downloadURL,
                version: version,
                prerelease: release.prerelease
            )
        }
        return nil
    }

    /// Prefer this Mac's app archive (`EmLoad-<version>-macos[-arch].zip`) over
    /// the older wrapper that bundles that zip together with a disk image.
    static func chooseAsset(
        from assets: [GitHubReleaseAsset],
        architecture: String
    ) -> GitHubReleaseAsset? {
        let zips = assets.filter { isMacZip($0.name) }
        let archSuffix = "-macos-\(architecture).zip"
        if let matched = zips.first(where: { $0.name.lowercased().hasSuffix(archSuffix) }) {
            return matched
        }
        if let universal = zips.first(where: { $0.name.lowercased().hasSuffix("-macos.zip") }) {
            return universal
        }
        return zips.first { asset in
            let name = asset.name.lowercased()
            if name.contains("arm64") || name.contains("aarch64") { return architecture == "arm64" }
            if name.contains("x86_64") || name.contains("intel") { return architecture == "x86_64" }
            return !name.contains("arm64") && !name.contains("aarch64")
                && !name.contains("x86_64") && !name.contains("intel")
        }
    }

    static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        guard host == "github.com" || host == "www.github.com" else { return false }
        return url.path.contains("/EmTechFlagship/") && url.path.contains("/releases/download/")
    }

    private static func parseRelease(_ row: [String: Any]) -> GitHubRelease? {
        guard let tag = row["tag_name"] as? String else { return nil }
        let assets = (row["assets"] as? [[String: Any]] ?? []).compactMap { asset -> GitHubReleaseAsset? in
            guard let name = asset["name"] as? String,
                  let url = asset["browser_download_url"] as? String
            else { return nil }
            return GitHubReleaseAsset(name: name, url: url)
        }
        return GitHubRelease(
            tagName: tag,
            name: (row["name"] as? String) ?? "",
            body: (row["body"] as? String) ?? "",
            prerelease: (row["prerelease"] as? Bool) ?? false,
            draft: (row["draft"] as? Bool) ?? false,
            htmlURL: (row["html_url"] as? String) ?? "",
            assets: assets
        )
    }

    private static func isMacZip(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".zip") && lower.contains("macos") && !lower.contains("win")
    }

    private static func notes(from body: String) -> String {
        let trimmed = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 700 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 700)
        return String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

enum AppUpdateInstaller {
    static func apply(
        _ update: AppUpdate,
        bundle: URL = Bundle.main.bundleURL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> UpdateApplyResult {
        let downloaded = try await download(update, onProgress: onProgress)
        guard bundle.pathExtension == "app" else {
            return .savedToDownloads(try saveDownload(downloaded, named: update.assetName))
        }
        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .savedToDownloads(try saveDownload(downloaded, named: update.assetName))
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmLoadUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let app = try locateApp(in: downloaded, scratch: staging)
        try launchReplacer(app: app, destination: bundle)
        return .relaunching
    }

    private static func download(
        _ update: AppUpdate,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard AppUpdateChecker.isTrustedDownload(update.downloadURL) else {
            throw UpdateError.message("The update link is not a GitHub release asset.")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmLoad-\(UUID().uuidString).zip")
        let downloader = UpdateDownloader(destination: destination, onProgress: onProgress)
        return try await downloader.download(update.downloadURL)
    }

    private static func saveDownload(_ file: URL, named name: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safeName = name.isEmpty ? "EmLoad-update.zip" : name
        var destination = downloads.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stem = destination.deletingPathExtension().lastPathComponent
            destination = downloads.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).zip")
        }
        try FileManager.default.copyItem(at: file, to: destination)
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        return destination
    }

    private static func locateApp(zip: URL, scratch: URL) throws -> URL {
        let extracted = scratch.appendingPathComponent("archive", isDirectory: true)
        try extractZip(zip, to: extracted)
        return try locateApp(in: extracted, depth: 0)
    }

    private static func locateApp(in downloadedZip: URL, scratch: URL) throws -> URL {
        try locateApp(zip: downloadedZip, scratch: scratch)
    }

    private static func locateApp(in root: URL, depth: Int) throws -> URL {
        if depth > 2 {
            throw UpdateError.message("The update archive does not contain EmLoad.app.")
        }
        let items = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        if let app = items.first(where: { $0.lastPathComponent == "EmLoad.app" }) {
            return app
        }
        for item in items {
            let nested = item.appendingPathComponent("EmLoad.app")
            if FileManager.default.fileExists(atPath: nested.path) {
                return nested
            }
        }
        if let zip = items.first(where: { isNestedMacZip($0.lastPathComponent) }) {
            let inner = root.appendingPathComponent("inner-\(depth)", isDirectory: true)
            try extractZip(zip, to: inner)
            return try locateApp(in: inner, depth: depth + 1)
        }
        if let image = items.first(where: { $0.pathExtension.lowercased() == "dmg" }) {
            return try app(fromDiskImage: image, scratch: root)
        }
        throw UpdateError.message("The update archive does not contain EmLoad.app.")
    }

    private static func app(fromDiskImage image: URL, scratch: URL) throws -> URL {
        let mount = scratch.appendingPathComponent("mnt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, image.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
        let mounted = mount.appendingPathComponent("EmLoad.app")
        guard FileManager.default.fileExists(atPath: mounted.path) else {
            throw UpdateError.message("The disk image does not contain EmLoad.app.")
        }
        let copy = scratch.appendingPathComponent("EmLoad.app")
        try run("/usr/bin/ditto", [mounted.path, copy.path])
        return copy
    }

    private static func extractZip(_ zip: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", zip.path])
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, destination.path])
    }

    private static func launchReplacer(app: URL, destination: URL) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent("EmLoad/update", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("apply-update.sh")
        let logURL = directory.appendingPathComponent("update.log")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -u
        pid=\(pid)
        src=\(shellQuote(app.path))
        dest=\(shellQuote(destination.path))
        log=\(shellQuote(logURL.path))
        {
          echo "waiting for $pid"
          while /bin/kill -0 "$pid" 2>/dev/null; do
            /bin/sleep 0.2
          done
          /bin/sleep 0.4
          stage="${dest}.update"
          /bin/rm -rf "$stage"
          /usr/bin/ditto "$src" "$stage"
          /usr/bin/xattr -dr com.apple.quarantine "$stage" || true
          if /bin/rm -rf "$dest" && /bin/mv "$stage" "$dest"; then
            /usr/bin/open "$dest"
          else
            /usr/bin/open "$stage"
          fi
          echo "relaunched"
        } >> "$log" 2>&1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try DetachedProcess.launch(scriptPath: scriptURL.path)
    }

    private static func isNestedMacZip(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".zip") && lower.contains("macos") && !lower.contains("win")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw UpdateError.message("\(name) could not unpack the update.")
        }
    }
}

private enum DetachedProcess {
    static func launch(scriptPath: String) throws {
        var attributes: posix_spawnattr_t?
        let initialized = posix_spawnattr_init(&attributes)
        guard initialized == 0 else {
            throw UpdateError.message("Could not start the updater (\(initialized)).")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flagged = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        guard flagged == 0 else {
            throw UpdateError.message("Could not detach the updater (\(flagged)).")
        }

        let bash = strdup("/bin/bash")
        let script = strdup(scriptPath)
        defer {
            free(bash)
            free(script)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = [bash, script, nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/bash", nil, &attributes, &argv, environ)
        guard spawned == 0, pid > 0 else {
            throw UpdateError.message("Could not start the updater (\(spawned)).")
        }
    }
}

private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("EmLoad", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else {
                throw UpdateError.message("GitHub returned HTTP \(status) while downloading the update.")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            complete(.success(destination))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    private func complete(_ result: Result<URL, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}
