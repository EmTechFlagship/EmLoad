using System.Text.Json;

namespace EmLoad.WinUI.Services;

public static class PatreonMembershipState
{
    private static readonly object Gate = new();
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "EmLoad",
        "membership.json");
    private static Preferences _preferences = Load();

    public static string? Tier
    {
        get { lock (Gate) return _preferences.Tier; }
    }

    public static bool IsSubscribed => Tier is "Plus" or "Pro";

    public static bool JitBenefitEnabled
    {
        get { lock (Gate) return _preferences.JitBenefitEnabled; }
        set => Update(preferences => preferences.JitBenefitEnabled = value);
    }

    public static bool EmLoadStoreBenefitEnabled
    {
        get { lock (Gate) return _preferences.EmLoadStoreBenefitEnabled; }
        set => Update(preferences => preferences.EmLoadStoreBenefitEnabled = value);
    }

    public static void SetTier(string? tier)
    {
        if (tier is not ("Plus" or "Pro"))
        {
            tier = null;
        }
        Update(preferences => preferences.Tier = tier);
    }

    private static void Update(Action<Preferences> update)
    {
        lock (Gate)
        {
            update(_preferences);
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(_preferences));
        }
    }

    private static Preferences Load()
    {
        try
        {
            return File.Exists(SettingsPath)
                ? JsonSerializer.Deserialize<Preferences>(File.ReadAllText(SettingsPath)) ?? new Preferences()
                : new Preferences();
        }
        catch
        {
            return new Preferences();
        }
    }

    private sealed class Preferences
    {
        public string? Tier { get; set; }
        public bool JitBenefitEnabled { get; set; } = true;
        public bool EmLoadStoreBenefitEnabled { get; set; } = true;
    }
}
