using Microsoft.UI.Xaml;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace EmLoad.WinUI.Services;

/// <summary>File/folder pickers that work in an unpackaged WinUI 3 window.</summary>
public static class Pickers
{
    public static async Task<string?> OpenIpaAsync(Window window)
    {
        var picker = new FileOpenPicker
        {
            SuggestedStartLocation = PickerLocationId.Downloads,
            ViewMode = PickerViewMode.List,
        };
        picker.FileTypeFilter.Add(".ipa");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));

        var file = await picker.PickSingleFileAsync();
        return file?.Path;
    }

    public static async Task<string?> PickFolderAsync(Window window, string? startPath = null)
    {
        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(window));

        var folder = await picker.PickSingleFolderAsync();
        return folder?.Path;
    }
}
