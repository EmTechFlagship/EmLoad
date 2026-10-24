using System.Text;
using System.Text.Json;
using EmLoad.WinUI.Services;
using Microsoft.UI.Xaml;

namespace EmLoad.WinUI;

public partial class App : Application
{
    private Window? _window;

    public static new App Current => (App)Application.Current;

    /// <summary>Shared engine connection and UI state (see <see cref="AppState"/>).</summary>
    public AppState State { get; } = new();

    public Window? MainAppWindow => _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) =>
        {
            // A XAML-thread crash must not close the window silently; log it and
            // keep going, matching the PySide6 excepthook behaviour.
            args.Handled = true;
            State.ReportError($"{args.Message}\n\n{args.Exception?.StackTrace}");
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activated += (_, _) => { };
        _window.Closed += (_, _) => State.Shutdown();
        _window.Activate();
    }
}

/// <summary>
/// Process-wide state: the engine client, the latest device inventory and the
/// persisted settings snapshot. Pages read from here instead of owning engines.
/// </summary>
public sealed class AppState
{
    private readonly StringBuilder _log = new();
    private readonly object _logLock = new();

    // Engine messages arrive on the reader thread, but everything below them
    // (device lists, log views) touches XAML. Events are therefore re-raised
    // on the UI thread: touching a control from the reader thread throws a
    // COMException that used to kill the reader loop.
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui =
        Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();

    private void OnUiThread(Action action)
    {
        if (_ui is null || _ui.HasThreadAccess)
        {
            action();
        }
        else
        {
            _ui.TryEnqueue(() => action());
        }
    }

    public EngineClient? Engine { get; private set; }

    public List<DeviceInfo> Devices { get; private set; } = new();

    public SettingsSnapshot Settings { get; private set; } = new();

    public string EngineVersion { get; private set; } = "?";

    public bool IsReady { get; private set; }

    /// <summary>Device inventory changed (initial load, refresh, or usbmux event).</summary>
    public event Action? DevicesChanged;

    /// <summary>Any engine event, including progress and log lines.</summary>
    public event Action<EngineEvent>? EngineEvent;

    /// <summary>A one-line message for the status bar.</summary>
    public event Action<string>? StatusMessage;

    /// <summary>The app log (sideload steps, engine stderr, errors).</summary>
    public event Action<string>? LogAppended;

    public string LogText
    {
        get
        {
            lock (_logLock)
            {
                return _log.ToString();
            }
        }
    }

    public async Task InitializeAsync()
    {
        Engine = await EngineClient.StartAsync();
        EngineVersion = Engine.Version;
        Engine.EventReceived += OnEngineEvent;
        Engine.EngineStderr += line =>
        {
            AppendLog($"engine: {line}");
        };
        Engine.Exited += message =>
        {
            AppendLog(message);
            StatusMessage?.Invoke(message);
        };

        Settings = await Engine.CallAsync<SettingsSnapshot>("settings.get") ?? new SettingsSnapshot();
        await RefreshDevicesAsync();
        await Engine.CallAsync("watch.start");

        var account = await Engine.CallAsync("account.status");
        if (Models.Account(account).Authenticated)
        {
            StatusMessage?.Invoke("Signed in to Apple ID");
        }

        IsReady = true;
        StatusMessage?.Invoke($"Engine ready (emload {EngineVersion})");
    }

    public async Task RefreshDevicesAsync()
    {
        if (Engine is null)
        {
            return;
        }
        var result = await Engine.CallAsync("devices.list");
        var rows = new List<DeviceInfo>();
        if (result.ValueKind == System.Text.Json.JsonValueKind.Array)
        {
            rows.AddRange(result.EnumerateArray().Select(Models.Device));
        }
        Devices = rows;
        OnUiThread(() => DevicesChanged?.Invoke());
    }

    public async Task ReloadSettingsAsync()
    {
        if (Engine is null)
        {
            return;
        }
        Settings = await Engine.CallAsync<SettingsSnapshot>("settings.get") ?? Settings;
    }

    public async Task SaveSettingsAsync(Dictionary<string, object?> patch)
    {
        if (Engine is null)
        {
            return;
        }
        var result = await Engine.CallAsync("settings.set", patch);
        Settings = result.Deserialize<SettingsSnapshot>() ?? Settings;
    }

    private void OnEngineEvent(EngineEvent evt) => OnUiThread(() => ApplyEngineEvent(evt));

    private void ApplyEngineEvent(EngineEvent evt)
    {
        switch (evt.Name)
        {
            case "devices":
                var rows = new List<DeviceInfo>();
                if (evt.Payload.TryGetProperty("data", out var data) &&
                    data.ValueKind == System.Text.Json.JsonValueKind.Array)
                {
                    rows.AddRange(data.EnumerateArray().Select(Models.Device));
                }
                Devices = rows;
                DevicesChanged?.Invoke();
                StatusMessage?.Invoke(rows.Count == 0
                    ? "No device connected"
                    : $"{rows.Count} device(s) connected");
                break;

            case "provision.result":
                var status = Models.GetString(evt.Payload, "status");
                if (status == "reprovisioned")
                {
                    var udid = Models.GetString(evt.Payload, "udid");
                    AppendLog($"Provisioned {udid} with a fresh certificate + profile");
                    StatusMessage?.Invoke("Provisioned a new device");
                }
                break;

            case "watch.error":
                AppendLog($"Device watch: {Models.GetString(evt.Payload, "message")}");
                StatusMessage?.Invoke("Device watch stopped (device list still refreshes)");
                break;

            case "log":
                var message = Models.GetString(evt.Payload, "message");
                if (!string.IsNullOrWhiteSpace(message))
                {
                    AppendLog(message!);
                }
                break;
        }

        EngineEvent?.Invoke(evt);
    }

    public void AppendLog(string message)
    {
        lock (_logLock)
        {
            _log.AppendLine($"{DateTime.Now:HH:mm:ss}  {message}");
            if (_log.Length > 200_000)
            {
                _log.Remove(0, _log.Length - 150_000);
            }
        }
        OnUiThread(() => LogAppended?.Invoke(message));
    }

    public void ReportError(string message)
    {
        AppendLog($"error: {message}");
        StatusMessage?.Invoke("Something went wrong - see the log");
    }

    public void Shutdown()
    {
        Engine?.Dispose();
        Engine = null;
    }
}

/// <summary>The connection/signing preferences stored in config.json.</summary>
public sealed class SettingsSnapshot
{
    [System.Text.Json.Serialization.JsonPropertyName("connection")]
    public string Connection { get; set; } = "auto";

    [System.Text.Json.Serialization.JsonPropertyName("signed_dir")]
    public string SignedDir { get; set; } = "";

    [System.Text.Json.Serialization.JsonPropertyName("keep_signed")]
    public bool KeepSigned { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("data_dir")]
    public string DataDir { get; set; } = "";

    [System.Text.Json.Serialization.JsonPropertyName("config_file")]
    public string ConfigFile { get; set; } = "";
}
