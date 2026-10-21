using Microsoft.Win32;

namespace PFlow.Windows;

/// pFlow under Settings > Apps > Installed apps, for this account only, and
/// the removal it offers. `Register` runs at every start of the installed copy,
/// so Setup and the in-app updater keep the version current without a second
/// copy of the rule. `Run` is `pFlow.exe --uninstall`: asks once, asks whether
/// to keep settings and History (default keep), ends the running copy, removes
/// the shortcuts, the Run and Uninstall keys and pFlow's own folders under
/// Programs. Nothing outside this account is touched, and no admin is needed.
internal static class Uninstaller
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run", RunValue = "pFlow by Pesh", Shortcut = "pFlow by Pesh.lnk";
    const string Title = "pFlow by Pesh";
    static string Me => Environment.ProcessPath ?? "";
    static string Programs => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs");
    static string InstallRoot => Path.Combine(Programs, "pFlow");
    static string DataRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "pFlow");

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
        try {
            EndRunningCopies();
            foreach (string link in new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft", "Windows", "Start Menu", "Programs", Shortcut), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), Shortcut) })
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

    /// The running copy is asked to quit (it listens on `QuitEvent`); one that does not go in 8 s is ended.
    static void EndRunningCopies()
    {
        var running = Process.GetProcessesByName("pFlow").Where(p => p.Id != Environment.ProcessId).ToList();
        if (running.Count == 0) return;
        try { using var quit = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEvent); foreach (var _ in running) quit.Set(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        foreach (var process in running) {
            try { if (!process.WaitForExit(8000)) { process.Kill(); process.WaitForExit(5000); } }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
    }

    /// A detached command script that removes the folders once this process has exited, trying for up to 30 s, then deletes itself.
    static void RemoveAfterExit(IEnumerable<string> folders)
    {
        string temp = Path.GetTempPath();
        string script = Path.Combine(temp, "pflow-remove-" + Guid.NewGuid().ToString("N") + ".cmd");
        var lines = new List<string> { "@echo off", "setlocal enabledelayedexpansion", "for /l %%i in (1,1,30) do (" };
        foreach (string folder in folders) lines.Add("  if exist \"" + folder + "\" rmdir /s /q \"" + folder + "\" >nul 2>&1");
        lines.Add("  set gone=1");
        foreach (string folder in folders) lines.Add("  if exist \"" + folder + "\" set gone=0");
        lines.Add("  if \"!gone!\"==\"1\" goto done"); lines.Add("  timeout /t 1 /nobreak >nul"); lines.Add(")"); lines.Add(":done"); lines.Add("del \"%~f0\"");
        File.WriteAllLines(script, lines);
        var cmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
        var info = new ProcessStartInfo(cmd) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = temp };
        info.ArgumentList.Add("/c"); info.ArgumentList.Add(script);
        Process.Start(info)?.Dispose();
    }
}
