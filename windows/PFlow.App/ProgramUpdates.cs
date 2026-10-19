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
        updateApplying = true; keyboard.Enabled = false;
        string job = Path.Combine(store.DirectoryPath, "Updates", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(job);
        Process? helper = null;
        try {
            using var client = new UpdateClient(); string archive = Path.Combine(job, "update.zip");
            await client.Download(offer, archive, progress, cancel);
            string package = Path.Combine(job, "package"); await Task.Run(() => ReleaseUpdates.Extract(archive, package), cancel); cancel.ThrowIfCancellationRequested();
            foreach (string name in new[] { "update-install.ps1", "install-windows.ps1", "WindowsArchitecture.ps1" }) File.Copy(Path.Combine(AppContext.BaseDirectory, "Update", name), Path.Combine(job, name));
            using var self = Process.GetCurrentProcess();
            var plan = new { package, destination = installed, version = offer.Version, processId = self.Id, startedTicks = self.StartTime.ToUniversalTime().Ticks };
            string planFile = Path.Combine(job, "plan.json"); File.WriteAllText(planFile, JsonSerializer.Serialize(plan));
            var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe")) { UseShellExecute = false, CreateNoWindow = true };
            foreach (string arg in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(job, "update-install.ps1"), "-Plan", planFile }) info.ArgumentList.Add(arg);
            helper = Process.Start(info) ?? throw new IOException("The update installer could not start.");
            long deadline = Environment.TickCount64 + 60000;
            while (!File.Exists(Path.Combine(job, "ready"))) {
                cancel.ThrowIfCancellationRequested();
                if (helper.HasExited || Environment.TickCount64 > deadline) throw new IOException("The update installer was not ready. Your installed app was not changed.");
                await Task.Delay(100, cancel);
            }
            cancel.ThrowIfCancellationRequested();
            Quit(); // Existing shutdown drains the worker and leaves clipboard restoration intact.
        } catch {
            File.WriteAllText(Path.Combine(job, "cancel"), "cancel");
            if (helper == null || helper.HasExited) { try { Directory.Delete(job, true); } catch (IOException) { } }
            throw;
        } finally {
            helper?.Dispose();
            if (!quitting) { updateApplying = false; keyboard.Reset(); keyboard.Enabled = store.Preferences.Enabled; }
        }
    }
}

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
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/pFlow;component/Assets/Pesh.ico"));
        action.Click += async (_, _) => await Run();
        timer = new(TimeSpan.FromMilliseconds(250), System.Windows.Threading.DispatcherPriority.Background, (_, _) => action.IsEnabled = !working && (offer == null || canInstall()), Dispatcher);
        Closed += (_, _) => { timer.Stop(); cancel.Cancel(); };
    }
    async Task Run()
    {
        working = true; action.IsEnabled = false;
        try {
            if (offer == null) {
                message.Text = "Checking for updates…";
                offer = await check(cancel.Token);
                message.Text = offer == null ? "You have the latest published version." : $"pFlow {offer.Version} is ready. Settings, history, and models stay on this computer.";
                action.Content = offer == null ? "Check again" : "Install and restart";
            } else {
                message.Text = "Downloading and checking the update…";
                await install(offer, new Progress<double>(value => progress.Value = value * 100), cancel.Token);
            }
        } catch (OperationCanceledException) { if (!cancel.IsCancellationRequested) message.Text = "The update check timed out. Try again."; }
        catch (InvalidOperationException error) { message.Text = error.Message; }
        catch (Exception) { message.Text = "The update could not finish. Your installed app was kept. Check your connection and try again."; }
        finally { working = false; }
    }
}
