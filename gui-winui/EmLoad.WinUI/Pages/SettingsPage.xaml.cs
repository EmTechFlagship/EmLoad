using System.Diagnostics;
using EmLoad.WinUI.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace EmLoad.WinUI.Pages;

public sealed partial class SettingsPage : Page
{
    private AppState State => App.Current.State;
    private bool _loading;

    public SettingsPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await LoadAsync();
    }

    private async Task LoadAsync()
    {
        if (State.Engine is null)
        {
            return;
        }

        _loading = true;
        try
        {
            await State.ReloadSettingsAsync();
            Apply(State.Settings);
        }
        catch (EngineException exc)
        {
            MainWindow.Shell.SetStatus($"Could not load settings: {exc.Message}");
        }
        finally
        {
            _loading = false;
        }

        await RefreshZsignAsync();
    }

    private void Apply(SettingsSnapshot settings)
    {
        var index = settings.Connection switch
        {
            "usb" => 1,
            "wifi" => 2,
            _ => 0,
        };
        ConnectionCombo.SelectedIndex = index;
        SignedDirBox.Text = settings.SignedDir;
        KeepSignedCheck.IsChecked = settings.KeepSigned;
        DataDirText.Text = settings.DataDir;
    }

    private async Task SaveAsync(Dictionary<string, object?> patch)
    {
        if (State.Engine is null || _loading)
        {
            return;
        }
        try
        {
            await State.SaveSettingsAsync(patch);
            MainWindow.Shell.SetStatus("Settings saved");
        }
        catch (EngineException exc)
        {
            MainWindow.Shell.SetStatus($"Could not save settings: {exc.Message}");
        }
    }

    private async void Connection_Changed(object sender, SelectionChangedEventArgs e)
    {
        var value = (ConnectionCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "auto";
        await SaveAsync(new Dictionary<string, object?> { ["connection"] = value });
    }

    private async void BrowseSignedDir_Click(object sender, RoutedEventArgs e)
    {
        var folder = await Pickers.PickFolderAsync(MainWindow.Shell, SignedDirBox.Text);
        if (folder is null)
        {
            return;
        }
        SignedDirBox.Text = folder;
        await SaveAsync(new Dictionary<string, object?> { ["signed_dir"] = folder });
    }

    private async void KeepSigned_Click(object sender, RoutedEventArgs e)
    {
        await SaveAsync(new Dictionary<string, object?>
        {
            ["keep_signed"] = KeepSignedCheck.IsChecked == true,
        });
    }

    private async void RecheckZsign_Click(object sender, RoutedEventArgs e) => await RefreshZsignAsync();

    private async Task RefreshZsignAsync()
    {
        if (State.Engine is null)
        {
            return;
        }
        try
        {
            var status = Models.Signing(await State.Engine.CallAsync("signing.status"));
            if (status.Available)
            {
                ZsignText.Text = $"zsign: {status.Path}\n({status.Version ?? "unknown version"})";
                ZsignButton.IsEnabled = false;
                ZsignButton.Content = "zsign installed";
            }
            else
            {
                ZsignText.Text = $"zsign not found: {status.Error ?? "unknown error"}\n"
                    + "Download it here, set EM_ZSIGN, or place zsign.exe in vendor/.";
                ZsignButton.IsEnabled = true;
                ZsignButton.Content = "Download zsign";
            }
        }
        catch (EngineException exc)
        {
            ZsignText.Text = $"Could not check zsign: {exc.Message}";
        }
    }

    private async void DownloadZsign_Click(object sender, RoutedEventArgs e)
    {
        if (State.Engine is null)
        {
            return;
        }

        ZsignButton.IsEnabled = false;
        ZsignBusy.IsActive = true;
        ZsignText.Text = "Downloading zsign…";
        MainWindow.Shell.SetBusy(true, "Downloading zsign…");

        try
        {
            await State.Engine.CallAsync("signing.download");
            await RefreshZsignAsync();
            MainWindow.Shell.SetStatus("zsign installed");
        }
        catch (EngineException exc)
        {
            ZsignText.Text = $"Download failed: {exc.Message}";
            ZsignButton.IsEnabled = true;
            MainWindow.Shell.SetStatus("zsign download failed");
        }
        finally
        {
            ZsignBusy.IsActive = false;
            MainWindow.Shell.SetBusy(false);
        }
    }

    private void OpenDataDir_Click(object sender, RoutedEventArgs e)
    {
        var directory = State.Settings.DataDir;
        if (string.IsNullOrWhiteSpace(directory))
        {
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{directory}\"")
            {
                UseShellExecute = true,
            });
        }
        catch (Exception exc)
        {
            MainWindow.Shell.SetStatus($"Could not open the folder: {exc.Message}");
        }
    }
}
