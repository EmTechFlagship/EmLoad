using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace EmLoad.WinUI.Services;

/// <summary>
/// Decodes the engine's <c>data:image/png;base64,…</c> app icons. The engine
/// embeds icons that way so no temporary files are needed.
/// </summary>
public static class ImageLoader
{
    private const string Prefix = "data:image/png;base64,";

    public static async Task<BitmapImage?> FromDataUriAsync(string? dataUri)
    {
        if (string.IsNullOrWhiteSpace(dataUri) ||
            !dataUri.StartsWith(Prefix, StringComparison.Ordinal))
        {
            return null;
        }

        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(dataUri[Prefix.Length..]);
        }
        catch (FormatException)
        {
            return null;
        }

        try
        {
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(bytes);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }

            stream.Seek(0);
            var image = new BitmapImage();
            await image.SetSourceAsync(stream);
            return image;
        }
        catch (Exception)
        {
            // A broken icon is not worth a crash.
            return null;
        }
    }
}
