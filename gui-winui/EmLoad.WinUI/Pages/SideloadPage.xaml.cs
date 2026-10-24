using EmLoad.WinUI.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace EmLoad.WinUI.Pages;

public sealed partial class SideloadPage : Page
{
    private AppState State => App.Current.State;

    private string? _ipaPath;
    private IpaSummary? _ipa;
    private bool _busy;

    public SideloadPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        State.DevicesChanged += OnDevicesChanged;
        KeepSignedCheck.IsChecked = State.Settings.KeepSigned;
        RefreshTargetCombo();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        State.DevicesChanged -= OnDevicesChanged;
    }

    // ------------------------------------------------------------------ //
    // Device target
    // ------------------------------------------------------------------ //
    private void OnDevicesChanged()
    {
        DispatcherQueue.TryEnqueue(RefreshTargetCombo);
    }

    private void RefreshTargetCombo()
    {
        var previous = (TargetCombo.SelectedItem as ComboBoxItem)?.Tag as string;
        TargetCombo.Items.Clear();

        foreach (var device in State.Devices)
        {
            var item = new ComboBoxItem
            {
                Content = $"{device.DisplayName} — {device.ShortUdid}",
                Tag = device.Udid,
            };
            TargetCombo.Items.Add(item);
            if (device.Udid == previous)
            {
                TargetCombo.SelectedItem = item;
            }
        }

        if (TargetCombo.SelectedItem is null && TargetCombo.Items.Count > 0)
        {
            TargetCombo.SelectedIndex = 0;
        }

        if (TargetCombo.Items.Count == 0)
        {
            TargetCombo.Items.Add(new ComboBoxItem
            {
                Content = "No device connected",
                IsEnabled = false,
            });
            TargetCombo.SelectedIndex = 0;
        }

        UpdateButtons();
    }

    private string? SelectedUdid => (TargetCombo.SelectedItem as ComboBoxItem)?.Tag as string;

    private void UpdateButtons()
    {
        var hasDevice = !string.IsNullOrEmpty(SelectedUdid);
        SideloadButton.IsEnabled = hasDevice && _ipa is not null && !_busy;
        ResetAppIdButton.IsEnabled = hasDevice && !_busy;
    }

    private async void RefreshDevices_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await State.RefreshDevicesAsync();
        }
        catch (EngineException exc)
        {
            MainWindow.Shell.SetStatus($"Could not list devices: {exc.Message}");
        }
    }

    // ------------------------------------------------------------------ //
    // Picking an IPA
    // ------------------------------------------------------------------ //
    private async void Browse_Click(object sender, RoutedEventArgs e)
    {
        var path = await Pickers.OpenIpaAsync(MainWindow.Shell);
        if (path is not null)
        {
            await LoadIpaAsync(path);
        }
    }

    private void DropZone_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "Sideload this app";
        }
    }

    private async void DropZone_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            return;
        }

        var items = await e.DataView.GetStorageItemsAsync();
        var file = items.OfType<StorageFile>()
            .FirstOrDefault(f => f.Name.EndsWith(".ipa", StringComparison.OrdinalIgnoreCase));
        if (file is null)
        {
            await Ui.ShowMessageAsync(XamlRoot, "Not an IPA", "Drop an .ipa file to sideload it.");
            return;
        }

        await LoadIpaAsync(file.Path);
    }

    private async Task LoadIpaAsync(string path)
    {
        if (State.Engine is null)
        {
            return;
        }

        _ipaPath = path;
        AppendLog($"Reading {Path.GetFileName(path)}…");
        SideloadBusy.IsActive = true;
        try
        {
            var result = await State.Engine.CallAsync(
                "ipa.inspect",
                new Dictionary<string, object?> { ["path"] = path });
            _ipa = Models.Ipa(result, path);

            DropZoneText.Text = $"IPA: {_ipa.AppBundle ?? Path.GetFileName(path)}";
            DropZone.BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
                "SystemFillColorSuccessBrush"];

            var lines = new List<string>
            {
                _ipa.DisplayName ?? _ipa.BundleId ?? "Unknown app",
                $"bundle: {_ipa.BundleId}",
                $"version: {_ipa.Version} ({_ipa.Build})    min iOS: {_ipa.MinimumOs ?? "-"}",
            };
            if (_ipa.Encrypted)
            {
                lines.Add("WARNING: App Store-encrypted (FairPlay) — cannot be sideloaded.");
            }
            if (_ipa.Extensions.Count > 0)
            {
                lines.Add($"extensions: {string.Join(", ", _ipa.Extensions)} (will be removed)");
            }
            AppInfoText.Text = string.Join(Environment.NewLine, lines);

            DisplayNameBox.Text = _ipa.DisplayName ?? "";
            BundleIdBox.Text = "";
            VersionBox.Text = _ipa.Version ?? "";
            AppIcon.Source = await ImageLoader.FromDataUriAsync(_ipa.Icon);
        }
        catch (EngineException exc)
        {
            _ipa = null;
            AppInfoText.Text = "Not a readable IPA.";
            DropZoneText.Text = "Drag & drop an .ipa here, or browse";
            AppendLog($"Could not read the IPA: {exc.Message}");
            await Ui.ShowErrorAsync(XamlRoot, "Could not read the IPA", exc.Message);
        }
        finally
        {
            SideloadBusy.IsActive = false;
            UpdateButtons();
        }
    }

    // ------------------------------------------------------------------ //
    // Sideload
    // ------------------------------------------------------------------ //
    private async void Sideload_Click(object sender, RoutedEventArgs e)
    {
        if (State.Engine is null || _ipaPath is null || _ipa is null)
        {
            return;
        }
        var udid = SelectedUdid;
        if (string.IsNullOrEmpty(udid))
        {
            await Ui.ShowMessageAsync(XamlRoot, "EmLoad", "Connect a device first.");
            return;
        }

        _busy = true;
        UpdateButtons();
        SideloadBusy.IsActive = true;
        Progress.Value = 0;
        PhaseText.Text = "Starting…";
        MainWindow.Shell.SetBusy(true, $"Sideloading {_ipa.DisplayName ?? "app"}…");
        AppendLog("Starting sideload…");

        try
        {
            var result = await State.Engine.CallAsync(
                "sideload.run",
                new Dictionary<string, object?>
                {
                    ["ipa"] = _ipaPath,
                    ["udid"] = udid,
                    ["bundleId"] = BundleIdBox.Text.Trim(),
                    ["displayName"] = DisplayNameBox.Text.Trim(),
                    ["version"] = VersionBox.Text.Trim(),
                    ["removeExtensions"] = StripExtensionsCheck.IsChecked == true,
                    ["removeUisd"] = StripUisdCheck.IsChecked == true,
                    ["enableFileSharing"] = FileSharingCheck.IsChecked == true,
                    ["keepSigned"] = KeepSignedCheck.IsChecked == true,
                    ["signedDir"] = State.Settings.SignedDir,
                },
                onProgress: progress => DispatcherQueue.TryEnqueue(() =>
                {
                    if (progress.Percent is { } percent)
                    {
                        Progress.Value = Math.Clamp(percent, 0, 100);
                    }
                    if (!string.IsNullOrWhiteSpace(progress.Step))
                    {
                        PhaseText.Text = $"[{progress.Phase}] {progress.Step}";
                        AppendLog($"[{progress.Phase}] {progress.Step}");
                    }
                }));

            var status = Models.GetString(result, "status") ?? "done";
            var name = Models.GetString(result, "name") ?? "The app";
            if (status != "installed")
            {
                var detail = Models.GetString(result, "error") ?? status;
                throw new EngineException(detail, "NotInstalled");
            }

            Progress.Value = 100;
            AppendLog($"Installed {name} on {udid}.");
            var regenerations = Models.GetInt(result, "profile_regenerations") ?? 0;
            if (regenerations > 0)
            {
                AppendLog($"Device verification failed {regenerations} time(s); re-issued a fresh profile.");
            }
            var expires = Models.GetString(result, "expires_at");
            if (DateTimeOffset.TryParse(expires, out var when))
            {
                AppendLog($"Profile expires {when.LocalDateTime:yyyy-MM-dd HH:mm} — refresh before then.");
            }
            MainWindow.Shell.SetStatus("Installed");
        }
        catch (EngineException exc)
        {
            AppendLog($"Sideload failed: {exc.Message}");
            MainWindow.Shell.SetStatus("Sideload failed");
            await Ui.ShowErrorAsync(
                XamlRoot,
                "Sideload failed",
                $"{_ipa.DisplayName ?? "The app"} did not install.\n\n{exc.Message}");
        }
        catch (Exception exc)
        {
            AppendLog($"Sideload failed: {exc}");
            MainWindow.Shell.SetStatus("Sideload failed");
        }
        finally
        {
            _busy = false;
            SideloadBusy.IsActive = false;
            UpdateButtons();
            MainWindow.Shell.SetBusy(false);
        }
    }

    private async void ResetAppId_Click(object sender, RoutedEventArgs e)
    {
        if (State.Engine is null)
        {
            return;
        }
        var udid = SelectedUdid;
        if (string.IsNullOrEmpty(udid))
        {
            await Ui.ShowMessageAsync(XamlRoot, "EmLoad", "Connect a device first.");
            return;
        }

        var confirmed = await Ui.ConfirmAsync(
            XamlRoot,
            "Reset App ID and profiles?",
            "This deletes EmLoad's cached Apple App ID, removes its provisioning "
            + "profiles from the device, and clears the local profile. The signing "
            + "certificate is kept.",
            primary: "Reset",
            secondary: "Cancel");
        if (!confirmed)
        {
            return;
        }

        ResetAppIdButton.IsEnabled = false;
        try
        {
            var result = await State.Engine.CallAsync(
                "provision.reset",
                new Dictionary<string, object?> { ["udid"] = udid });
            var appId = Models.GetString(result, "app_id");
            AppendLog($"Reset App ID {appId} and removed cached profile.");

            if (result.TryGetProperty("profiles", out var profiles) &&
                profiles.TryGetProperty("failed", out var failed) &&
                failed.ValueKind == System.Text.Json.JsonValueKind.Array &&
                failed.GetArrayLength() > 0)
            {
                var messages = failed.EnumerateArray()
                    .Where(f => f.ValueKind == System.Text.Json.JsonValueKind.String)
                    .Select(f => f.GetString());
                AppendLog("Some device profiles could not be removed: " + string.Join("; ", messages));
            }
            MainWindow.Shell.SetStatus("App ID and provisioning profiles reset");
        }
        catch (EngineException exc)
        {
            AppendLog($"App ID reset failed: {exc.Message}");
            await Ui.ShowErrorAsync(XamlRoot, "Reset failed", exc.Message);
        }
        finally
        {
            ResetAppIdButton.IsEnabled = true;
        }
    }

    private void AppendLog(string message)
    {
        LogView.Text = string.IsNullOrEmpty(LogView.Text)
            ? message
            : LogView.Text + Environment.NewLine + message;
        LogView.SelectionStart = LogView.Text.Length;
    }
}
