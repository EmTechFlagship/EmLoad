using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;

namespace EmLoad.WinUI.Pages;

public sealed partial class SubscriptionPage : Page
{
    private static readonly HttpClient Http = new();
    private CancellationTokenSource? _connectCancellation;

    public SubscriptionPage()
    {
        InitializeComponent();
    }

    private async void ConnectPatreon_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        var sessionId = Guid.NewGuid().ToString("D");
        var worker = "https://emload-patreon.ios11emiry.workers.dev";
        var startUrl = $"{worker}/auth/start?session_id={Uri.EscapeDataString(sessionId)}";

        try
        {
            Process.Start(new ProcessStartInfo(startUrl) { UseShellExecute = true });
        }
        catch (Exception exc)
        {
            MembershipStatus.Text = $"Could not open Patreon: {exc.Message}";
            return;
        }

        _connectCancellation?.Cancel();
        _connectCancellation = new CancellationTokenSource();
        var token = _connectCancellation.Token;
        ConnectPatreonButton.IsEnabled = false;
        MembershipStatus.Text = "Finish signing in to Patreon in your browser…";

        try
        {
            var statusUrl = $"{worker}/api/session?session_id={Uri.EscapeDataString(sessionId)}";
            for (var attempt = 0; attempt < 300; attempt++)
            {
                token.ThrowIfCancellationRequested();
                await Task.Delay(TimeSpan.FromSeconds(2), token);
                using var response = await Http.GetAsync(statusUrl, token);
                response.EnsureSuccessStatusCode();
                using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
                var root = document.RootElement;
                if (root.TryGetProperty("status", out var status) && status.GetString() == "complete")
                {
                    var tier = root.TryGetProperty("tier", out var tierValue) && tierValue.ValueKind == JsonValueKind.String
                        ? tierValue.GetString()
                        : null;
                    PatreonMembershipState.SetTier(tier);
                    MainWindow.Shell.RefreshMembershipNavigation();
                    MembershipStatus.Text = tier is null
                        ? "No active Em Basic or Em Pro membership was found for EmAppleFlagship."
                        : $"EmLoad {tier} is active through Patreon.";
                    return;
                }
            }
            MembershipStatus.Text = "Patreon sign-in timed out. Try connecting again.";
        }
        catch (OperationCanceledException)
        {
            MembershipStatus.Text = "Patreon connection cancelled.";
        }
        catch (Exception exc)
        {
            MembershipStatus.Text = $"Could not verify the Patreon membership: {exc.Message}";
        }
        finally
        {
            ConnectPatreonButton.IsEnabled = true;
        }
    }
}
