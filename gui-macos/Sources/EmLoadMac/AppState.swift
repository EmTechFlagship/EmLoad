import Foundation
import SwiftUI

/// Process-wide state: the engine client, the latest device inventory, the
/// persisted settings snapshot, and the shared activity log.
@MainActor
final class AppState: ObservableObject {
    @Published var engineVersion = "?"
    @Published var devices: [Device] = []
    @Published var settings = SettingsSnapshot()
    @Published var account: AccountStatus?
    @Published var statusMessage = "Starting the EmLoad engine…"
    @Published var isReady = false
    @Published var isBusy = false
    @Published var busyMessage = ""
    @Published var startupError: String?
    @Published var logs: [String] = []
    @Published var alertMessage: String?
    @Published var showLogin = false
    @Published var emstore: EmStoreStatus?

    private(set) var engine: RPCClient?
    private var started = false
    private let logLimit = 2_000

    var logText: String {
        logs.joined(separator: "\n")
    }

    // MARK: - Startup

    func initialize() async {
        guard !started else { return }
        started = true
        appendLog("Starting the EmLoad engine…")

        do {
            let client = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RPCClient, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try RPCClient.start())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            engine = client
            engineVersion = client.version
            wire(client)

            await reloadSettings()
            do {
                _ = try await call("watch.start")
            } catch {
                appendLog("Device watcher did not start: \(error.localizedDescription)")
            }
            await refreshDevices()
            await refreshAccount()

            isReady = true
            startupError = nil
            statusMessage = "Engine ready (emload \(engineVersion))"
            appendLog("Engine ready (emload \(engineVersion)).")
        } catch {
            let message = error.localizedDescription
            startupError = message
            statusMessage = "Engine offline"
            appendLog("Startup failed: \(message)")
        }
    }

    func retryStartup() {
        engine?.stop()
        engine = nil
        started = false
        startupError = nil
        isReady = false
        statusMessage = "Starting the EmLoad engine…"
        Task { await initialize() }
    }

    func shutdown() {
        engine?.stop()
        engine = nil
        isReady = false
    }

    private func wire(_ client: RPCClient) {
        client.onEvent = { [weak self] payload in
            Task { @MainActor in self?.handleEvent(payload) }
        }
        client.onStderr = { [weak self] line in
            Task { @MainActor in self?.appendLog("engine: \(line)") }
        }
        client.onExit = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.appendLog(message)
                self.statusMessage = message
                self.isReady = false
            }
        }
    }

    // MARK: - Calls

    /// Convenience wrapper that gives a useful error when the engine is offline.
    func call(
        _ method: String,
        _ params: [String: Any] = [:],
        onProgress: ((EngineProgress) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) async throws -> Any {
        guard let engine else {
            throw EngineFailure(
                message: "The EmLoad engine is not running. Restart the app.",
                kind: "Offline"
            )
        }
        return try await engine.call(method, params, onProgress: onProgress, onLog: onLog)
    }

    func refreshDevices() async {
        guard engine != nil else { return }
        do {
            devices = Device.list(from: try await call("devices.list"))
            statusMessage = devices.isEmpty
                ? "No device connected"
                : "\(devices.count) device(s) connected"
        } catch {
            statusMessage = "Could not list devices: \(error.localizedDescription)"
        }
    }

    func reloadSettings() async {
        guard engine != nil else { return }
        do {
            let raw = try await call("settings.get")
            settings = SettingsSnapshot(dictionary: JSON.dict(raw) ?? [:])
        } catch {
            appendLog("Could not load settings: \(error.localizedDescription)")
        }
    }

    func saveSettings(_ patch: [String: Any]) async {
        guard engine != nil else { return }
        do {
            let raw = try await call("settings.set", patch)
            settings = SettingsSnapshot(dictionary: JSON.dict(raw) ?? [:])
            statusMessage = "Settings saved"
        } catch {
            statusMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func refreshAccount() async {
        guard engine != nil else { return }
        do {
            let raw = try await call("account.status")
            var status = AccountStatus(dictionary: JSON.dict(raw) ?? [:])

            // A saved session exists but none is active: resume it, matching
            // the PySide6 window's startup behaviour.
            if !status.authenticated && status.accountCount > 0 {
                _ = try? await call("account.resume")
                let retried = try await call("account.status")
                status = AccountStatus(dictionary: JSON.dict(retried) ?? [:])
            }
            account = status
        } catch {
            appendLog("Account status unavailable: \(error.localizedDescription)")
        }
    }

    func refreshEmStore() async {
        guard engine != nil else { return }
        do {
            let raw = try await call("emstore.status")
            emstore = EmStoreStatus(dictionary: JSON.dict(raw) ?? [:])
        } catch {
            appendLog("EmSideStore status unavailable: \(error.localizedDescription)")
        }
    }

    // MARK: - Events

    private func handleEvent(_ payload: [String: Any]) {
        guard let name = payload["event"] as? String else { return }

        switch name {
        case "devices":
            devices = Device.list(from: payload["data"] ?? [])
            statusMessage = devices.isEmpty
                ? "No device connected"
                : "\(devices.count) device(s) connected"

        case "provision.result":
            let result = JSON.dict(payload["result"]) ?? [:]
            let status = JSON.string(result["status"]) ?? ""
            let udid = JSON.string(payload["udid"]) ?? ""
            if status == "reprovisioned" {
                appendLog("Provisioned \(udid) with a fresh certificate and profile.")
                statusMessage = "Provisioned a new device"
            }

        case "watch.error":
            let message = JSON.string(payload["message"]) ?? "unknown error"
            appendLog("Device watch: \(message)")
            statusMessage = "Device watch stopped (the device list still refreshes)"

        case "log":
            if let message = JSON.string(payload["message"]), !message.isEmpty {
                appendLog(message)
            }

        case "emstore.result":
            let result = JSON.dict(payload["result"]) ?? [:]
            let udid = JSON.string(payload["udid"]) ?? ""
            let status = JSON.string(result["status"]) ?? "unknown"
            let error = JSON.string(result["error"])
            if let error {
                appendLog("EmSideStore on \(udid) failed: \(error)")
            } else {
                appendLog("EmSideStore on \(udid): \(status)")
            }
            Task { await refreshEmStore() }

        default:
            break
        }
    }

    // MARK: - Logging / status

    func appendLog(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logs.append("\(stamp)  \(message)")
        if logs.count > logLimit {
            logs.removeFirst(logs.count - logLimit)
        }
    }

    func setBusy(_ busy: Bool, _ message: String? = nil) {
        isBusy = busy
        if let message { busyMessage = message }
        if !busy { busyMessage = "" }
    }

    func report(_ error: Error) {
        alertMessage = error.localizedDescription
        appendLog("error: \(error.localizedDescription)")
        statusMessage = "Something went wrong"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
