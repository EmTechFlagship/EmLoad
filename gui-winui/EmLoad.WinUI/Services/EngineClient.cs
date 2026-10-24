using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace EmLoad.WinUI.Services;

/// <summary>One unsolicited message from the engine (device list, progress, log).</summary>
public sealed record EngineEvent(string Name, JsonElement Payload)
{
    public long? RequestId =>
        Payload.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.Number
            ? id.GetInt64()
            : null;
}

/// <summary>A progress step reported by a long-running engine call.</summary>
public sealed record ProgressUpdate(string Phase, double? Percent, string? Step);

/// <summary>An error the engine reported deliberately (a situation, not a bug).</summary>
public sealed class EngineException : Exception
{
    public string Kind { get; }

    public EngineException(string message, string kind) : base(message) => Kind = kind;
}

/// <summary>
/// Owns the long-lived <c>emload rpc</c> Python process and speaks
/// newline-delimited JSON to it.
///
/// Every request gets a correlation id; responses resolve the matching
/// <see cref="TaskCompletionSource{JsonElement}"/>. Progress and log lines for
/// a request are routed to that request's callbacks, while unsolicited events
/// (device attach/detach, auto-provision results) surface on
/// <see cref="EventReceived"/> for whoever is listening.
/// </summary>
public sealed class EngineClient : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = null,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly Process _process;
    private readonly StreamWriter _stdin;
    private readonly ConcurrentDictionary<long, PendingRequest> _pending = new();
    private readonly object _writeLock = new();
    private readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private long _nextId;
    private volatile bool _disposed;

    public string PythonPath { get; }
    public string RepoRoot { get; }
    public string Version { get; private set; } = "?";

    /// <summary>Unsolicited events plus every progress/log line (for the status bar).</summary>
    public event Action<EngineEvent>? EventReceived;

    /// <summary>Raw stderr from Python (library warnings, tracebacks).</summary>
    public event Action<string>? EngineStderr;

    /// <summary>The bridge process ended (crash or shutdown).</summary>
    public event Action<string>? Exited;

    private sealed class PendingRequest
    {
        public required TaskCompletionSource<JsonElement> Completion { get; init; }
        public Action<ProgressUpdate>? Progress { get; init; }
        public Action<string>? Log { get; init; }
    }

    private EngineClient(Process process, string pythonPath, string repoRoot)
    {
        _process = process;
        PythonPath = pythonPath;
        RepoRoot = repoRoot;
        _stdin = process.StandardInput;
        _stdin.AutoFlush = true;

        new Thread(ReadStdoutLoop) { IsBackground = true, Name = "emload-rpc-out" }.Start();
        new Thread(ReadStderrLoop) { IsBackground = true, Name = "emload-rpc-err" }.Start();
        new Thread(WatchExitLoop) { IsBackground = true, Name = "emload-rpc-exit" }.Start();
    }

    public static async Task<EngineClient> StartAsync(CancellationToken ct = default)
    {
        var (python, root) = PythonLocator.Locate();

        var psi = new ProcessStartInfo(python)
        {
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        psi.ArgumentList.Add("-m");
        psi.ArgumentList.Add("emload");
        psi.ArgumentList.Add("rpc");

        Process process;
        try
        {
            process = Process.Start(psi) ?? throw new EngineException(
                $"could not start {python}", "StartFailed");
        }
        catch (Exception exc) when (exc is not EngineException)
        {
            throw new EngineException(
                $"Could not start the EmLoad engine.\n\n{python}\n\n{exc.Message}",
                "StartFailed");
        }

        var client = new EngineClient(process, python, root);
        await client.WaitReadyAsync(ct).ConfigureAwait(false);
        return client;
    }

    private async Task WaitReadyAsync(CancellationToken ct)
    {
        var timeout = Task.Delay(TimeSpan.FromSeconds(90), ct);
        var done = await Task.WhenAny(_ready.Task, timeout).ConfigureAwait(false);
        if (done == _ready.Task && _ready.Task.IsCompletedSuccessfully)
        {
            return;
        }
        Dispose();
        throw new EngineException(
            "The EmLoad engine did not start within 90 seconds.\n\n" +
            $"Python: {PythonPath}\nRepo: {RepoRoot}\n\n" +
            "Run `.venv\\Scripts\\python -m emload doctor` in the repo to see why.",
            "StartTimeout");
    }

    // ------------------------------------------------------------------ //
    // Calls
    // ------------------------------------------------------------------ //
    public async Task<JsonElement> CallAsync(
        string method,
        object? parameters = null,
        Action<ProgressUpdate>? onProgress = null,
        Action<string>? onLog = null,
        CancellationToken ct = default)
    {
        if (_disposed)
        {
            throw new EngineException("The engine connection is closed.", "Disposed");
        }

        var id = Interlocked.Increment(ref _nextId);
        var pending = new PendingRequest
        {
            Completion = new TaskCompletionSource<JsonElement>(
                TaskCreationOptions.RunContinuationsAsynchronously),
            Progress = onProgress,
            Log = onLog,
        };
        _pending[id] = pending;

        using var registration = ct.Register(() =>
        {
            if (_pending.TryRemove(id, out var entry))
            {
                entry.Completion.TrySetCanceled(ct);
            }
        });

        var request = JsonSerializer.Serialize(
            new Dictionary<string, object?>
            {
                ["id"] = id,
                ["method"] = method,
                ["params"] = parameters ?? new Dictionary<string, object?>(),
            },
            JsonOptions);

        try
        {
            lock (_writeLock)
            {
                _stdin.Write(request);
                _stdin.Write('\n');
            }
        }
        catch (Exception exc)
        {
            _pending.TryRemove(id, out _);
            throw new EngineException(
                "Lost the connection to the EmLoad engine. Restart the app.", "WriteFailed")
            {
                Source = exc.Message,
            };
        }

        return await pending.Completion.Task.ConfigureAwait(false);
    }

    /// <summary>Call a method and deserialize its result into <typeparamref name="T"/>.</summary>
    public async Task<T?> CallAsync<T>(
        string method,
        object? parameters = null,
        Action<ProgressUpdate>? onProgress = null,
        Action<string>? onLog = null,
        CancellationToken ct = default)
    {
        var result = await CallAsync(method, parameters, onProgress, onLog, ct)
            .ConfigureAwait(false);
        if (result.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return default;
        }
        return result.Deserialize<T>(new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        });
    }

    // ------------------------------------------------------------------ //
    // Reader threads
    // ------------------------------------------------------------------ //
    private void ReadStdoutLoop()
    {
        try
        {
            while (true)
            {
                var line = _process.StandardOutput.ReadLine();
                if (line is null)
                {
                    break;
                }
                line = line.Trim();
                if (line.Length == 0)
                {
                    continue;
                }
                try
                {
                    HandleLine(line);
                }
                catch (Exception exc)
                {
                    // One bad message (or a handler bug) must not stop the
                    // reader: a dead reader leaves every later call hanging.
                    EngineStderr?.Invoke(
                        $"engine message failed: {exc.GetType().Name}: {exc.Message}");
                }
            }
        }
        catch (Exception) when (_disposed)
        {
            // Shutdown race; nothing to report.
        }
        catch (Exception exc)
        {
            EngineStderr?.Invoke($"engine reader stopped: {exc.GetType().Name}: {exc.Message}");
        }
    }

    private void HandleLine(string line)
    {
        JsonElement root;
        try
        {
            using var document = JsonDocument.Parse(line);
            root = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            EngineStderr?.Invoke($"(non-JSON) {line}");
            return;
        }

        if (root.TryGetProperty("event", out var eventName))
        {
            HandleEvent(eventName.GetString() ?? "", root);
            return;
        }

        if (!root.TryGetProperty("id", out var idElement) ||
            idElement.ValueKind != JsonValueKind.Number)
        {
            return;
        }

        var id = idElement.GetInt64();
        if (!_pending.TryRemove(id, out var pending))
        {
            return;
        }

        var ok = root.TryGetProperty("ok", out var okElement) &&
                 okElement.ValueKind == JsonValueKind.True;
        if (!ok)
        {
            var message = root.TryGetProperty("error", out var err)
                ? err.GetString() ?? "Unknown engine error"
                : "Unknown engine error";
            var kind = root.TryGetProperty("kind", out var kindElement)
                ? kindElement.GetString() ?? "EngineError"
                : "EngineError";
            pending.Completion.TrySetException(new EngineException(message, kind));
            return;
        }

        pending.Completion.TrySetResult(
            root.TryGetProperty("result", out var result) ? result : default);
    }

    private void HandleEvent(string name, JsonElement payload)
    {
        if (name == "ready")
        {
            Version = payload.TryGetProperty("version", out var v)
                ? v.GetString() ?? "?"
                : "?";
            _ready.TrySetResult();
            return;
        }

        if (payload.TryGetProperty("id", out var idElement) &&
            idElement.ValueKind == JsonValueKind.Number &&
            _pending.TryGetValue(idElement.GetInt64(), out var pending))
        {
            switch (name)
            {
                case "progress":
                    pending.Progress?.Invoke(new ProgressUpdate(
                        GetString(payload, "phase") ?? "",
                        GetDouble(payload, "percent"),
                        GetString(payload, "step")));
                    break;
                case "log":
                    pending.Log?.Invoke(GetString(payload, "message") ?? "");
                    break;
            }
        }

        EventReceived?.Invoke(new EngineEvent(name, payload));
    }

    private void ReadStderrLoop()
    {
        try
        {
            while (_process.StandardError.ReadLine() is { } line)
            {
                if (line.Length > 0)
                {
                    EngineStderr?.Invoke(line);
                }
            }
        }
        catch (Exception)
        {
            // Stream closed during shutdown.
        }
    }

    private void WatchExitLoop()
    {
        try
        {
            _process.WaitForExit();
        }
        catch (Exception)
        {
            // Already gone.
        }

        _ready.TrySetException(new EngineException(
            "The engine process exited during startup.", "StartFailed"));

        foreach (var (id, pending) in _pending)
        {
            if (_pending.TryRemove(id, out _))
            {
                pending.Completion.TrySetException(new EngineException(
                    "The EmLoad engine process exited. Restart the app.", "Exited"));
            }
        }

        if (!_disposed)
        {
            Exited?.Invoke($"The EmLoad engine exited (code {SafeExitCode()}).");
        }
    }

    private int? SafeExitCode()
    {
        try
        {
            return _process.ExitCode;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string? GetString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static double? GetDouble(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDouble()
            : null;

    // ------------------------------------------------------------------ //
    // Shutdown
    // ------------------------------------------------------------------ //
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        try
        {
            _stdin.Close();
        }
        catch (Exception)
        {
            // Already closed.
        }

        try
        {
            if (!_process.WaitForExit(3000))
            {
                _process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception)
        {
            // Nothing left to stop.
        }

        _process.Dispose();
    }
}
