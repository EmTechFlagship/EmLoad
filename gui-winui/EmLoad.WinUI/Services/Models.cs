using System.Text.Json;

namespace EmLoad.WinUI.Services;

/// <summary>One connected device, enriched with lockdown details when available.</summary>
public sealed record DeviceInfo(
    string Udid,
    string? Name,
    string? Model,
    string? OsVersion,
    string? Connection,
    bool Responded)
{
    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? "Unnamed device" : Name!;
    public string ShortUdid => Udid.Length > 12 ? $"{Udid[..8]}…" : Udid;
    public string Subtitle => $"{Model ?? "unknown model"} · iOS {OsVersion ?? "?"}";
    public string ConnectionLabel => string.IsNullOrWhiteSpace(Connection)
        ? "unknown"
        : Connection!.ToUpperInvariant();
}

/// <summary>A recorded sideload with its remaining signature lifetime.</summary>
public sealed record LibraryApp(
    string BundleId,
    string? Name,
    DateTimeOffset? InstalledAt,
    DateTimeOffset? ExpiresAt,
    double? DaysLeft,
    bool Expired,
    string? Icon)
{
    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? BundleId : Name!;
    public string InstalledText => InstalledAt?.LocalDateTime.ToString("yyyy-MM-dd") ?? "-";
    public string ExpiresText => ExpiresAt?.LocalDateTime.ToString("yyyy-MM-dd") ?? "-";

    public string TimeLeftText => DaysLeft switch
    {
        null => "-",
        _ when Expired => "expired",
        < 1 => $"{Math.Max(0, (int)(DaysLeft!.Value * 24))}h left",
        _ => $"{DaysLeft:F1}d left",
    };
}

public sealed record DoctorCheck(string Name, string Status, string Message)
{
    public string Glyph => Status switch
    {
        "ok" => "\u2714",
        "warn" => "\u26A0",
        "error" => "\u2716",
        _ => "?",
    };
}

public sealed record AccountStatus(
    bool Authenticated,
    string? Email,
    string? TeamId,
    bool HasAuthToken,
    int AccountCount);

public sealed record IpaSummary(
    string Path,
    string? AppBundle,
    string? DisplayName,
    string? BundleId,
    string? Version,
    string? Build,
    string? MinimumOs,
    bool Encrypted,
    IReadOnlyList<string> Extensions,
    string? Icon);

public sealed record SigningStatus(bool Available, string? Path, string? Version, string? Error);

/// <summary>Maps the engine's snake_case JSON onto the records above.</summary>
public static class Models
{
    public static DeviceInfo Device(JsonElement element)
    {
        var info = element.TryGetProperty("info", out var i) && i.ValueKind == JsonValueKind.Object
            ? i
            : default;

        return new DeviceInfo(
            GetString(element, "serial") ?? "",
            info.ValueKind == JsonValueKind.Object ? GetString(info, "DeviceName") : null,
            info.ValueKind == JsonValueKind.Object ? GetString(info, "ProductType") : null,
            info.ValueKind == JsonValueKind.Object ? GetString(info, "ProductVersion") : null,
            GetString(element, "connection_type"),
            info.ValueKind == JsonValueKind.Object && info.EnumerateObject().Any());
    }

    public static LibraryApp Library(JsonElement element) => new(
        GetString(element, "bundle_id") ?? "",
        GetString(element, "name"),
        GetDate(element, "installed_at"),
        GetDate(element, "expires_at"),
        GetDouble(element, "days_left"),
        element.TryGetProperty("expired", out var expired) &&
        expired.ValueKind == JsonValueKind.True,
        element.TryGetProperty("icon", out var icon) && icon.ValueKind == JsonValueKind.String
            ? icon.GetString()
            : null);

    public static DoctorCheck Check(JsonElement element) => new(
        GetString(element, "name") ?? "?",
        GetString(element, "status") ?? "?",
        GetString(element, "message") ?? "");

    public static AccountStatus Account(JsonElement element) => new(
        element.TryGetProperty("authenticated", out var auth) && auth.ValueKind == JsonValueKind.True,
        GetString(element, "email"),
        GetString(element, "team_id"),
        element.TryGetProperty("has_auth_token", out var token) && token.ValueKind == JsonValueKind.True,
        GetInt(element, "account_count") ?? 0);

    public static IpaSummary Ipa(JsonElement element, string path)
    {
        var extensions = new List<string>();
        if (element.TryGetProperty("extensions", out var exts) && exts.ValueKind == JsonValueKind.Array)
        {
            extensions.AddRange(exts.EnumerateArray()
                .Where(e => e.ValueKind == JsonValueKind.String)
                .Select(e => e.GetString()!));
        }

        return new IpaSummary(
            path,
            GetString(element, "app_bundle"),
            GetString(element, "display_name"),
            GetString(element, "bundle_id"),
            GetString(element, "version"),
            GetString(element, "build"),
            GetString(element, "minimum_os"),
            element.TryGetProperty("has_sc_info", out var sc) && sc.ValueKind == JsonValueKind.True,
            extensions,
            GetString(element, "icon"));
    }

    public static SigningStatus Signing(JsonElement element) => new(
        element.TryGetProperty("available", out var available) && available.ValueKind == JsonValueKind.True,
        GetString(element, "path"),
        GetString(element, "version"),
        GetString(element, "error"));

    // -- scalar helpers ---------------------------------------------------- //
    public static string? GetString(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    public static double? GetDouble(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.Number
            ? value.GetDouble()
            : null;

    public static int? GetInt(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.Number
            ? (int)value.GetDouble()
            : null;

    public static bool GetBool(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.True;

    private static DateTimeOffset? GetDate(JsonElement element, string name)
    {
        var raw = GetString(element, name);
        return DateTimeOffset.TryParse(raw, out var parsed) ? parsed : null;
    }
}
