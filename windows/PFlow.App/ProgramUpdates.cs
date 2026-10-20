using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace PFlow.Windows;

internal sealed partial class Program
{
    UpdateWindow? updateWindow;
    bool updateApplying;
    internal bool CanUpdate => !quitting && !updateApplying && !operations.Busy && phase != Phase.Inserting && ClipboardLease.Pending.Count == 0;
    void OpenUpdates()
    {
        if (updateWindow != null) { updateWindow.Activate(); return; }
        updateWindow = new UpdateWindow(store.Preferences, () => CanUpdate, InstallUpdate); updateWindow.Closed += (_, _) => updateWindow = null; updateWindow.Show();
    }
    async Task InstallUpdate(UpdateOffer offer, IProgress<double> progress, CancellationToken cancel)
    {
        if (!CanUpdate) throw new InvalidOperationException("Finish dictation and text insertion before updating.");
        string installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "pFlow");
        if (!string.Equals(Path.GetFullPath(Environment.ProcessPath!), Path.Combine(installed, "pFlow.exe"), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Install pFlow with Install.cmd once before using in-app updates.");
        string job = Path.Combine(store.DirectoryPath, "Updates", Guid.NewGuid().ToString("N"));
        await InstallUpdateInJob(offer, progress, cancel, installed, job);
    }
    internal async Task InstallUpdateInJob(UpdateOffer offer, IProgress<double> progress, CancellationToken cancel, string installed, string job)
    {
        updateApplying = true; keyboard.Enabled = false;
        Process? helper = null;
        UpdateStage stage = UpdateStage.Prepare;
        try {
            Directory.CreateDirectory(job);
            using var client = new UpdateClient(); string archive = Path.Combine(job, "update.zip");
            stage = UpdateStage.Download;
            await client.Download(offer, archive, progress, cancel);
            stage = UpdateStage.Unpack;
            string package = Path.Combine(job, "package"); await Task.Run(() => ReleaseUpdates.Extract(archive, package), cancel); cancel.ThrowIfCancellationRequested();
            stage = UpdateStage.Installer;
            foreach (string name in new[] { "update-install.ps1", "install-windows.ps1", "WindowsArchitecture.ps1" }) File.Copy(Path.Combine(AppContext.BaseDirectory, "Update", name), Path.Combine(job, name));
            using var self = Process.GetCurrentProcess();
            var plan = new { package, destination = installed, version = offer.Version, processId = self.Id, startedTicks = self.StartTime.ToUniversalTime().Ticks };
            string planFile = Path.Combine(job, "plan.json"); File.WriteAllText(planFile, JsonSerializer.Serialize(plan));
            helper = Process.Start(UpdateInstallerStartInfo(job, planFile)) ?? throw new IOException("The update installer could not start.");
            long deadline = Environment.TickCount64 + 60000;
            while (!File.Exists(Path.Combine(job, "ready"))) {
                cancel.ThrowIfCancellationRequested();
                if (helper.HasExited || Environment.TickCount64 > deadline) throw new IOException("The update installer was not ready. Your installed app was not changed.");
                await Task.Delay(100, cancel);
            }
            cancel.ThrowIfCancellationRequested();
            Quit(); // Existing shutdown drains the worker and leaves clipboard restoration intact.
        } catch (Exception error) {
            if (error is not OperationCanceledException) SaveUpdateError(job, stage, error);
            try { if (Directory.Exists(job)) File.WriteAllText(Path.Combine(job, "cancel"), "cancel"); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            if (helper == null || helper.HasExited) { try { Directory.Delete(job, true); } catch (IOException) { } }
            if (error is OperationCanceledException) throw;
            throw new UpdateInstallException(stage, error);
        } finally {
            helper?.Dispose();
            if (!quitting) { updateApplying = false; keyboard.Reset(); keyboard.Enabled = store.Preferences.Enabled; }
        }
    }
    internal static ProcessStartInfo UpdateInstallerStartInfo(string job, string planFile)
    {
        // Windows PowerShell's compiler must not resolve the app's .NET runtime DLLs.
        var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe")) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = job };
        foreach (string arg in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(job, "update-install.ps1"), "-Plan", planFile }) info.ArgumentList.Add(arg);
        return info;
    }
    internal static void SaveUpdateError(string job, UpdateStage stage, Exception error)
    {
        try {
            string details = $"{DateTimeOffset.UtcNow:O}\nStage: {stage}\n{error}\n";
            string helperError = Path.Combine(job, "error.txt");
            if (File.Exists(helperError)) {
                using var reader = new StreamReader(helperError); char[] buffer = new char[12288];
                int count = reader.ReadBlock(buffer, 0, buffer.Length); details += new string(buffer, 0, count);
            }
            // One bounded local file survives cleanup; no dictation or clipboard data is logged.
            File.WriteAllText(Path.Combine(Path.GetDirectoryName(job)!, "last-error.txt"), details[..Math.Min(details.Length, 16384)]);
        } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

internal enum UpdateStage { Prepare, Download, Unpack, Installer }
internal sealed class UpdateInstallException(UpdateStage stage, Exception inner) : IOException(stage switch {
    UpdateStage.Download => "The update could not download. Your installed app was kept. Check your connection and try again.",
    UpdateStage.Unpack => "The update could not be unpacked or verified. Your installed app was kept. Try again.",
    UpdateStage.Installer => "The update installer could not get ready. Your installed app was kept. Try again.",
    _ => "The update could not be prepared. Your installed app was kept. Try again."
}, inner);

internal sealed class UpdateWindow : Window
{
    readonly Func<bool> canInstall;
    readonly Func<UpdateOffer, IProgress<double>, CancellationToken, Task> install;
    readonly TextBlock message = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 12) };
    readonly Button action = new() { Content = "Check for updates", Margin = new Thickness(0, 8, 0, 8), Padding = new Thickness(14, 8, 14, 8) };
    readonly ProgressBar progress = new() { Minimum = 0, Maximum = 100, Height = 5 };
    readonly CancellationTokenSource cancel = new();
    readonly System.Windows.Threading.DispatcherTimer timer;
    readonly Func<CancellationToken, Task<UpdateOffer?>> check;
    UpdateOffer? offer; bool working;
    public static string CurrentVersion => typeof(Program).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0.0.0";
    public static string Target => "windows-" + RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant();
    public UpdateWindow(Preferences preferences, Func<bool> canInstall, Func<UpdateOffer, IProgress<double>, CancellationToken, Task> install, Func<CancellationToken, Task<UpdateOffer?>>? check = null)
    {
        this.canInstall = canInstall; this.install = install;
        this.check = check ?? (async token => { using var client = new UpdateClient(); return await client.Check(Target, CurrentVersion, token); });
        Title = "pFlow updates"; Width = 400; Height = 260; ResizeMode = ResizeMode.NoResize; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Resources.MergedDictionaries.Add((ResourceDictionary)Application.LoadComponent(new Uri("/pFlow;component/SettingsStyles.xaml", UriKind.Relative)));
        var body = new StackPanel { Margin = new Thickness(24) }; body.Children.Add(new TextBlock { Text = "pFlow " + CurrentVersion, FontSize = 22, FontWeight = FontWeights.SemiBold });
        message.Text = "Check GitHub for a newer release. Checks run only when you ask."; body.Children.Add(message); body.Children.Add(progress); body.Children.Add(action); Content = body;
        PeshTheme.Apply(this, preferences);
        SetResourceReference(BackgroundProperty, "PeshBackground"); SetResourceReference(ForegroundProperty, "PeshText");
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/pFlow;component/Assets/Pesh.ico"));
        action.Click += async (_, _) => await Run();
        timer = new(TimeSpan.FromMilliseconds(250), System.Windows.Threading.DispatcherPriority.Background, (_, _) => action.IsEnabled = !working && (offer == null || canInstall()), Dispatcher);
        Closed += (_, _) => { timer.Stop(); cancel.Cancel(); };
    }
    async Task Run()
    {
        working = true; action.IsEnabled = false; progress.Value = 0;
        try {
            if (offer == null) {
                message.Text = "Checking for updates…";
                offer = await check(cancel.Token);
                message.Text = offer == null ? "You have the latest published version." : $"pFlow {offer.Version} is ready. Settings, history, and models stay on this computer.";
                action.Content = offer == null ? "Check again" : "Install and restart";
            } else {
                message.Text = "Downloading and checking the update…";
                await install(offer, new Progress<double>(value => { if (working) progress.Value = value * 100; }), cancel.Token);
            }
        } catch (OperationCanceledException) { progress.Value = 0; if (!cancel.IsCancellationRequested) message.Text = "The update check timed out. Try again."; }
        catch (InvalidOperationException error) { progress.Value = 0; message.Text = error.Message; }
        catch (UpdateInstallException error) { progress.Value = 0; message.Text = error.Message; }
        catch (Exception) { progress.Value = 0; message.Text = "Could not check for updates. Check your connection and try again."; }
        finally { working = false; }
    }
}
