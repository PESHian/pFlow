using System.Diagnostics;
using System.IO.Compression;
using PFlow.Core;

namespace PFlow.Setup;

/// The one thing to double-click: unpacks the universal package carried at the
/// end of this file, ends a running pFlow if the person agrees, runs the same
/// install script the ZIP used (install-universal.ps1: architecture choice,
/// hash check, Start menu shortcut), optionally adds a desktop shortcut, and
/// opens pFlow. `--no-launch` and `--no-desktop` keep the test run quiet.
internal static class Program
{
    const string Title = "pFlow Setup";

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles(); Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        bool launch = !args.Contains("--no-launch"), askDesktop = !args.Contains("--no-desktop"), quiet = args.Contains("--quiet");
        string local = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string temp = Path.Combine(local, "pFlow.setup-" + Guid.NewGuid().ToString("N"));
        using var window = new Progress();
        try {
            string me = Environment.ProcessPath ?? throw new InvalidOperationException("Setup could not find its own file.");
            long zipStart = ZipStart(me) ?? throw new InvalidOperationException("This copy of pFlow Setup carries no package. Download it again.");
            if (!EndRunningCopy(quiet)) return 1;
            bool desktop = askDesktop && !quiet && MessageBox.Show("Add a pFlow shortcut on the desktop too?", Title, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
            window.Show(); window.Say("Unpacking pFlow…");
            Extract(me, zipStart, temp, window);
            window.Say("Installing pFlow for your account…");
            RunInstall(temp, desktop);
            string installed = Path.Combine(local, "Programs", "pFlow", "pFlow.exe");
            if (!File.Exists(installed)) throw new InvalidOperationException("The install finished without pFlow.exe in place.");
            if (launch) Process.Start(new ProcessStartInfo(installed) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(installed) });
            window.Hide();
            if (!quiet) MessageBox.Show(launch ? "pFlow is installed and open. Look for its icon in the tray, near the clock." : "pFlow is installed.", Title, MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        } catch (Exception error) {
            window.Hide();
            if (!quiet) MessageBox.Show(error.Message, "pFlow was not installed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            else Console.Error.WriteLine(error.Message);
            return 1;
        } finally {
            try { if (Directory.Exists(temp)) Directory.Delete(temp, true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    static long? ZipStart(string path)
    {
        using var file = File.OpenRead(path);
        if (file.Length <= SetupPackage.TrailerLength) return null;
        var tail = new byte[SetupPackage.TrailerLength];
        file.Position = file.Length - tail.Length; file.ReadExactly(tail);
        return SetupPackage.ZipStart(tail, file.Length);
    }

    /// A running pFlow holds files the install replaces. Copies from 0.1.18 on
    /// listen for the quit signal; older ones are closed after the person says so.
    static bool EndRunningCopy(bool quiet)
    {
        var running = Process.GetProcessesByName("pFlow");
        if (running.Length == 0) return true;
        if (!quiet && MessageBox.Show("pFlow is running. Close it now and continue?", Title, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return false;
        try { using var quit = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\pFlow-by-Pesh-Windows-quit"); foreach (var _ in running) quit.Set(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        foreach (var process in running) {
            try { if (!process.WaitForExit(4000)) { process.Kill(); process.WaitForExit(5000); } } catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        return true;
    }

    static void Extract(string me, long zipStart, string temp, Progress window)
    {
        Directory.CreateDirectory(temp);
        using var file = File.OpenRead(me);
        using var zip = new ZipArchive(new SubStream(file, zipStart, file.Length - zipStart - SetupPackage.TrailerLength), ZipArchiveMode.Read);
        long total = zip.Entries.Sum(e => e.Length), done = 0;
        foreach (var entry in zip.Entries) {
            if (!SetupPackage.SafeEntry(entry.FullName)) throw new InvalidOperationException("The package holds an unsafe path and was not installed.");
            string target = Path.GetFullPath(Path.Combine(temp, entry.FullName));
            if (!target.StartsWith(temp + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("The package holds an unsafe path and was not installed.");
            if (entry.FullName.EndsWith('/')) { Directory.CreateDirectory(target); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            entry.ExtractToFile(target, true);
            done += entry.Length; window.Fraction(total == 0 ? 1 : (double)done / total);
        }
    }

    static void RunInstall(string root, bool desktop)
    {
        string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(shell)) throw new InvalidOperationException("Windows PowerShell is missing, so pFlow could not be installed.");
        var start = new ProcessStartInfo(shell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = root };
        foreach (string arg in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(root, "install-universal.ps1"), "-Root", root }) start.ArgumentList.Add(arg);
        if (desktop) start.ArgumentList.Add("-DesktopShortcut");
        using var process = Process.Start(start) ?? throw new InvalidOperationException("The install script could not start.");
        string output = process.StandardOutput.ReadToEnd(), errors = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0) {
            // The script's own plain sentence, when it threw one; otherwise its last lines.
            var lines = (errors + "\n" + output).Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            string reason = lines.FirstOrDefault(l => l.EndsWith('.') && !l.StartsWith('+') && !l.StartsWith("At ")) ?? string.Join("\n", lines.TakeLast(5));
            throw new InvalidOperationException(reason.Length > 0 ? reason : "The install script failed.");
        }
    }

    /// A read-only view of one part of a file, so ZipArchive sees the package as a whole ZIP.
    sealed class SubStream(Stream inner, long start, long length) : Stream
    {
        long position;
        public override bool CanRead => true; public override bool CanSeek => true; public override bool CanWrite => false;
        public override long Length => length;
        public override long Position { get => position; set => position = Math.Clamp(value, 0, length); }
        public override int Read(byte[] buffer, int offset, int count)
        {
            int allowed = (int)Math.Min(count, length - position); if (allowed <= 0) return 0;
            inner.Position = start + position; int read = inner.Read(buffer, offset, allowed); position += read; return read;
        }
        public override long Seek(long offset, SeekOrigin origin) => Position = origin switch { SeekOrigin.Begin => offset, SeekOrigin.Current => position + offset, _ => length + offset };
        public override void Flush() { }
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    /// A small window with one line and a bar; the person sees that something is happening.
    sealed class Progress : Form
    {
        readonly Label label = new() { Dock = DockStyle.Top, Height = 40, TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(12, 0, 12, 0) };
        readonly ProgressBar bar = new() { Dock = DockStyle.Top, Height = 22, Minimum = 0, Maximum = 1000, Margin = new Padding(12) };
        public Progress()
        {
            Text = Title; Width = 420; Height = 130; FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen; ControlBox = false; Padding = new Padding(12);
            Controls.Add(bar); Controls.Add(label);
        }
        public void Say(string text) { label.Text = text; Application.DoEvents(); }
        public void Fraction(double value) { bar.Value = (int)Math.Clamp(value * 1000, 0, 1000); Application.DoEvents(); }
    }
}
