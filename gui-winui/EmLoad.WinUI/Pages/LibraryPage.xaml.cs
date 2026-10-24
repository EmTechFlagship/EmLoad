using System.Text.Json;
using EmLoad.WinUI.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace EmLoad.WinUI.Pages;

public sealed partial class LibraryPage : Page
{
    private static readonly Dictionary<string, Microsoft.UI.Xaml.Media.Imaging.BitmapImage> IconCache = new();

    private AppState State => App.Current.State;
    private bool _refreshing;

    public LibraryPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        await ReloadAsync();
    }

    private async Task ReloadAsync()
    {
        if (State.Engine is null)
        {
            return;
        }

        try
        {
            var result = await State.Engine.CallAsync("library.list");
            var records = new List<LibraryApp>();
            if (result.ValueKind == JsonValueKind.Array)
            {
                records.AddRange(result.EnumerateArray().Select(Models.Library));
            }

            AppsList.ItemsSource = records;
            var any = records.Count > 0;
            HeaderGrid.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
            EmptyText.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
            AppsList.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
            CountText.Text = any ? $"{records.Count} tracked app(s)" : "";
            RefreshAllButton.IsEnabled = any && !_refreshing;
        }
        catch (EngineException exc)
        {
            MainWindow.Shell.SetStatus($"Could not read the library: {exc.Message}");
        }
    }

    private async void Reload_Click(object sender, RoutedEventArgs e)
    {
        await ReloadAsync();
    }

    private async void RefreshAll_Click(object sender, RoutedEventArgs e)
    {
        if (AppsList.ItemsSource is not IEnumerable<LibraryApp> apps)
        {
            return;
        }
        await RefreshAsync(apps.Select(a => a.BundleId).ToList());
    }

    private async void RefreshOne_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is string bundleId)
        {
            await RefreshAsync(new List<string> { bundleId });
        }
    }

    private async Task RefreshAsync(List<string> bundleIds)
    {
        if (State.Engine is null || bundleIds.Count == 0 || _refreshing)
        {
            return;
        }

        _refreshing = true;
        RefreshAllButton.IsEnabled = false;
        Busy.IsActive = true;
        StatusLine.Text = $"Refreshing {bundleIds.Count} app(s)…";
        MainWindow.Shell.SetBusy(true, StatusLine.Text);

        try
        {
            var result = await State.Engine.CallAsync(
                "library.refresh",
                new Dictionary<string, object?>
                {
                    ["bundleIds"] = bundleIds,
                    ["keepSigned"] = State.Settings.KeepSigned,
                    ["signedDir"] = State.Settings.SignedDir,
                },
                onProgress: progress => DispatcherQueue.TryEnqueue(() =>
                {
                    if (!string.IsNullOrWhiteSpace(progress.Step))
                    {
                        StatusLine.Text = $"[{progress.Phase}] {progress.Step}";
                    }
                }));

            var failed = Models.GetInt(result, "failed") ?? 0;
            var total = 0;
            var failures = new List<string>();
            if (result.TryGetProperty("results", out var rows) && rows.ValueKind == JsonValueKind.Array)
            {
                foreach (var row in rows.EnumerateArray())
                {
                    total++;
                    if (Models.GetString(row, "status") == "error")
                    {
                        failures.Add(
                            $"{Models.GetString(row, "bundle_id")}: {Models.GetString(row, "error")}");
                    }
                    else if (Models.GetString(row, "status") == "not_tracked")
                    {
                        failures.Add($"{Models.GetString(row, "bundle_id")}: not tracked");
                    }
                }
            }

            StatusLine.Text = failed == 0
                ? $"Refreshed {total - failed} app(s)."
                : $"Refreshed {total - failed} app(s); {failed} failed.";
            MainWindow.Shell.SetStatus(StatusLine.Text);

            if (failures.Count > 0)
            {
                await Ui.ShowErrorAsync(
                    XamlRoot,
                    "Some apps could not be refreshed",
                    string.Join(Environment.NewLine, failures));
            }
        }
        catch (EngineException exc)
        {
            StatusLine.Text = $"Refresh failed: {exc.Message}";
            await Ui.ShowErrorAsync(XamlRoot, "Refresh failed", exc.Message);
        }
        finally
        {
            _refreshing = false;
            Busy.IsActive = false;
            RefreshAllButton.IsEnabled = true;
            MainWindow.Shell.SetBusy(false);
            await ReloadAsync();
        }
    }

    private async void Uninstall_Click(object sender, RoutedEventArgs e)
    {
        if (State.Engine is null || (sender as FrameworkElement)?.Tag is not string bundleId)
        {
            return;
        }

        var confirmed = await Ui.ConfirmAsync(
            XamlRoot,
            "Uninstall app?",
            $"Uninstall {bundleId} from the device? The app is removed; the sideload record is kept.",
            primary: "Uninstall");
        if (!confirmed)
        {
            return;
        }

        try
        {
            await State.Engine.CallAsync(
                "apps.uninstall",
                new Dictionary<string, object?> { ["bundleId"] = bundleId });
            StatusLine.Text = $"Uninstalled {bundleId}.";
            MainWindow.Shell.SetStatus(StatusLine.Text);
        }
        catch (EngineException exc)
        {
            StatusLine.Text = $"Uninstall failed: {exc.Message}";
            await Ui.ShowErrorAsync(XamlRoot, "Uninstall failed", exc.Message);
        }
    }

    private async void Forget_Click(object sender, RoutedEventArgs e)
    {
        if (State.Engine is null || (sender as FrameworkElement)?.Tag is not string bundleId)
        {
            return;
        }

        var confirmed = await Ui.ConfirmAsync(
            XamlRoot,
            "Stop tracking this app?",
            $"Remove the sideload record for {bundleId}? This does not uninstall it or "
            + "delete its signing certificate.",
            primary: "Forget");
        if (!confirmed)
        {
            return;
        }

        try
        {
            await State.Engine.CallAsync(
                "library.forget",
                new Dictionary<string, object?> { ["bundleId"] = bundleId });
            StatusLine.Text = $"Forgetting {bundleId}.";
            await ReloadAsync();
        }
        catch (EngineException exc)
        {
            StatusLine.Text = $"Could not forget {bundleId}: {exc.Message}";
        }
    }

    private async void RowIcon_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is not Image image || image.Tag is not string dataUri)
        {
            return;
        }
        if (IconCache.TryGetValue(dataUri, out var cached))
        {
            image.Source = cached;
            return;
        }

        var bitmap = await ImageLoader.FromDataUriAsync(dataUri);
        if (bitmap is not null)
        {
            IconCache[dataUri] = bitmap;
            image.Source = bitmap;
        }
    }
}
