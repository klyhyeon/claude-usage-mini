using Microsoft.Win32;

namespace ClaudeUsageMini;

/// <summary>Launch at login via the per-user Run key — no installer, no admin rights.</summary>
public static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "ClaudeUsageMini";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is not null;
        }
    }

    /// <summary>Registers on first run so the tracker is simply always there.
    /// A user who removes the entry stays removed — this only fills a blank.</summary>
    public static void EnableIfUnset()
    {
        if (IsEnabled) return;
        Set(true);
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (key is null) return;
        if (enabled) key.SetValue(ValueName, $"\"{Environment.ProcessPath}\"");
        else key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
