using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using PFlow.Core;
using PFlow.Windows;

// Live text on Windows with the real resident worker and fictional narration
// fed in real time through the live path. No microphone, no key events.
internal static partial class Program
{
    static bool liveTextOnly, liveFocusOnly;
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);

    sealed class TakeReport
    {
        public string Name = "", Mode = "";
        public double AudioMs, AudioEndMs, StopMs, FinalMs, CpuSeconds, FirstUpdateMs = -1, FailedAtMs = -1, TooSlowAtMs = -1;
        public int UpdatesBeforeEnd, Windows;
        public long PeakAppBytes, PeakWorkerBytes;
        public string LiveAtEnd = "", LiveWords = "", Final = "";
        public List<(double Ms, string Text)> Updates = [];
    }

    static byte[] Pcm(string file)
    {
        var bytes = File.ReadAllBytes(file);
        Check("fixture is 16 kHz mono 16-bit: " + Path.GetFileName(file), BitConverter.ToInt16(bytes, 22) == 1 && BitConverter.ToInt32(bytes, 24) == 16000 && BitConverter.ToInt16(bytes, 34) == 16);
        return bytes[44..];
    }

    static TimeSpan Cpu(int? id) { try { return id is int pid ? Process.GetProcessById(pid).TotalProcessorTime : TimeSpan.Zero; } catch (ArgumentException) { return TimeSpan.Zero; } }
    static long Memory(int? id) { try { return id is int pid ? Process.GetProcessById(pid).WorkingSet64 : 0; } catch (ArgumentException) { return 0; } }

    /// One take as Program runs it: the setting is read once at the start, the
    /// recorder's 100 ms blocks arrive in real time, live windows go to the warm
    /// worker, stop drains live work, then the normal whole-recording pass runs.
    static async Task<TakeReport> FeedTake(string name, string audio, string mode, bool continuous, Whisper whisper, StateStore store, LivePreview preview,
        Capsule capsule, Func<TakeReport, LiveRecognizer?, Task>? during = null, Action? eachBlock = null, Action<string>? typed = null, TimeSpan? windowLimit = null)
    {
        var report = new TakeReport { Name = name, Mode = LiveTextModes.Resolve(mode) };
        var trigger = new PFlow.Core.Trigger();
        var start = continuous ? Enumerable.Repeat(0, 1).Select(_ => { trigger.Press(0); trigger.Release(90); var action = trigger.Press(220); trigger.Release(300); return action; }).Single() : trigger.Press(0);
        Check(name + " trigger starts the take", start == (continuous ? PFlow.Core.TriggerAction.Continuous : PFlow.Core.TriggerAction.Start));
        var pcm = Pcm(Path.Combine(root, audio)); report.AudioMs = pcm.Length / 32.0;
        var reconciler = new LiveTranscriptReconciler(); var clock = new Stopwatch();
        LiveRecognizer? live = null; int requestsBefore = whisper.LiveRequests;
        if (LiveTextModes.ShowsPreview(report.Mode)) {
            LiveRecognizer recognizer = null!;
            recognizer = new LiveRecognizer((uint)Random.Shared.Next(1, int.MaxValue), whisper, "en",
                update => preview.Dispatcher.InvokeAsync(() => {
                    // As Program does: a repeat of the same words is not shown again but still goes to typing.
                    long? accepted = reconciler.LastSequence; bool changed = reconciler.Apply(update);
                    if (reconciler.LastSequence == accepted) return;
                    if (changed) {
                        preview.ShowText(reconciler.Text); preview.Reveal(capsule.Handle);
                        report.Updates.Add((clock.Elapsed.TotalMilliseconds, reconciler.Text));
                    }
                    typed?.Invoke(reconciler.Text);
                }),
                () => preview.Dispatcher.InvokeAsync(() => { report.FailedAtMs = clock.Elapsed.TotalMilliseconds; preview.SetNote("Live words stopped"); }),
                onTooSlow: () => preview.Dispatcher.InvokeAsync(() => { report.TooSlowAtMs = clock.Elapsed.TotalMilliseconds; preview.SetNote(LiveTake.TooSlowNote); }), windowLimit: windowLimit);
            live = recognizer; reconciler.Begin(recognizer.SessionName); preview.Begin();
        }
        capsule.Set(continuous ? PFlow.Core.Phase.Continuous : PFlow.Core.Phase.Recording);
        if (live != null) preview.Reveal(capsule.Handle);
        int? worker = whisper.WorkerId; var cpuApp = Process.GetCurrentProcess().TotalProcessorTime; var cpuWorker = Cpu(worker);
        clock.Start(); live?.Start(); double sampled = 0;
        for (int at = 0; at < pcm.Length; at += 3200) {
            int count = Math.Min(3200, pcm.Length - at); double due = (at + count) / 32.0;
            while (clock.Elapsed.TotalMilliseconds < due) await Task.Delay(Math.Max(1, (int)(due - clock.Elapsed.TotalMilliseconds)));
            live?.Append(pcm[at..(at + count)]);
            eachBlock?.Invoke();
            if (clock.Elapsed.TotalMilliseconds - sampled >= 500) {
                sampled = clock.Elapsed.TotalMilliseconds; var self = Process.GetCurrentProcess(); self.Refresh();
                report.PeakAppBytes = Math.Max(report.PeakAppBytes, self.WorkingSet64); report.PeakWorkerBytes = Math.Max(report.PeakWorkerBytes, Memory(whisper.WorkerId));
            }
            if (during != null) await during(report, live);
        }
        report.AudioEndMs = clock.Elapsed.TotalMilliseconds;
        report.UpdatesBeforeEnd = report.Updates.Count(update => update.Ms <= report.AudioEndMs);
        report.FirstUpdateMs = report.Updates.Count > 0 ? report.Updates[0].Ms : -1;
        report.LiveAtEnd = reconciler.Text;
        var stopAction = continuous ? Enumerable.Repeat(0, 1).Select(_ => { trigger.Press(40_000); return trigger.Release(40_060); }).Single() : trigger.Release((long)report.AudioEndMs);
        Check(name + " trigger stops the take", stopAction == PFlow.Core.TriggerAction.Stop);
        var stop = Stopwatch.StartNew();
        report.LiveWords = live != null ? await live.Stop() : "";
        report.StopMs = stop.Elapsed.TotalMilliseconds; report.Windows = live?.Session.Inferences ?? 0;
        report.CpuSeconds = (Process.GetCurrentProcess().TotalProcessorTime - cpuApp + (whisper.WorkerId == worker ? Cpu(worker) - cpuWorker : TimeSpan.Zero)).TotalSeconds;
        if (live == null) Check(name + " Off sends no live windows", whisper.LiveRequests == requestsBefore && report.Updates.Count == 0 && !preview.IsVisible);
        return report;
    }

    static void Print(TakeReport report)
    {
        var gaps = report.Updates.Zip(report.Updates.Skip(1), (a, b) => b.Ms - a.Ms).OrderBy(x => x).ToList();
        Console.WriteLine($"LIVE {report.Name} mode={report.Mode} audio={report.AudioMs:F0}ms updatesBeforeEnd={report.UpdatesBeforeEnd} first={report.FirstUpdateMs:F0}ms medianGap={(gaps.Count > 0 ? gaps[gaps.Count / 2] : 0):F0}ms windows={report.Windows} stopDrain={report.StopMs:F0}ms final={report.FinalMs:F0}ms cpu={report.CpuSeconds:F1}s peakApp={report.PeakAppBytes / 1048576}MB peakWorker={report.PeakWorkerBytes / 1048576}MB failedAt={report.FailedAtMs:F0}");
        foreach (var update in report.Updates.Take(4).Concat(report.Updates.Count > 4 ? [report.Updates[^1]] : [])) Console.WriteLine($"  {update.Ms,7:F0}ms {update.Text}");
        Console.WriteLine($"  final: {report.Final}");
    }

    static void Render(LivePreview preview, string name, double scale, double textScale)
    {
        preview.ApplyTextSize(textScale);
        var content = (FrameworkElement)preview.Content;
        content.Measure(new Size(preview.Width, double.PositiveInfinity)); content.Arrange(new Rect(0, 0, preview.Width, content.DesiredSize.Height)); content.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * scale), (int)Math.Ceiling(content.ActualHeight * scale), 96 * scale, 96 * scale, System.Windows.Media.PixelFormats.Pbgra32);
        bitmap.Render(content);
        var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(Path.Combine(root, "live-preview-" + name + ".png")); png.Save(file);
        preview.ApplyTextSize();
    }

    static async Task LiveText()
    {
        string directory = Path.Combine(root, "live-text-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        var store = new StateStore(directory); store.Preferences.Language = "en";
        await using var whisper = new Whisper(directory, PackageAssets);
        var capsule = new Capsule(store); var preview = new LivePreview(store);
        try {
            var warm = Stopwatch.StartNew(); await whisper.Prewarm(); Console.WriteLine($"LIVE verified worker warm in {warm.ElapsedMilliseconds}ms");
            var pipeline = new DictationPipeline(store, whisper, new LocalTextModel(directory, PackageAssets));
            var reports = new List<TakeReport>();
            foreach (var (name, audio, mode, continuous, tail) in new[] {
                ("hold", "latency-long.wav", LiveTextModes.Preview, false, "to its owner"),
                ("continuous", "latency-extended.wav", LiveTextModes.TypeInApp, true, "went home"),
                ("off", "latency-extended.wav", LiveTextModes.Off, true, "went home") }) {
                var report = await FeedTake(name, audio, mode, continuous, whisper, store, preview, capsule);
                capsule.Set(PFlow.Core.Phase.Processing);
                if (report.Mode != LiveTextModes.Off) { preview.Finishing(); Check(name + " preview stays up while finishing", preview.IsVisible); }
                var final = Stopwatch.StartNew();
                var prepared = await pipeline.Prepare(Path.Combine(root, audio), report.AudioMs / 1000, directory, (_, _) => { }, CancellationToken.None);
                report.FinalMs = final.Elapsed.TotalMilliseconds; report.Final = prepared.Text; Print(report);
                capsule.Set(PFlow.Core.Phase.Inserted); preview.Clear();
                Check(name + " finished text includes the last words", Words(prepared.Text).EndsWith(Words(tail)));
                Check(name + " final pass reused the warm worker", whisper.LastMetrics.Reused);
                if (report.Mode != LiveTextModes.Off) {
                    Check(name + " preview updated before the narration ended", report.UpdatesBeforeEnd >= 3 && report.FirstUpdateMs > 0 && report.FirstUpdateMs < 4000);
                    Check(name + " live windows were bounded", report.Windows > 0 && report.Windows <= report.AudioMs / 1000 + 1);
                    Check(name + " stop drained live work promptly", report.StopMs < 3000);
                    Check(name + " preview cleared after the take", !preview.IsVisible && preview.Shown == "");
                }
                reports.Add(report);
            }
            var on = reports[1]; var off = reports[2];
            Console.WriteLine($"LIVE cpu same narration: on={on.CpuSeconds:F1}s off={off.CpuSeconds:F1}s ({on.CpuSeconds / on.AudioMs * 100000:F0}% vs {off.CpuSeconds / off.AudioMs * 100000:F0}% of one core); peak worker on={on.PeakWorkerBytes / 1048576}MB off={off.PeakWorkerBytes / 1048576}MB; final on={on.FinalMs:F0}ms off={off.FinalMs:F0}ms");
            File.WriteAllText(Path.Combine(root, "live-text-report.json"), JsonSerializer.Serialize(reports.Select(r => new {
                r.Name, r.Mode, r.AudioMs, r.AudioEndMs, r.UpdatesBeforeEnd, r.FirstUpdateMs, r.Windows, r.StopMs, r.FinalMs, r.CpuSeconds, r.PeakAppBytes, r.PeakWorkerBytes,
                Updates = r.Updates.Select(u => new { u.Ms, u.Text }), r.LiveAtEnd, r.Final }), new JsonSerializerOptions { WriteIndented = true }));

            string story = string.Join(" ", Enumerable.Repeat("The lighthouse keeper counted the copper lanterns while the pelicans waited by the harbor wall.", 6));
            foreach (string theme in new[] { "light", "dark" }) {
                store.Preferences.Theme = theme; preview.ApplyTheme(); preview.Begin(); preview.ShowText(story);
                Render(preview, theme + "-100", 1, 1); Render(preview, theme + "-200", 2, 1); Render(preview, theme + "-large-text-150", 1.5, 2.25);
            }
            await LiveTextSettings(directory);
            preview.Begin(); preview.ShowText(story);
            Check("long narration preview shows a bounded tail", preview.Shown.Length <= 241 && preview.Shown.StartsWith('…'));
            preview.Clear();
        } finally { preview.Close(); capsule.Close(); Directory.Delete(directory, true); }
    }

    static async Task LiveTextSettings(string parent)
    {
        string directory = Path.Combine(parent, "settings"); Directory.CreateDirectory(directory);
        using var keyboard = new KeyboardHook(_ => { }) { Enabled = false };
        var store = new StateStore(directory);
        foreach (string theme in new[] { "light", "dark" })
        foreach (double width in new[] { 900.0, 420.0 }) {
            store.Preferences.Theme = theme;
            var window = new SettingsWindow(store, new Whisper(directory), new LocalTextModel(directory), keyboard, () => { }, () => false) { ShowActivated = false, Width = width };
            try {
                window.Show(); await Task.Delay(150); window.UpdateLayout();
                var picker = Descendants<System.Windows.Controls.ComboBox>(window).Single(x => System.Windows.Automation.AutomationProperties.GetName(x) == "Live text");
                Check("Live text offers the three choices", picker.Items.Cast<object>().Select(x => x.ToString()).SequenceEqual(new[] { "Off", "Preview in pFlow", "Type in the current app" }));
                if (theme == "light" && width > 500) {
                    Check("Live text starts Off", picker.SelectedValue as string == LiveTextModes.Off);
                    picker.SelectedIndex = 1;
                    Check("Preview in pFlow is saved for the next recording", new StateStore(directory).Preferences.LiveTextMode == LiveTextModes.Preview);
                    picker.SelectedIndex = 2;
                    Check("Type in the current app is saved", new StateStore(directory).Preferences.LiveTextMode == LiveTextModes.TypeInApp);
                    Check("Settings explains typing into the app", Descendants<System.Windows.Controls.TextBlock>(window).Any(x => x.Text.StartsWith("Types your words into the app as you talk")));
                }
                Descendants<System.Windows.Controls.TextBlock>(window).First(x => x.Text.EndsWith("can differ a little from the preview.") || x.Text.StartsWith("Words appear in your app")).BringIntoView();
                await Task.Delay(150); window.UpdateLayout();
                string Shown(System.Windows.Controls.ComboBox box) => string.Join("|", Descendants<System.Windows.Controls.TextBlock>(box).Select(x => x.Text));
                if (width > 500) Check($"{theme} Live text box shows its label, not its data", Shown(picker) is "Off" or "Type in the current app");
                foreach (var box in Descendants<System.Windows.Controls.ComboBox>(window)) Console.WriteLine($"LIVE settings box '{System.Windows.Automation.AutomationProperties.GetName(box)}' shows '{Shown(box)}'");
                var content = (FrameworkElement)window.Content;
                var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * 2), (int)Math.Ceiling(content.ActualHeight * 2), 192, 192, System.Windows.Media.PixelFormats.Pbgra32); bitmap.Render(content);
                var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(bitmap));
                using var output = File.Create(Path.Combine(root, $"live-settings-{theme}-{width:F0}.png")); png.Save(output);
            } finally { window.Close(); }
        }
    }

    /// Closes only our fictional Notepad tabs, without saving them. Notepad may
    /// hold other tabs in the same window; those are never touched.
    static async Task CloseFictionalTabs()
    {
        var notepads = Process.GetProcessesByName("notepad").Select(p => p.Id).ToHashSet();
        foreach (AutomationElement window in AutomationElement.RootElement.FindAll(TreeScope.Children, System.Windows.Automation.Condition.TrueCondition)) {
            try {
                if (!notepads.Contains(window.Current.ProcessId)) continue;
                var tabs = window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem));
                foreach (AutomationElement tab in tabs) {
                    if (!tab.Current.Name.Contains("pflow-fictional-live-")) continue;
                    if (tab.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var select)) ((SelectionItemPattern)select).Select();
                    await Task.Delay(200);
                    var close = tab.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button));
                    if (close?.GetCurrentPattern(InvokePattern.Pattern) is not InvokePattern invoke) { Console.WriteLine("LIVE could not find a fictional tab's close button"); continue; }
                    invoke.Invoke();
                    for (int i = 0; i < 20; i++) {
                        await Task.Delay(150);
                        var dontSave = window.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, "Don't save"));
                        if (dontSave?.GetCurrentPattern(InvokePattern.Pattern) is InvokePattern skip) { skip.Invoke(); break; }
                    }
                    await Task.Delay(300);
                }
            } catch (ElementNotAvailableException) { }
        }
    }

    /// In the signed-in session: a fictional Notepad keeps focus, selection and
    /// clipboard while the preview updates, then gets the finished text once.
    /// Also a worker crash and a model failure in the middle of a take.
    static async Task LiveFocus()
    {
        string directory = Path.Combine(root, "live-focus-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        string name = "pflow-fictional-live-" + Guid.NewGuid().ToString("N"), file = Path.Combine(directory, name + ".txt");
        File.WriteAllText(file, "Fictional prefix. ");
        string model = Path.Combine(directory, "ggml-small.bin");
        File.Copy(Path.Combine(PackageAssets, "models", "ggml-small.bin"), model);
        await CloseFictionalTabs();
        var start = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; start.ArgumentList.Add(file); Process.Start(start);
        var notepad = await WindowWith(name); var edit = await Editor(notepad);
        using var owner = new HwndSource(new HwndSourceParameters("pFlow fictional live owner") { Width = 10, Height = 10 });
        var store = new StateStore(directory); store.Preferences.Language = "en"; store.Preferences.CopyDictationToClipboard = false;
        await using var whisper = new Whisper(directory, PackageAssets);
        var capsule = new Capsule(store); var preview = new LivePreview(store);
        try {
            await whisper.Prewarm();
            Check("live focus test uses its own model copy", whisper.ModelPath == model);
            var pipeline = new DictationPipeline(store, whisper, new LocalTextModel(directory, PackageAssets));
            int history = 0;
            foreach (var (take, theme) in new[] { ("preview", "light"), ("crash", "dark"), ("model-failure", "light") }) {
                store.Preferences.Theme = theme; preview.ApplyTheme(); capsule.ApplyTheme();
                await Focus(notepad, edit); End(edit);
                var target = InsertionTarget.Capture(); string before = Read(edit);
                IntPtr foreground = Native.GetForegroundWindow(); var focused = AutomationElement.FocusedElement.GetRuntimeId();
                uint clipboard = Native.GetClipboardSequenceNumber(); bool focusKept = true, styleKept = true, inside = true, shot = false, killed = false; int checks = 0;
                void Watch() {
                    if (!preview.IsVisible) return;
                    checks++;
                    focusKept &= Native.GetForegroundWindow() == foreground && AutomationElement.FocusedElement.GetRuntimeId().SequenceEqual(focused) && Native.GetClipboardSequenceNumber() == clipboard;
                    styleKept &= (Native.GetWindowLongPtr(preview.Handle, -20).ToInt64() & 0x08000020) == 0x08000020 && !preview.IsActive;
                    var screen = System.Windows.Forms.Screen.FromHandle(capsule.Handle).WorkingArea;
                    inside &= Native.GetWindowRect(preview.Handle, out var p) && Native.GetWindowRect(capsule.Handle, out var c) && p.Left >= screen.Left && p.Right <= screen.Right && p.Top >= screen.Top && p.Bottom <= screen.Bottom && p.Bottom <= c.Top;
                }
                async Task During(TakeReport report, LiveRecognizer? live) {
                    if (!shot && report.Updates.Count >= 2 && Native.GetWindowRect(preview.Handle, out var r)) {
                        shot = true;
                        using var bitmap = new System.Drawing.Bitmap(r.Right - r.Left, r.Bottom - r.Top);
                        using (var graphics = System.Drawing.Graphics.FromImage(bitmap)) graphics.CopyFromScreen(r.Left, r.Top, 0, 0, bitmap.Size);
                        bitmap.Save(Path.Combine(root, $"live-preview-screen-{take}-{theme}.png"));
                    }
                    if (take != "preview" && !killed && report.Updates.Count >= 2 && live is { Session.Busy: true } && whisper.WorkerId is int id) {
                        // The resident worker dies while it recognizes a live window.
                        await Task.Delay(300);
                        if (!live.Session.Busy) return;
                        killed = true;
                        try { Process.GetProcessById(id).Kill(); } catch (ArgumentException) { }
                        for (int i = 0; i < 100 && report.FailedAtMs < 0; i++) await Task.Delay(50);
                        Check(take + " a worker crash during a live window is noticed", report.FailedAtMs > 0);
                        if (take == "model-failure") {
                            // ...and the model can no longer be verified, so the final pass fails too.
                            using var stream = new FileStream(model, FileMode.Open, FileAccess.ReadWrite); stream.Position = 4096; int value = stream.ReadByte(); stream.Position = 4096; stream.WriteByte((byte)(value ^ 1));
                        }
                    }
                }
                var report = await FeedTake(take, "latency-long.wav", LiveTextModes.Preview, take == "crash", whisper, store, preview, capsule, During, Watch);
                Check(take + " preview never took focus, the caret or the clipboard", checks > 10 && focusKept);
                Check(take + " preview is no-activate and click-through", styleKept);
                Check(take + " preview stays above the control inside the work area", inside);
                if (take != "preview") Check(take + " live failure is shown, words kept", report.FailedAtMs > 0 && preview.Header == "Live words stopped" && report.LiveWords.Length > 0);
                capsule.Set(PFlow.Core.Phase.Processing); preview.Finishing();
                string audio = Path.Combine(directory, take + ".wav"); File.Copy(Path.Combine(root, "latency-long.wav"), audio, true);
                var result = await pipeline.Run(audio, report.AudioMs / 1000, target, directory, owner.Handle, (phase, detail) => capsule.Set(phase, detail), CancellationToken.None, report.LiveWords);
                preview.Clear();
                var saved = new StateStore(directory).History;
                Check(take + " saves exactly one History entry", saved.Count == ++history);
                Check(take + " clipboard unchanged", Native.GetClipboardSequenceNumber() == clipboard);
                if (take == "model-failure") {
                    Check("model failure keeps the live words in History with an honest status", result.Status == LiveTake.KeptStatus && saved[0].Text == report.LiveWords.Trim() && saved[0].InsertionStatus == LiveTake.KeptStatus);
                    Check("model failure types nothing", Normalize(Read(edit)) == Normalize(before));
                    Console.WriteLine($"LIVE model-failure kept: {saved[0].Text}");
                } else {
                    string after = Normalize(Read(edit)), typed = saved[0].Text;
                    int Count(string text) => (text.Length - text.Replace(typed, "").Length) / typed.Length;
                    Check(take + " finished text is typed once", result.Status == "Inserted" && after.StartsWith(Normalize(before)) && Count(after) == Count(Normalize(before)) + 1);
                    Check(take + " finished text includes the last words", Words(typed).EndsWith(Words("to its owner")));
                    if (take == "crash") Check("after a crash the final pass started a new verified worker", whisper.LastMetrics.Reused == false);
                }
                report.Final = saved[0].Text; Print(report);
            }
            // A borderless full-screen window, as browsers and players use, keeps focus under the preview.
            var full = new Window { WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, WindowState = WindowState.Maximized, Title = "pflow-fictional-fullscreen", Background = System.Windows.Media.Brushes.DarkSlateGray };
            full.Show(); await Task.Delay(300);
            var fullHandle = new WindowInteropHelper(full).Handle;
            await Activate(AutomationElement.FromHandle(fullHandle));
            capsule.Set(PFlow.Core.Phase.Recording); preview.Begin(); preview.ShowText("Fictional words over a full-screen window."); preview.Reveal(capsule.Handle); await Task.Delay(300);
            bool above = false; for (IntPtr w = GetWindow(fullHandle, 3); w != IntPtr.Zero; w = GetWindow(w, 3)) if (w == preview.Handle) { above = true; break; }
            Check("preview shows above a full-screen window without taking focus", above && Native.GetForegroundWindow() == fullHandle);
            preview.Clear(); capsule.Set(PFlow.Core.Phase.Canceled); full.Close();
        } finally {
            preview.Close(); capsule.Close();
            await CloseFictionalTabs();
            await Task.Delay(500);
            try { Directory.Delete(directory, true); } catch (IOException) { }
        }
    }
}
