using EmLoad.WinUI.Services;
using Microsoft.UI.Xaml.Controls;

namespace EmLoad.WinUI.Dialogs;

/// <summary>
/// Apple ID sign-in with the two-step 2FA flow. The password is handed to the
/// engine once; the engine keeps it in memory only until the code arrives.
/// </summary>
public sealed partial class LoginDialog : ContentDialog
{
    private bool _pending2fa;
    private bool _busy;
    private string _email = "";

    public LoginDialog()
    {
        InitializeComponent();
    }

    private AppState State => App.Current.State;

    private async void OnPrimaryButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Keep the dialog open: the engine call is async and we decide when to
        // close based on the result.
        args.Cancel = true;
        if (_busy || State.Engine is null)
        {
            return;
        }

        if (_pending2fa)
        {
            await SubmitCodeAsync();
        }
        else
        {
            await SubmitCredentialsAsync();
        }
    }

    private async Task SubmitCredentialsAsync()
    {
        var email = EmailBox.Text.Trim();
        var password = PasswordBox.Password;
        if (email.Length == 0 || password.Length == 0)
        {
            StatusText.Text = "Enter your Apple ID email and password.";
            return;
        }

        _email = email;
        SetBusy(true, "Signing in…");
        try
        {
            var result = await State.Engine!.CallAsync(
                "account.login",
                new Dictionary<string, object?> { ["email"] = email, ["password"] = password });

            var status = Models.GetString(result, "status");
            if (status == "2fa_required")
            {
                _pending2fa = true;
                var method = Models.GetString(result, "method") == "trusteddevice"
                    ? "trusted device"
                    : "SMS";
                CodeBox.Visibility = Microsoft.UI.Xaml.Visibility.Visible;
                CodeBox.Focus(Microsoft.UI.Xaml.FocusState.Programmatic);
                PrimaryButtonText = "Verify code";
                StatusText.Text = $"Apple sent a verification code to your {method}. Enter it below.";
                return;
            }

            if (status == "authenticated")
            {
                StatusText.Text = "Signed in.";
                State.AppendLog($"Signed in as {email}.");
                MainWindow.Shell.SetStatus($"Signed in as {email}");
                Hide();
                return;
            }

            StatusText.Text = $"Apple returned: {status ?? "no status"}";
        }
        catch (EngineException exc)
        {
            StatusText.Text = exc.Message;
            PasswordBox.Password = "";
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task SubmitCodeAsync()
    {
        var code = CodeBox.Text.Trim();
        if (code.Length == 0)
        {
            StatusText.Text = "Enter the verification code Apple sent you.";
            return;
        }

        SetBusy(true, "Verifying code…");
        try
        {
            var result = await State.Engine!.CallAsync(
                "account.login2fa",
                new Dictionary<string, object?> { ["email"] = _email, ["code"] = code });

            var status = Models.GetString(result, "status");
            if (status == "authenticated")
            {
                State.AppendLog($"Signed in as {_email}.");
                MainWindow.Shell.SetStatus($"Signed in as {_email}");
                Hide();
                return;
            }

            StatusText.Text = $"Apple returned: {status ?? "no status"}";
        }
        catch (EngineException exc)
        {
            StatusText.Text = exc.Message;
            CodeBox.Text = "";
        }
        finally
        {
            SetBusy(false);
        }
    }

    private void SetBusy(bool busy, string? message = null)
    {
        _busy = busy;
        IsPrimaryButtonEnabled = !busy;
        if (message is not null)
        {
            StatusText.Text = message;
        }
    }
}
