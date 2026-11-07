using System.Text.Json;
using EmLoad.WinUI.Pages;
using EmLoad.WinUI.Services;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using WinRT.Interop;

namespace EmLoad.WinUI;

public sealed partial class MainWindow : Window
{
    private bool _started;
    private bool _didAutoCheckForUpdate;
    private bool _updateDialogOpen;
    private string? _currentNavigationTag;

    public static MainWindow Shell => (MainWindow)App.Current.MainAppWindow!;

    public MainWindow()
    {
        InitializeComponent();

        try
        {
            SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        }
        catch (Exception)
        {
            // Mica needs Windows 11 + a supported GPU; the default brush is fine.
        }

        var appWindow = GetAppWindow();
        if (appWindow is not null)
        {
            appWindow.Title = "EmLoad";
            appWindow.Resize(new SizeInt32(1120, 780));

            var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "EmLoad.ico");
            if (File.Exists(icon))
            {
                appWindow.SetIcon(icon);
            }
        }

        // Draw the app name in our own title bar so the Mica backdrop reaches
        // the top edge instead of a light system bar over a dark window.
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarRow);

        App.Current.State.StatusMessage += OnStatusMessage;

        ApplyMembershipNavigation(selectCurrentPlan: false);
        Nav.SelectedItem = PatreonMembershipState.Tier switch
        {
            "Plus" => PlusBenefitsNav,
            "Pro" => ProBenefitsNav,
            _ => DevicesNav,
        };
        if (Content is FrameworkElement root)
        {
            root.Loaded += MainWindow_Loaded;
            root.Loaded += (_, _) => UpdatePaneFooter(Nav.DisplayMode);
        }
    }

    private AppWindow? GetAppWindow()
    {
        var handle = WindowNative.GetWindowHandle(this);
        var id = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(handle);
        return AppWindow.GetFromWindowId(id);
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        if (_started)
        {
            return;
        }
        _started = true;
        await StartEngineAsync();
    }

    private async Task StartEngineAsync()
    {
        ShowStartup("Starting the EmLoad engine…", null, busy: true);
        try
        {
            await App.Current.State.InitializeAsync();
            HideStartup();
            EngineBadge.Text = $"emload {App.Current.State.EngineVersion} · Python engine";
            SetBusy(false);
            await CheckForAppUpdateAsync(interactive: false);
            // Seed the first page with the freshly loaded device list.
            if (ContentFrame.Content is DevicesPage devices)
            {
                devices.OnDevicesChanged();
            }
        }
        catch (EngineException exc)
        {
            ShowStartup("The EmLoad engine could not start", exc.Message, busy: false, retry: true);
            EngineBadge.Text = "engine offline";
        }
        catch (Exception exc)
        {
            ShowStartup("Unexpected startup failure", exc.ToString(), busy: false, retry: true);
            EngineBadge.Text = "engine offline";
        }
    }

    private async void RetryButton_Click(object sender, RoutedEventArgs e)
    {
        App.Current.State.Shutdown();
        await StartEngineAsync();
    }

    /// <summary>
    /// Looks for a GitHub release newer than this build, including pre-releases
    /// from RC 1 on. The automatic check runs once per launch.
    /// </summary>
    public async Task CheckForAppUpdateAsync(bool interactive)
    {
        if (_updateDialogOpen)
        {
            return;
        }
        if (!interactive)
        {
            if (_didAutoCheckForUpdate)
            {
                return;
            }
            _didAutoCheckForUpdate = true;
            if (Environment.GetEnvironmentVariable("EMLOAD_SKIP_UPDATES") == "1")
            {
                return;
            }
        }

        var engine = App.Current.State.Engine;
        if (engine is null || Content.XamlRoot is null)
        {
            if (interactive)
            {
                SetStatus("The engine is not running, so EmLoad cannot check for updates.");
            }
            return;
        }

        JsonElement result;
        try
        {
            result = await engine.CallAsync("app.update.check");
        }
        catch (Exception exc)
        {
            App.Current.State.AppendLog($"Update check failed: {exc.Message}");
            if (interactive)
            {
                await Ui.ShowMessageAsync(Content.XamlRoot, "EmLoad", exc.Message);
            }
            return;
        }

        if (!result.TryGetProperty("update", out var update)
            || update.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            if (interactive)
            {
                await Ui.ShowMessageAsync(
                    Content.XamlRoot,
                    "EmLoad",
                    $"EmLoad {JsonString(result, "current")} is up to date.");
            }
            return;
        }

        var current = JsonString(result, "current");
        var version = JsonString(update, "version");
        var title = JsonString(update, "title");
        var notes = JsonString(update, "notes");
        var html = JsonString(update, "html_url");
        var prerelease = update.TryGetProperty("prerelease", out var preFlag)
            && preFlag.ValueKind == JsonValueKind.True;
        var canApply = update.TryGetProperty("can_apply", out var applyFlag)
            && applyFlag.ValueKind == JsonValueKind.True;
        if (!interactive && !canApply)
        {
            return;
        }
        var kind = prerelease ? "pre-release" : "release";
        var message = $"You have {current}. {version} is a newer GitHub {kind}.";
        message += canApply
            ? "\n\nDownload and restart closes EmLoad, installs the update, and opens it again."
            : "\n\nThis copy cannot replace itself. The release page has the download.";
        if (!string.IsNullOrWhiteSpace(notes))
        {
            message += "\n\n" + notes;
        }

        App.Current.State.AppendLog($"Update available: {(string.IsNullOrWhiteSpace(title) ? version : title)}");

        var dialog = new ContentDialog
        {
            Title = string.IsNullOrWhiteSpace(title) ? "Update available" : title,
            Content = new TextBlock
            {
                Text = message,
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 440,
            },
            CloseButtonText = "Later",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot,
        };
        if (canApply)
        {
            dialog.PrimaryButtonText = "Download and restart";
            dialog.SecondaryButtonText = "View release";
            dialog.SecondaryButtonClick += (_, _) => OpenRelease(html);
        }
        else
        {
            dialog.PrimaryButtonText = "View release";
        }

        string? updateError = null;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            if (!canApply)
            {
                OpenRelease(html);
                return;
            }

            var deferral = args.GetDeferral();
            args.Cancel = true;
            dialog.IsPrimaryButtonEnabled = false;
            dialog.IsSecondaryButtonEnabled = false;
            try
            {
                SetBusy(true, "Downloading update…");
                var applied = await engine.CallAsync(
                    "app.update.apply",
                    new Dictionary<string, object?> { ["host_pid"] = Environment.ProcessId },
                    progress => SetStatus(progress.Step ?? "Downloading update…"));
                if (JsonString(applied, "status") == "relaunching")
                {
                    App.Current.State.AppendLog($"Installing {JsonString(applied, "version")} and reopening.");
                    Close();
                    return;
                }
                OpenRelease(JsonString(applied, "html_url"));
                args.Cancel = false;
            }
            catch (Exception exc)
            {
                updateError = exc.Message;
                App.Current.State.AppendLog($"Update failed: {exc.Message}");
                SetStatus("Update failed");
                args.Cancel = false;
            }
            finally
            {
                SetBusy(false);
                deferral.Complete();
            }
        };

        _updateDialogOpen = true;
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            _updateDialogOpen = false;
        }
        if (updateError is not null && Content.XamlRoot is not null)
        {
            await Ui.ShowMessageAsync(Content.XamlRoot, "Update failed", updateError);
        }
    }

    private static void OpenRelease(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            _ = Windows.System.Launcher.LaunchUriAsync(uri);
        }
    }

    private static string JsonString(JsonElement element, string name)
    {
        return element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : "";
    }

    // ------------------------------------------------------------------ //
    // Navigation
    // ------------------------------------------------------------------ //
    private void Nav_DisplayModeChanged(NavigationView sender, NavigationViewDisplayModeChangedEventArgs args)
    {
        UpdatePaneFooter(args.DisplayMode);
    }

    /// <summary>
    /// Hides the engine badge unless the pane shows labels. The collapsed pane is
    /// only 48 px wide, which clips the badge down to "emlo…".
    /// </summary>
    private void UpdatePaneFooter(NavigationViewDisplayMode mode)
    {
        EngineBadge.Visibility = mode == NavigationViewDisplayMode.Expanded
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item)
        {
            return;
        }

        var tag = item.Tag as string ?? "";
        Type? pageType = tag switch
        {
            "subscription" => typeof(SubscriptionPage),
            "plusBenefits" or "proBenefits" => typeof(MembershipBenefitsPage),
            "devices" => typeof(DevicesPage),
            "sideload" => typeof(SideloadPage),
            "library" => typeof(LibraryPage),
            "account" => typeof(AccountPage),
            "settings" => typeof(SettingsPage),
            "diagnostics" => typeof(DiagnosticsPage),
            _ => null,
        };

        if (pageType is not null && (ContentFrame.CurrentSourcePageType != pageType || tag != _currentNavigationTag))
        {
            ContentFrame.Navigate(pageType);
            _currentNavigationTag = tag;
        }
    }

    public void RefreshMembershipNavigation()
    {
        ApplyMembershipNavigation(selectCurrentPlan: true);
    }

    private void ApplyMembershipNavigation(bool selectCurrentPlan)
    {
        var tier = PatreonMembershipState.Tier;
        SubscriptionNav.Visibility = Visibility.Collapsed;
        PlusBenefitsNav.Visibility = tier == "Plus" ? Visibility.Visible : Visibility.Collapsed;
        ProBenefitsNav.Visibility = tier == "Pro" ? Visibility.Visible : Visibility.Collapsed;

        if (!selectCurrentPlan)
        {
            return;
        }

        var selectedItem = tier switch
        {
            "Plus" => PlusBenefitsNav,
            "Pro" => ProBenefitsNav,
            _ => DevicesNav,
        };
        if (!ReferenceEquals(Nav.SelectedItem, selectedItem))
        {
            Nav.SelectedItem = selectedItem;
        }
    }

    // ------------------------------------------------------------------ //
    // Status bar / shell services used by pages
    // ------------------------------------------------------------------ //
    private void OnStatusMessage(string message)
    {
        DispatcherQueue.TryEnqueue(() => StatusText.Text = message);
    }

    public void SetStatus(string message)
    {
        DispatcherQueue.TryEnqueue(() => StatusText.Text = message);
    }

    public void SetBusy(bool busy, string? message = null)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            BusyRing.IsActive = busy;
            if (message is not null)
            {
                StatusText.Text = message;
            }
        });
    }

    public void RefreshEngineBadge()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            EngineBadge.Text = $"emload {App.Current.State.EngineVersion} · Python engine";
        });
    }

    private async void LogButton_Click(object sender, RoutedEventArgs e)
    {
        var box = new TextBox
        {
            Text = App.Current.State.LogText,
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            Height = 420,
            MinWidth = 720,
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);

        var dialog = new ContentDialog
        {
            Title = "Operation log",
            Content = box,
            CloseButtonText = "Close",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
    }

    // ------------------------------------------------------------------ //
    // Startup overlay
    // ------------------------------------------------------------------ //
    private void ShowStartup(string title, string? detail, bool busy, bool retry = false)
    {
        StartupOverlay.Visibility = Visibility.Visible;
        StartupRing.IsActive = busy;
        StartupRing.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        StartupTitle.Text = title;
        StartupDetail.Text = detail ?? "Python is loading the device and signing stack. This takes a few seconds.";
        RetryButton.Visibility = retry ? Visibility.Visible : Visibility.Collapsed;
    }

    private void HideStartup()
    {
        StartupOverlay.Visibility = Visibility.Collapsed;
    }
}
