namespace PFlow.Core;

/// The card shown when a finished take could not go into the app: the words,
/// a plain line saying why, a Copy button. Nothing here touches the clipboard;
/// the words are also in History. Pure text rules, so a test can read them.
public static class InsertionPrompt
{
    public const string Title = "pFlow couldn't type this";
    public const string Hint = "Copy it, or select the words and press Ctrl+C.";
    public const string Copy = "Copy", Copied = "Copied";

    /// The sentences every refusal ends with. They say where the words are,
    /// which the card itself now shows, so the reason line drops them.
    static readonly string[] Trailers = ["Your text is in History.", "Open History to copy your dictation.", "Your words are in History."];

    /// True when a take's outcome needs the card: anything that did not put
    /// the words in. "Inserted…" outcomes never do, nor words typed live and kept.
    public static bool Needed(string status, bool typedLive) => !typedLive && !status.StartsWith("Inserted", StringComparison.Ordinal);

    /// The plain line under the title: the outcome without its "in History" trailer.
    public static string Reason(string status)
    {
        string line = status.Trim();
        foreach (string trailer in Trailers)
            if (line.EndsWith(trailer, StringComparison.Ordinal)) line = line[..^trailer.Length].TrimEnd();
        return line.Length == 0 ? "The words could not go into that box." : line;
    }
}

/// The one short notice at a fresh start: where pFlow is and how to dictate.
public static class StartNotice
{
    public const string Title = "pFlow is running";
    public const string Settings = "Settings";
    public static string Body(string activationKey) =>
        $"Find it in the tray, near the clock. Hold {activationKey} and speak; let go to put the words in.";
}

/// pFlow's row under Settings > Apps > Installed apps, for the signed-in
/// account only (HKCU). Pure values; the app writes them to the registry when
/// it runs from the install folder, so Setup and the in-app updater both keep
/// the version current by starting the installed copy.
public static class UninstallEntry
{
    public const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\pFlow by Pesh";
    public const string DisplayName = "pFlow by Pesh", Publisher = "Pesh", UninstallSwitch = "--uninstall";

    public static IReadOnlyDictionary<string, object> Values(string executable, string installRoot, Version version, long installedBytes, DateTimeOffset installed) => new Dictionary<string, object> {
        ["DisplayName"] = DisplayName,
        ["Publisher"] = Publisher,
        ["DisplayVersion"] = $"{version.Major}.{version.Minor}.{Math.Max(version.Build, 0)}",
        ["DisplayIcon"] = executable + ",0",
        ["InstallLocation"] = installRoot,
        ["InstallDate"] = installed.ToString("yyyyMMdd", System.Globalization.CultureInfo.InvariantCulture),
        ["UninstallString"] = "\"" + executable + "\" " + UninstallSwitch,
        ["QuietUninstallString"] = "\"" + executable + "\" " + UninstallSwitch + " --quiet",
        // REG_DWORD, in KB, as Installed apps expects.
        ["EstimatedSize"] = (int)Math.Min(int.MaxValue, (installedBytes + 1023) / 1024),
        ["NoModify"] = 1, ["NoRepair"] = 1,
    };

    /// Folders in Programs that belong to pFlow: the install, a staged install,
    /// and the previous/failed copies the installer keeps beside it.
    public static bool OwnsFolder(string name) =>
        name.Equals("pFlow", StringComparison.OrdinalIgnoreCase) || name.Equals("pFlow.new", StringComparison.OrdinalIgnoreCase)
        || name.StartsWith("pFlow.previous-", StringComparison.OrdinalIgnoreCase) || name.StartsWith("pFlow.failed-", StringComparison.OrdinalIgnoreCase);

    public const string ConfirmQuestion = "Remove pFlow from this PC?";
    public const string KeepDataQuestion = "Keep your settings and History? (Yes keeps them for a later install; No deletes them.)";
    public const string Done = "pFlow was removed.";
}
