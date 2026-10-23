using Microsoft.Win32;

namespace PFlow.Windows;

/// Retires an older copy of pFlow that an install to another folder left
/// behind: the older running copy gives way to this one, and the sign-in
/// Run key is pointed at this copy. Nothing on disk is deleted.
internal static class StaleCopies
{
    const string QuitEvent = "Local\\pFlow-by-Pesh-Windows-quit", RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run", RunValue = "pFlow by Pesh";
    static string Me => Environment.ProcessPath ?? "";
    /// Where install-windows.ps1 (Install.cmd) puts pFlow.
    static string InstallRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "pFlow");
    static Version Mine => VersionOf(Me) ?? new Version(0, 0);

    internal static Version? VersionOf(string path)
    {
        try {
            if (!File.Exists(path)) return null;
            var info = FileVersionInfo.GetVersionInfo(path);
            return Version.TryParse(info.ProductVersion?.Split('+', '-')[0], out var product) ? product
                : new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart);
        } catch { return null; }
    }

    static string? PathOf(Process process) { try { return process.MainModule?.FileName; } catch { return null; } }

    static List<Process> OlderCopies() => Process.GetProcessesByName("pFlow")
        .Where(p => p.Id != Environment.ProcessId)
        .Where(p => { var path = PathOf(p); return InstalledCopies.OlderCopyShouldYield(path, path == null ? null : VersionOf(path), Me, Mine); })
        .ToList();

    /// Called when another copy holds the single-instance mutex. An older
    /// copy is asked to quit (copies from 0.1.18 on listen; earlier ones are
    /// closed) and the mutex is taken over. False when the other copy is this
    /// version or newer: then this launch simply ends, as before.
    internal static bool TakeOverFromOlderCopy(Mutex single)
    {
        var older = OlderCopies();
        if (older.Count == 0) return false;
        using (var quit = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEvent)) foreach (var _ in older) quit.Set();
        if (single.WaitOne(TimeSpan.FromSeconds(4))) return true;
        foreach (var process in older) { try { if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); } } catch { /* already gone or not ours to end */ } }
        return single.WaitOne(TimeSpan.FromSeconds(5));
    }

    const string SettingsEvent = "Local\\pFlow-by-Pesh-Windows-settings";

    /// Opening pFlow while it already runs: the running copy is asked to open
    /// its Settings window, and this launch ends.
    internal static void AskRunningCopyToOpenSettings()
    {
        try { using var open = new EventWaitHandle(false, EventResetMode.AutoReset, SettingsEvent); open.Set(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// The running copy's side of `AskRunningCopyToOpenSettings`.
    internal static void ListenForOpenSettings(Action openSettings) => Listen(SettingsEvent, openSettings, "pFlow open settings");

    /// The uninstaller's request to quit (Uninstaller.QuitEvent), honored only while an
    /// uninstaller is really running (it holds Uninstaller.RunningMutex); a stray signal is ignored.
    internal static void ListenForUninstall(Action quit) => Listen(Uninstaller.QuitEvent, () => { if (UninstallerRunning()) quit(); }, "pFlow uninstall quit");

    static bool UninstallerRunning()
    {
        try { using var held = Mutex.OpenExisting(Uninstaller.RunningMutex); return true; }
        catch (Exception error) when (error is WaitHandleCannotBeOpenedException or UnauthorizedAccessException or IOException) { return false; }
    }

    /// A pre-created event with an access list that keeps this copy out, or any other failure,
    /// only disables that listener; it never stops pFlow from starting.
    static void Listen(string eventName, Action action, string threadName)
    {
        var listener = new Thread(() => {
            try {
                using var signal = new EventWaitHandle(false, EventResetMode.AutoReset, eventName);
                while (true) { signal.WaitOne(); action(); }
            } catch (Exception error) when (error is IOException or UnauthorizedAccessException or WaitHandleCannotBeOpenedException or ObjectDisposedException) { }
        }) { IsBackground = true, Name = threadName };
        listener.Start();
    }

    /// Waits for a newer copy's request to quit. A stale signal with no newer
    /// copy running is ignored.
    internal static void ListenForNewerCopy(Action quit)
    {
        var listener = new Thread(() => {
            using var signal = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEvent);
            while (true) {
                signal.WaitOne();
                bool newer = Process.GetProcessesByName("pFlow").Any(p => { var path = p.Id == Environment.ProcessId ? null : PathOf(p); return path != null && (VersionOf(path) ?? new Version(0, 0)) > Mine; });
                if (newer) { quit(); return; }
            }
        }) { IsBackground = true, Name = "pFlow newer copy" };
        listener.Start();
    }

    /// The Run key is only touched when it already exists (the person chose
    /// launch at sign-in), names a missing or older pFlow.exe, and this copy
    /// runs from the install folder.
    internal static void RepointRunKey()
    {
        try {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key?.GetValue(RunValue) is not string command) return;
            if (InstalledCopies.RunKeyNeedsRepoint(command, Me, Mine, InstallRoot, VersionOf)) key.SetValue(RunValue, "\"" + Me + "\"");
        } catch { /* a locked key leaves the old value; Settings can set it again */ }
    }
}
