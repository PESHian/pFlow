namespace PFlow.Core;

/// The tray menu, as text, so a test can read it. Dictation starts with the
/// activation key, never from the menu, so there is no start item.
public static class TrayMenu
{
    public const string ShowControl = "Show recording control", Settings = "Settings", Updates = "Check for updates",
        History = "History", Enabled = "Dictation enabled", Cancel = "Cancel", Quit = "Quit";
    public static readonly IReadOnlyList<string> Items = [ShowControl, Settings, Updates, History, Enabled, Cancel, Quit];
}

/// Older copies of pFlow left behind by an install to another folder. The
/// decisions are pure; the app reads the registry and process list.
public static class InstalledCopies
{
    /// The executable named by a Run command, without quotes or arguments.
    public static string? CommandPath(string? command)
    {
        if (string.IsNullOrWhiteSpace(command)) return null;
        string value = command.Trim();
        if (value.StartsWith('"')) { int end = value.IndexOf('"', 1); return end > 1 ? value[1..end] : null; }
        int space = value.IndexOf(' ');
        return space > 0 ? value[..space] : value;
    }

    public static bool SamePath(string? a, string? b) =>
        a != null && b != null && string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

    /// Launch-at-sign-in must open this copy: re-point when the Run key names
    /// another pFlow.exe that is missing (null version) or older.
    public static bool RunKeyNeedsRepoint(string? registeredCommand, string currentPath, Version currentVersion, Func<string, Version?> versionOf)
    {
        var path = CommandPath(registeredCommand);
        if (path == null || SamePath(path, currentPath)) return false;
        var version = versionOf(path);
        return version == null || version < currentVersion;
    }

    /// Single instance: a running older copy at another path gives way to
    /// this one instead of keeping the newer one from starting.
    public static bool OlderCopyShouldYield(string? otherPath, Version? otherVersion, string currentPath, Version currentVersion) =>
        otherPath != null && otherVersion != null && !SamePath(otherPath, currentPath) && otherVersion < currentVersion;
}
