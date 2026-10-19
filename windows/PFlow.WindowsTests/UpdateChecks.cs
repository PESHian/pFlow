using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Threading;

internal static partial class Program
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern void GetNativeSystemInfo(IntPtr buffer);
    static void NativeUpdates()
    {
        _ = Application.Current ?? new PFlow.Windows.Program { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        bool ready = false; int checks = 0, installs = 0;
        var offer = new UpdateOffer("0.1.11", "https://github.com/PESHian/pFlow/releases/download/fixture/pFlow-Windows-x64-0.1.11-update.zip", 23, new string('a',64));
        void Invoke(Button button) => ((IInvokeProvider)UIElementAutomationPeer.CreatePeerForElement(button).GetPattern(PatternInterface.Invoke)).Invoke();
        void Until(Func<bool> condition) { long until = Environment.TickCount64 + 3000; while (!condition() && Environment.TickCount64 < until) { Drain(); Thread.Sleep(20); } }
        var window = new UpdateWindow(new Preferences(), () => ready, (value, progress, token) => { Check("install receives the checked offer", value == offer && !token.IsCancellationRequested); installs++; return Task.CompletedTask; }, _ => { checks++; return Task.FromResult<UpdateOffer?>(offer); });
        try {
            window.Show(); window.UpdateLayout(); Drain();
            Check("update window never checks automatically", checks == 0 && installs == 0 && window.Icon != null);
            var button = Descendants<Button>(window).Single(); Invoke(button); Until(() => checks == 1 && button.Content as string == "Install and restart");
            Check("native check button shows available version", checks == 1 && Descendants<TextBlock>(window).Any(text => text.Text.Contains("0.1.11 is ready")));
            Thread.Sleep(300); Drain(); Check("installation disabled while dictation is busy", !button.IsEnabled && installs == 0);
            ready = true; Until(() => button.IsEnabled); Invoke(button); Until(() => installs == 1);
            Check("native install button invokes installer once", installs == 1 && checks == 1);
        } finally { window.Close(); }
        bool canceled = false;
        var pending = new UpdateWindow(new Preferences(), () => true, (_, _, _) => Task.CompletedTask, async token => { using var registration = token.Register(() => canceled = true); await Task.Delay(Timeout.Infinite, token); return null; });
        pending.Show(); pending.UpdateLayout(); Drain(); Invoke(Descendants<Button>(pending).Single()); Drain(); pending.Close(); Until(() => canceled);
        Check("closing update window cancels pending network check", canceled);
        string root = Path.Combine(Path.GetTempPath(), "pflow-update-settings-fictional-" + Guid.NewGuid().ToString("N"));
        try {
            var store = new StateStore(root); int opened = 0;
            using var hook = new KeyboardHook(_ => {}) { Enabled = false };
            var application = (PFlow.Windows.Program)Application.Current;
            const System.Reflection.BindingFlags fields = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
            typeof(PFlow.Windows.Program).GetField("store", fields)!.SetValue(application, store);
            typeof(PFlow.Windows.Program).GetField("keyboard", fields)!.SetValue(application, hook);
            string blocked = Path.Combine(root, "Updates"); File.WriteAllText(blocked, "Fictional file blocks directory creation.");
            bool refused = false;
            try { application.InstallUpdateInJob(offer, new Progress<double>(), CancellationToken.None, root, Path.Combine(blocked,"job")).GetAwaiter().GetResult(); }
            catch (IOException) { refused = true; }
            Check("folder failure restores dictation and permits another update", refused && application.CanUpdate && hook.Enabled == store.Preferences.Enabled);
            File.Delete(blocked); hook.Enabled = false;
            var settings = new SettingsWindow(store, new Whisper(root), new LocalTextModel(root), hook, () => {}, () => false, () => opened++);
            try { settings.Show(); settings.UpdateLayout(); Drain(); var button = Descendants<Button>(settings).Single(item => item.Content as string == "Check for updates"); button.BringIntoView(); Invoke(button); Until(() => opened == 1); Check("Settings opens updater without starting capture", opened == 1 && !hook.Enabled); }
            finally { settings.Close(); }
        } finally { Directory.Delete(root, true); }
        IntPtr native = System.Runtime.InteropServices.Marshal.AllocHGlobal(64); string expected;
        try { GetNativeSystemInfo(native); expected = System.Runtime.InteropServices.Marshal.ReadInt16(native) switch { 0 => "x86", 9 => "x64", 12 => "arm64", _ => "unsupported" }; }
        finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(native); }
        Check("update choice follows OS architecture including emulation", UpdateWindow.Target == "windows-" + expected);
    }
}
