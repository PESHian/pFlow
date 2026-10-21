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

    /// Absolute Windows paths compared as text (either separator, any case), so
    /// the same rule holds in the Linux test run.
    static string Normal(string path) => path.Trim().Replace('/', '\\').TrimEnd('\\');

    public static bool SamePath(string? a, string? b) =>
        a != null && b != null && string.Equals(Normal(a), Normal(b), StringComparison.OrdinalIgnoreCase);

    /// True when `path` is inside `root` (the install folder itself or below it).
    public static bool Inside(string path, string root) =>
        Normal(path).StartsWith(Normal(root) + '\\', StringComparison.OrdinalIgnoreCase);

    /// Launch-at-sign-in must open this copy: re-point when the Run key names
    /// another pFlow.exe that is missing (null version) or older, and only
    /// when this copy lives in the real install folder (`installRoot`, where
    /// Install.cmd puts it). A copy run from a zip, Temp, a build or any
    /// other folder never changes the key.
    public static bool RunKeyNeedsRepoint(string? registeredCommand, string currentPath, Version currentVersion, string installRoot, Func<string, Version?> versionOf)
    {
        if (!Inside(currentPath, installRoot)) return false;
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
