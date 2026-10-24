using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace EmLoad.WinUI.Services;

/// <summary>Small dialog helpers shared by the pages.</summary>
public static class Ui
{
    private static bool _open;

    public static async Task ShowMessageAsync(
        XamlRoot root,
        string title,
        string message,
        string close = "OK")
    {
        if (_open)
        {
            return;
        }
        _open = true;
        try
        {
            var dialog = new ContentDialog
            {
                Title = title,
                Content = new TextBlock
                {
                    Text = message,
                    TextWrapping = TextWrapping.Wrap,
                    IsTextSelectionEnabled = true,
                },
                CloseButtonText = close,
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = root,
            };
            await dialog.ShowAsync();
        }
        finally
        {
            _open = false;
        }
    }

    public static Task ShowErrorAsync(XamlRoot root, string title, string message) =>
        ShowMessageAsync(root, title, message);

    public static async Task<bool> ConfirmAsync(
        XamlRoot root,
        string title,
        string message,
        string primary = "Continue",
        string secondary = "Cancel")
    {
        if (_open)
        {
            return false;
        }
        _open = true;
        try
        {
            var dialog = new ContentDialog
            {
                Title = title,
                Content = new TextBlock
                {
                    Text = message,
                    TextWrapping = TextWrapping.Wrap,
                },
                PrimaryButtonText = primary,
                CloseButtonText = secondary,
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = root,
            };
            var result = await dialog.ShowAsync();
            return result == ContentDialogResult.Primary;
        }
        finally
        {
            _open = false;
        }
    }
}
