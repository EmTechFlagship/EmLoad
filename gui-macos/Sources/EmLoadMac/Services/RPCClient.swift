import Foundation

/// A progress step reported by a long-running engine call.
struct EngineProgress {
    let phase: String
    let percent: Double?
    let step: String?
}

/// An error the engine reported deliberately (a situation, not a crash).
struct EngineFailure: LocalizedError {
    let message: String
    let kind: String

    var errorDescription: String? { message }
}

/// Owns the long-lived `emload rpc` Python process and speaks newline-delimited
/// JSON to it.
///
/// Every request gets a correlation id; responses resolve the matching
/// continuation. Progress/log events are delivered on the main queue so views
/// can update `@State` directly. Unsolicited events (device attach/detach,
/// auto-provision results, EmSideStore results) surface through `onEvent`.
final class RPCClient {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var pending: [Int64: Pending] = [:]
    private var nextID: Int64 = 0
    private var readySignaled = false
    private var readyError: Error?
    private let readySemaphore = DispatchSemaphore(value: 0)
    private var shuttingDown = false

    private(set) var version = "?"

    /// Every unsolicited engine event, already parsed. Called on the main queue.
    var onEvent: (([String: Any]) -> Void)?
    /// Raw stderr lines (library warnings, tracebacks). Called on the main queue.
    var onStderr: ((String) -> Void)?
    /// The bridge process ended. Called on the main queue.
    var onExit: ((String) -> Void)?

    private struct Pending {
        let continuation: CheckedContinuation<Any, Error>
        let onProgress: ((EngineProgress) -> Void)?
        let onLog: ((String) -> Void)?
    }

    // MARK: - Lifecycle

    static func start() throws -> RPCClient {
        let location = PythonLocator.locate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: location.python)
        process.arguments = ["-m", "emload", "rpc"]
        process.currentDirectoryURL = URL(fileURLWithPath: location.root)

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw EngineFailure(
                message: "Could not start the EmLoad engine.\n\n\(location.python)\n\n\(error.localizedDescription)",
                kind: "StartFailed"
            )
        }

        let client = RPCClient(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
        client.startReaders()

        if client.readySemaphore.wait(timeout: .now() + 90) == .timedOut {
            client.stop()
            throw EngineFailure(
                message: "The EmLoad engine did not start within 90 seconds.\n\n"
                    + "Python: \(location.python)\nRepo: \(location.root)\n\n"
                    + "Run `\(location.python) -m emload doctor` in Terminal to see why.",
                kind: "StartTimeout"
            )
        }
        if let error = client.readyError {
            client.stop()
            throw error
        }
        return client
    }

    private init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdinHandle = stdin
        self.stdoutHandle = stdout
        self.stderrHandle = stderr

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let failure = EngineFailure(
                message: "The EmLoad engine process exited (code \(proc.terminationStatus)).",
                kind: "Exited"
            )
            self.signalReady(failure)

            let orphaned = self.stateLock.sync {
                let copy = self.pending
                self.pending.removeAll()
                return copy
            }
            for (_, request) in orphaned {
                request.continuation.resume(throwing: failure)
            }

            guard !self.shuttingDown else { return }
            DispatchQueue.main.async {
                self.onExit?("The EmLoad engine exited (code \(proc.terminationStatus)).")
            }
        }
    }

    /// Stop the bridge process. Safe to call more than once.
    func stop() {
        shuttingDown = true
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
        }
        let orphaned = stateLock.sync {
            let copy = pending
            pending.removeAll()
            return copy
        }
        let failure = EngineFailure(message: "The EmLoad engine was stopped.", kind: "Stopped")
        for (_, request) in orphaned {
            request.continuation.resume(throwing: failure)
        }
    }

    // MARK: - Calls

    /// Send one request and wait for its response.
    func call(
        _ method: String,
        _ params: [String: Any] = [:],
        onProgress: ((EngineProgress) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) async throws -> Any {
        let id: Int64 = stateLock.sync {
            nextID += 1
            return nextID
        }
        let request: [String: Any] = ["id": id, "method": method, "params": params]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: request)
        } catch {
            throw EngineFailure(message: "Could not encode the request: \(error.localizedDescription)", kind: "EncodeFailed")
        }
        var line = data
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            stateLock.sync {
                pending[id] = Pending(
                    continuation: continuation,
                    onProgress: onProgress,
                    onLog: onLog
                )
            }
            do {
                writeLock.lock()
                defer { writeLock.unlock() }
                try stdinHandle.write(contentsOf: line)
            } catch {
                let removed = stateLock.sync { pending.removeValue(forKey: id) }
                removed?.continuation.resume(
                    throwing: EngineFailure(
                        message: "Lost the connection to the EmLoad engine. Restart the app.",
                        kind: "WriteFailed"
                    )
                )
            }
        }
    }

    // MARK: - Reader threads

    private func startReaders() {
        let stdout = stdoutHandle
        Thread.detachNewThread { [weak self] in
            self?.readLines(from: stdout, isStdout: true)
        }
        let stderr = stderrHandle
        Thread.detachNewThread { [weak self] in
            self?.readLines(from: stderr, isStdout: false)
        }
    }

    private func readLines(from handle: FileHandle, isStdout: Bool) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !lineData.isEmpty else { continue }
                if isStdout {
                    handleLine(lineData)
                } else if let text = String(data: lineData, encoding: .utf8), !text.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.onStderr?(text)
                    }
                }
            }
        }
    }

    private func handleLine(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return
        }

        if let event = root["event"] as? String {
            handleEvent(event, root)
            return
        }

        guard let idNumber = root["id"] as? NSNumber else { return }
        let id = idNumber.int64Value
        guard let request = stateLock.sync({ pending.removeValue(forKey: id) }) else { return }

        let ok = (root["ok"] as? NSNumber)?.boolValue ?? (root["ok"] as? Bool) ?? false
        if ok {
            request.continuation.resume(returning: root["result"] ?? NSNull())
            return
        }
        let message = (root["error"] as? String) ?? "Unknown engine error"
        let kind = (root["kind"] as? String) ?? "EngineError"
        request.continuation.resume(throwing: EngineFailure(message: message, kind: kind))
    }

    private func handleEvent(_ name: String, _ payload: [String: Any]) {
        if name == "ready" {
            version = (payload["version"] as? String) ?? "?"
            signalReady(nil)
        }

        if let idNumber = payload["id"] as? NSNumber {
            let id = idNumber.int64Value
            let request = stateLock.sync { pending[id] }
            switch name {
            case "progress":
                let update = EngineProgress(
                    phase: (payload["phase"] as? String) ?? "",
                    percent: (payload["percent"] as? NSNumber)?.doubleValue,
                    step: payload["step"] as? String
                )
                if let callback = request?.onProgress {
                    DispatchQueue.main.async { callback(update) }
                }
            case "log":
                let message = (payload["message"] as? String) ?? ""
                if !message.isEmpty, let callback = request?.onLog {
                    DispatchQueue.main.async { callback(message) }
                }
            default:
                break
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(payload)
        }
    }

    private func signalReady(_ error: Error?) {
        let shouldSignal: Bool = stateLock.sync {
            guard !readySignaled else { return false }
            readySignaled = true
            readyError = error
            return true
        }
        if shouldSignal { readySemaphore.signal() }
    }
}

private extension NSLock {
    func sync<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
