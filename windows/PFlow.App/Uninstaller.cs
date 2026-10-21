using Microsoft.Win32;

namespace PFlow.Windows;

/// pFlow under Settings > Apps > Installed apps, for this account only, and
/// the removal it offers. `Register` runs at every start of the installed copy,
/// so Setup and the in-app updater keep the version current without a second
/// copy of the rule. `Run` is `pFlow.exe --uninstall`: asks once, asks whether
/// to keep settings and History (default keep), ends the running copy, removes
/// the shortcuts, the Run and Uninstall keys and pFlow's own folders under
/// Programs. A copy that will not quit (busy with a take or a clipboard restore)
/// is never ended by force: the uninstall stops and says so. Nothing outside
/// this account is touched, and no admin is needed.
internal static class Uninstaller
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run", RunValue = "pFlow by Pesh", Shortcut = "pFlow by Pesh.lnk";
    const string Title = "pFlow by Pesh";
    static string Me => Environment.ProcessPath ?? "";
    // The LOCALAPPDATA/APPDATA variables first, as Setup and the install scripts read them, so the install test can redirect them.
    static string Local => Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    static string Roaming => Environment.GetEnvironmentVariable("APPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    static string Programs => Path.Combine(Local, "Programs");
    static string InstallRoot => Path.Combine(Programs, "pFlow");
    static string DataRoot => Path.Combine(Local, "pFlow");
    /// Held while an uninstall runs; the running copy quits only when it sees this.
    internal const string RunningMutex = "Local\\pFlow-by-Pesh-Windows-uninstalling";

    /// Writes the Installed apps row when this copy runs from the install folder. Quiet on any failure.
    internal static void Register()
    {
        try {
            if (!InstalledCopies.Inside(Me, InstallRoot)) return;
            var version = StaleCopies.VersionOf(Me) ?? new Version(0, 0, 0);
            long bytes = 0;
            foreach (var file in new DirectoryInfo(InstallRoot).EnumerateFiles("*", SearchOption.AllDirectories)) bytes += file.Length;
            using var key = Registry.CurrentUser.CreateSubKey(UninstallEntry.KeyPath);
            foreach (var pair in UninstallEntry.Values(Me, InstallRoot, version, bytes, DateTimeOffset.Now)) key.SetValue(pair.Key, pair.Value, pair.Value is int ? RegistryValueKind.DWord : RegistryValueKind.String);
        } catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
    }

    /// `pFlow.exe --uninstall [--quiet]`. Quiet (tests, "QuietUninstallString") keeps settings and History and asks nothing.
    internal static int Run(bool quiet)
    {
        if (!quiet && MessageBox.Show(UninstallEntry.ConfirmQuestion, Title, MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return 1;
        bool keepData = quiet || MessageBox.Show(UninstallEntry.KeepDataQuestion, Title, MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.Yes) == MessageBoxResult.Yes;
        using var running = new Mutex(true, RunningMutex);
        try {
            if (!EndRunningCopies()) {
                string why = Uninspectable ? UninstallEntry.CannotInspect : UninstallEntry.CannotQuit;
                if (!quiet) MessageBox.Show(why, Title, MessageBoxButton.OK, MessageBoxImage.Warning); else Console.Error.WriteLine(why);
                return 1;
            }
            foreach (string link in new[] { Path.Combine(Roaming, "Microsoft", "Windows", "Start Menu", "Programs", Shortcut), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), Shortcut) })
                if (File.Exists(link)) File.Delete(link);
            using (var run = Registry.CurrentUser.OpenSubKey(RunKey, writable: true)) run?.DeleteValue(RunValue, false);
            Registry.CurrentUser.DeleteSubKeyTree(UninstallEntry.KeyPath, false);
            if (!keepData && Directory.Exists(DataRoot)) Directory.Delete(DataRoot, true);
            // Folders this process is not running from go now; the install folder (holding this exe) goes a moment after exit.
            var later = new List<string>();
            if (Directory.Exists(Programs))
                foreach (var folder in new DirectoryInfo(Programs).EnumerateDirectories().Where(d => UninstallEntry.OwnsFolder(d.Name))) {
                    if (InstalledCopies.Inside(Me, folder.FullName)) { later.Add(folder.FullName); continue; }
                    try { folder.Delete(true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { later.Add(folder.FullName); }
                }
            if (later.Count > 0) RemoveAfterExit(later);
            if (!quiet) MessageBox.Show(UninstallEntry.Done, Title, MessageBoxButton.OK, MessageBoxImage.Information);
            return 0;
        } catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException) {
            string message = "pFlow could not be removed completely: " + PrivateLog.Scrub(error.Message);
            if (!quiet) MessageBox.Show(message, Title, MessageBoxButton.OK, MessageBoxImage.Error); else Console.Error.WriteLine(message);
            return 1;
        }
    }

    internal const string QuitEvent = "Local\\pFlow-by-Pesh-Windows-uninstall-quit";

    /// Copies running from the folder being removed are asked to quit (they listen on `QuitEvent`
    /// and finish any insertion and clipboard restore first). Waits up to 90 s; never ends one by
    /// force, so a clipboard item mid-restore is never lost. False when one is still running.
    static bool EndRunningCopies()
    {
        var others = Process.GetProcessesByName("pFlow").Where(p => p.Id != Environment.ProcessId).ToList();
        // A pFlow this account cannot look into (one running as administrator) might be the installed copy: stop rather than pull its folder away.
        if (others.Any(p => PathOf(p) == null)) { Uninspectable = true; return false; }
        var running = others.Where(p => UninstallEntry.RunsFrom(PathOf(p), InstallRoot)).ToList();
        if (running.Count == 0) return true;
        try { using var quit = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEvent); foreach (var _ in running) quit.Set(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        var deadline = DateTime.UtcNow.AddSeconds(90);
        foreach (var process in running) {
            try { while (!process.HasExited && DateTime.UtcNow < deadline) process.WaitForExit(500); if (!process.HasExited) return false; }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        return true;
    }
    static bool Uninspectable;
    static string? PathOf(Process process) { try { return process.MainModule?.FileName; } catch { return null; } }

    /// A detached command script that removes the folders once this process has exited, trying for
    /// up to 30 s, then deletes itself. Plain batch: no delayed expansion, so a "!" in a name is safe.
    static void RemoveAfterExit(IEnumerable<string> folders)
    {
        string temp = Path.GetTempPath();
        string script = Path.Combine(temp, "pflow-remove-" + Guid.NewGuid().ToString("N") + ".cmd");
        var lines = new List<string> { "@echo off", "set tries=0", ":again" };
        foreach (string folder in folders) lines.Add("if exist \"" + folder + "\" rmdir /s /q \"" + folder + "\" >nul 2>&1");
        string gone = string.Join(" ", folders.Select(folder => "if not exist \"" + folder + "\""));
        lines.Add(gone + " goto done");
        lines.Add("set /a tries+=1"); lines.Add("if %tries% geq 30 goto done"); lines.Add("timeout /t 1 /nobreak >nul"); lines.Add("goto again");
        lines.Add(":done"); lines.Add("del \"%~f0\"");
        File.WriteAllLines(script, lines);
        var cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
        var info = new ProcessStartInfo(cmd) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = temp };
        info.ArgumentList.Add("/c"); info.ArgumentList.Add(script);
        Process.Start(info)?.Dispose();
    }
}
