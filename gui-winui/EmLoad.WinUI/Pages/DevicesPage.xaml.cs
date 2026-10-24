using EmLoad.WinUI.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace EmLoad.WinUI.Pages;

public sealed partial class DevicesPage : Page
{
    private bool _loaded;

    public DevicesPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private AppState State => App.Current.State;

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        State.DevicesChanged += OnDevicesChanged;
        OnDevicesChanged();

        if (State.IsReady && !_loaded)
        {
            _loaded = true;
            await RefreshAsync();
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        State.DevicesChanged -= OnDevicesChanged;
    }

    public void OnDevicesChanged()
    {
        DeviceList.ItemsSource = State.Devices;
        var any = State.Devices.Count > 0;
        DeviceList.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        NoDevicesText.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
        DeviceCountText.Text = any
            ? $"{State.Devices.Count} device(s)"
            : "Waiting for a device";
    }

    private async Task RefreshAsync()
    {
        DevicesBusy.IsActive = true;
        try
        {
            await State.RefreshDevicesAsync();
            MainWindow.Shell.SetStatus(State.Devices.Count == 0
                ? "No device connected"
                : $"{State.Devices.Count} device(s) connected");
        }
        catch (EngineException exc)
        {
            MainWindow.Shell.SetStatus($"Could not list devices: {exc.Message}");
        }
        finally
        {
            DevicesBusy.IsActive = false;
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        await RefreshAsync();
    }
}
