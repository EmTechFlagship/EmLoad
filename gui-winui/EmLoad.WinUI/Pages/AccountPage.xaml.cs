using System.Text.Json;
using EmLoad.WinUI.Dialogs;
using EmLoad.WinUI.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace EmLoad.WinUI.Pages;

public sealed partial class AccountPage : Page
{
    private AppState State => App.Current.State;

    public AccountPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        if (State.Engine is null)
        {
            return;
        }

        Busy.IsActive = true;
        try
        {
            var status = Models.Account(await State.Engine.CallAsync("account.status"));

            if (!status.Authenticated && status.AccountCount > 0)
            {
                // A saved session exists but none is active: resume it, like the
                // PySide6 window does on open.
                AccountTitle.Text = "Resuming saved session…";
                try
                {
                    await State.Engine.CallAsync("account.resume");
                    status = Models.Account(await State.Engine.CallAsync("account.status"));
                }
                catch (EngineException)
                {
                    // Fall through to the signed-out state.
                }
            }

            Apply(status);
        }
        catch (EngineException exc)
        {
            AccountTitle.Text = "Account status unavailable";
            AccountDetail.Text = exc.Message;
        }
        finally
        {
            Busy.IsActive = false;
        }
    }

    private async void Apply(AccountStatus status)
    {
        if (!status.Authenticated)
        {
            AccountTitle.Text = "Not signed in";
            AccountDetail.Text = "Sign in to provision apps, install profiles and sideload.";
            SignInButton.IsEnabled = true;
            SignOutButton.IsEnabled = false;
            TeamsText.Text = "Sign in to list your Apple developer teams.";
            return;
        }

        AccountTitle.Text = status.Email ?? "Signed in";
        AccountDetail.Text =
            $"team: {status.TeamId ?? "not provisioned yet"}\n"
            + $"developer token: {(status.HasAuthToken ? "yes" : "no")}";
        SignInButton.IsEnabled = true;
        SignOutButton.IsEnabled = true;

        if (State.Engine is null)
        {
            return;
        }

        try
        {
            var teams = await State.Engine.CallAsync("account.teams");
            TeamsText.Text = RenderTeams(teams);
        }
        catch (EngineException exc)
        {
            TeamsText.Text = $"Could not list teams: {exc.Message}";
        }
    }

    private static string RenderTeams(JsonElement teams)
    {
        if (teams.ValueKind != JsonValueKind.Array || teams.GetArrayLength() == 0)
        {
            return "No teams returned by Apple.";
        }

        var lines = new List<string>();
        foreach (var team in teams.EnumerateArray())
        {
            var name = Models.GetString(team, "name")
                ?? Models.GetString(team, "teamName")
                ?? "Team";
            var id = Models.GetString(team, "team_id")
                ?? Models.GetString(team, "teamId")
                ?? "";
            var type = Models.GetString(team, "type")
                ?? Models.GetString(team, "team_type")
                ?? "";
            lines.Add($"{name} — {id}{(type.Length > 0 ? $" ({type})" : "")}");
        }
        return string.Join(Environment.NewLine, lines);
    }

    private async void SignIn_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new LoginDialog { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
        await RefreshAsync();
    }

    private async void SignOut_Click(object sender, RoutedEventArgs e)
    {
        if (State.Engine is null)
        {
            return;
        }

        var confirmed = await Ui.ConfirmAsync(
            XamlRoot,
            "Sign out of EmLoad?",
            "This clears the saved Apple session. Apps already installed stay on the device.",
            primary: "Sign out");
        if (!confirmed)
        {
            return;
        }

        Busy.IsActive = true;
        try
        {
            await State.Engine.CallAsync("account.logout");
            State.AppendLog("Signed out.");
            MainWindow.Shell.SetStatus("Signed out");
        }
        catch (EngineException exc)
        {
            await Ui.ShowErrorAsync(XamlRoot, "Sign out failed", exc.Message);
        }
        finally
        {
            Busy.IsActive = false;
        }
        await RefreshAsync();
    }
}
