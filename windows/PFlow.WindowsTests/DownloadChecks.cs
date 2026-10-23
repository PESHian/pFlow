using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Net;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

internal static partial class Program
{
    /// Every download control: one Download button before, a bar + plain line + one Cancel during,
    /// "Downloaded · size" after, the reason + Download after a failure; each under its own button in
    /// its own card. A canceled real download leaves no partial file. The model-in-use rule by file
    /// name (fictional bytes). PFLOW_SHOTS=<folder> writes downloading-{theme}-{width}.png to look at.
    static void NativeDownloads()
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        string? shots = Environment.GetEnvironmentVariable("PFLOW_SHOTS");
        const long text = 1107409472, speech = 487601967;
        Check("before: one Download button with the size, nothing else", DownloadControl.Describe(DownloadState.Ready, text, 0, null) == new DownloadControl.Look("Download (1.1 GB)", false, false, ""));
        Check("during: the bar, the plain line and one Cancel; no Download button", DownloadControl.Describe(DownloadState.Downloading, text, 120_000_000, null) == new DownloadControl.Look(null, true, true, "Downloading… 120 MB of 1.1 GB"));
        Check("after: Downloaded with the size and nothing to press", DownloadControl.Describe(DownloadState.Installed, speech, 0, null) == new DownloadControl.Look(null, false, false, "Downloaded · 488 MB"));
        Check("failed: the plain reason and the Download button again", DownloadControl.Describe(DownloadState.Failed, text, 0, "The server said no.") == new DownloadControl.Look("Download (1.1 GB)", false, false, "The server said no."));
        Check("sizes read as the buttons always have", FileSize.Describe(2497280256) == "2.5 GB" && FileSize.Describe(speech) == "488 MB" && FileSize.Describe(0) == "0 MB");

        // The control itself, driven by a fake fetch.
        TaskCompletionSource? pending = null; IProgress<double>? report = null; bool installed = false; string? blocked = null;
        var control = new DownloadControl("Fictional model", text, () => installed, (progress, cancel) => { report = progress; pending = new(); cancel.Register(() => pending.TrySetCanceled(cancel)); return pending.Task; }, () => blocked);
        var window = new Window { Width = 420, Height = 200, Content = control, ShowActivated = false };
        window.Resources.MergedDictionaries.Add((ResourceDictionary)Application.LoadComponent(new Uri("/pFlow;component/SettingsStyles.xaml", UriKind.Relative)));
        List<string> Buttons() => Descendants<Button>(control).Where(b => b.IsVisible).Select(b => (string)b.Content).ToList();
        bool Bar() => Descendants<ProgressBar>(control).Single().IsVisible;
        // The control's own line, not the label inside a themed button (that is a TextBlock too).
        string Line() => control.Children.OfType<TextBlock>().Where(t => t.IsVisible).Select(t => t.Text).SingleOrDefault() ?? "";
        void Press(string label) { Descendants<Button>(control).Single(b => b.IsVisible && (string)b.Content == label).RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); Drain(); }
        try {
            window.Show(); window.UpdateLayout(); Drain();
            Check("before: only Download (1.1 GB) is visible, no bar, no line", Buttons().SequenceEqual(["Download (1.1 GB)"]) && !Bar() && Line() == "" && control.State == DownloadState.Ready);
            blocked = "Finish or cancel dictation first."; Press("Download (1.1 GB)");
            Check("while dictating the button stays and the line says why", Buttons().SequenceEqual(["Download (1.1 GB)"]) && Line() == "Finish or cancel dictation first." && pending == null);
            blocked = null; Press("Download (1.1 GB)"); report!.Report(120_000_000.0 / text); Drain();
            Check($"during: the bar, 'Downloading… 120 MB of 1.1 GB' and one Cancel; the Download button is gone (buttons {string.Join("/", Buttons())}, bar {Bar()}, line '{Line()}', state {control.State})", Buttons().SequenceEqual(["Cancel"]) && Bar() && Line() == "Downloading… 120 MB of 1.1 GB" && control.State == DownloadState.Downloading);
            Press("Cancel"); Drain();
            Check("cancel returns to the Download state with nothing else to press", Buttons().SequenceEqual(["Download (1.1 GB)"]) && !Bar() && Line() == "Download canceled." && control.State == DownloadState.Ready);
            Press("Download (1.1 GB)"); pending!.SetException(new IOException("The server said no.")); Drain();
            Check("a failed download shows its plain line and the Download button", Buttons().SequenceEqual(["Download (1.1 GB)"]) && !Bar() && Line() == "The server said no." && control.State == DownloadState.Failed);
            Press("Download (1.1 GB)"); installed = true; pending!.SetResult(); Drain();
            Check("after: Downloaded · 1.1 GB and no buttons", Buttons().Count == 0 && !Bar() && Line() == "Downloaded · 1.1 GB" && control.State == DownloadState.Installed);
            Check("a progress report after the download ended changes nothing", Run(() => report!.Report(.5)) && Line() == "Downloaded · 1.1 GB");
        } finally { window.Close(); }

        // Inside Settings: each control, with its bar, sits in the card of its own section.
        foreach (string theme in new[] { "dark", "light" }) foreach (double width in new[] { 420.0, 900.0 }) {
            string root = Path.Combine(Path.GetTempPath(), "pflow-download-fictional-" + Guid.NewGuid().ToString("N"));
            try {
                var store = new StateStore(root); store.Preferences.Theme = theme;
                using var hook = new KeyboardHook(_ => { }) { Enabled = false };
                var settings = new SettingsWindow(store, new Whisper(root), new LocalTextModel(root), hook, () => { }, () => false) { ShowActivated = false, Width = width, Height = 640 };
                try {
                    settings.Show(); settings.UpdateLayout(); Drain();
                    string tag = $"{theme} {width:F0}: ";
                    var controls = Descendants<DownloadControl>(settings).ToList();
                    var textControl = controls.Single(c => System.Windows.Automation.AutomationProperties.GetName(c) == "Text model download");
                    var speechControl = controls.Single(c => System.Windows.Automation.AutomationProperties.GetName(c) == "Whisper model download");
                    var textCard = CardAround(textControl); var speechCard = CardAround(speechControl);
                    Check(tag + "the text model control is in the Report templates card, the Whisper one in Speech recognition, each bar under its own button",
                        textCard != speechCard && Descendants<CheckBox>(textCard).Any(c => (string)c.Content == "Use the local text model for report templates") && Descendants<ComboBox>(speechCard).Any(c => System.Windows.Automation.AutomationProperties.GetName(c) == "Speech language")
                        && Descendants<ProgressBar>(textControl).Count() == 1 && Descendants<ProgressBar>(speechControl).Count() == 1 && !Descendants<ProgressBar>(textCard).Except(Descendants<ProgressBar>(textControl)).Any());
                    Check(tag + "before any download the text card shows one Download button, the speech card one per model, and no Cancel", Descendants<Button>(textCard).Count(b => b.IsVisible && b.Content is string s && s.StartsWith("Download")) == 1
                        && Descendants<Button>(speechCard).Count(b => b.IsVisible && b.Content is string s && s.StartsWith("Download")) == SpeechModels.All.Count && !Descendants<Button>(settings).Any(b => b.IsVisible && b.Content as string == "Cancel")
                        && !Descendants<Button>(settings).Any(b => b.IsVisible && b.Content as string == "Cancel download"));
                    Check(tag + "the Settings line says no model is in use yet and the button carries the model's size", Descendants<TextBlock>(textCard).Any(t => t.IsVisible && t.Text == "Local AI is unavailable until its model is installed. Plain dictation still works.")
                        && Descendants<Button>(textCard).Any(b => b.IsVisible && b.Content as string == $"Download ({FileSize.Describe(LocalTextModel.Current.Size)})") && Descendants<Button>(speechCard).Any(b => b.IsVisible && b.Content as string == "Download (488 MB)"));
                    textControl.Show(DownloadState.Downloading, 120_000_000); speechControl.Show(DownloadState.Downloading, 61_000_000); settings.UpdateLayout(); Drain();
                    var bar = Descendants<ProgressBar>(textControl).Single(); var button = Descendants<Button>(textControl).Single(b => b.IsVisible);
                    var barAt = bar.TranslatePoint(new Point(0, 0), settings); var lineAt = textControl.Children.OfType<TextBlock>().Single(t => t.IsVisible).TranslatePoint(new Point(0, 0), settings);
                    var cardAt = textCard.TranslatePoint(new Point(0, 0), settings); var nextCard = speechCard.TranslatePoint(new Point(0, 0), settings);
                    Check(tag + "while downloading the bar and the line sit inside the Report templates card, above the next card", bar.IsVisible && barAt.Y > cardAt.Y && lineAt.Y > barAt.Y && lineAt.Y + 19 <= nextCard.Y && (string)button.Content == "Cancel");
                    if (shots != null) {
                        textControl.BringIntoView(); settings.UpdateLayout(); Drain();
                        var content = (FrameworkElement)settings.Content;
                        var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * 2), (int)Math.Ceiling(content.ActualHeight * 2), 192, 192, PixelFormats.Pbgra32); bitmap.Render(content);
                        var png = new System.Windows.Media.Imaging.PngBitmapEncoder(); png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                        Directory.CreateDirectory(shots); using var file = File.Create(Path.Combine(shots, $"downloading-{theme}-{width:F0}.png")); png.Save(file);
                    }
                } finally { settings.Close(); }
            } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        }

        // The real download, canceled part way: nothing is left behind and the model is not "installed".
        {
            string root = Path.Combine(Path.GetTempPath(), "pflow-cancel-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
            using var server = new HttpListener(); int port = Random.Shared.Next(20000, 60000); server.Prefixes.Add($"http://127.0.0.1:{port}/"); server.Start();
            var serving = Task.Run(async () => {
                var context = await server.GetContextAsync(); context.Response.ContentType = "application/octet-stream";
                try { var chunk = new byte[1024 * 1024]; for (int i = 0; i < 64; i++) { await context.Response.OutputStream.WriteAsync(chunk); await context.Response.OutputStream.FlushAsync(); await Task.Delay(100); } } catch (Exception) { }
                finally { try { context.Response.Close(); } catch (Exception) { } }
            });
            try {
                var model = new LocalTextModel(root) { Source = $"http://127.0.0.1:{port}/fictional.gguf" };
                using var cancel = new CancellationTokenSource(); bool canceled = false;
                try { model.Download(new Progress<double>(_ => cancel.Cancel()), cancel.Token).GetAwaiter().GetResult(); } catch (OperationCanceledException) { canceled = true; }
                Check("a canceled real download ends with OperationCanceled, leaves no partial file and installs nothing", canceled && Directory.GetFiles(root).Length == 0 && !model.CurrentInstalled && model.InUse == null);
            } finally { server.Stop(); try { serving.Wait(2000); } catch (Exception) { } if (Directory.Exists(root)) Directory.Delete(root, true); }
        }

        // The model in use, by the file on this PC (fictional bytes, the name only).
        {
            string root = Path.Combine(Path.GetTempPath(), "pflow-models-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
            try {
                var model = new LocalTextModel(root, root);
                Check("no model file: nothing in use and the Settings line says so", model.InUse == null && !model.CurrentInstalled && model.Status.StartsWith("Local AI is unavailable") && model.ModelPath.EndsWith(LocalTextModel.Current.FileName));
                File.WriteAllText(Path.Combine(root, LocalTextModel.Current.FileName), "fictional");
                Check("with the file: the model is in use, named with its size on the Settings line", model.InUse == LocalTextModel.Current && model.CurrentInstalled && model.Status == "Text model in use: Qwen3-4B (2.5 GB). Processing stays on this PC.");
                Check("the engine's threads follow the core rule for this PC", LocalTextModel.Threads >= 2 && LocalTextModel.Threads <= 8 && LocalTextModel.Threads == Native.EngineThreads(Native.CoreClasses()) && Native.CoreClasses().Count <= Environment.ProcessorCount);
            } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
        // The thread rule on fake topologies: the fastest class, slower classes added only while under four, 2-8.
        Check("a Core Ultra 5 125U (2 P + 8 E + 2 LP-E cores) gets 8 threads, not its 2 performance cores alone", Native.EngineThreads([2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0]) == 8);
        Check("6 P + 8 E cores get the 6 performance cores", Native.EngineThreads([1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0]) == 6);
        Check("2 P + 4 E cores get all 6, a plain 6-core PC gets 6, 16 plain cores get 8, one core gets 2", Native.EngineThreads([1, 1, 0, 0, 0, 0]) == 6 && Native.EngineThreads([0, 0, 0, 0, 0, 0]) == 6 && Native.EngineThreads(Enumerable.Repeat((byte)0, 16).ToList()) == 8 && Native.EngineThreads([0]) == 2);
        Check("no core list falls back to the logical count, 2-8", Native.EngineThreads([]) == Math.Clamp(Environment.ProcessorCount, 2, 8));

        // 32-bit Windows: no text model section, and closing Settings must not throw.
        {
            string root = Path.Combine(Path.GetTempPath(), "pflow-32bit-fictional-" + Guid.NewGuid().ToString("N"));
            try {
                var model = new LocalTextModel(root) { Supported = false };
                using var hook = new KeyboardHook(_ => { }) { Enabled = false };
                var settings = new SettingsWindow(new StateStore(root), new Whisper(root), model, hook, () => { }, () => false) { ShowActivated = false };
                settings.Show(); settings.UpdateLayout(); Drain();
                bool noControl = !Descendants<DownloadControl>(settings).Any(c => System.Windows.Automation.AutomationProperties.GetName(c) == "Text model download") && Descendants<DownloadControl>(settings).Count() == 1;
                bool reason = Descendants<TextBlock>(settings).Any(t => t.Text == LocalTextModel.UnsupportedReason);
                settings.Close(); Drain();
                Check("with the local model unsupported Settings shows the reason, only the Whisper download, and closes without an error", noControl && reason && !settings.IsVisible && !model.FilesPresent);
            } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        }

        // The model file is hashed once: at the download, then at app start (Prewarm), never again while it is unchanged. Stale partial downloads are swept.
        {
            string root = Path.Combine(Path.GetTempPath(), "pflow-hash-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
            var bytes = new byte[3 * 1024 * 1024]; new Random(7).NextBytes(bytes);
            string sha = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
            using var server = new HttpListener(); int port = Random.Shared.Next(20000, 60000); server.Prefixes.Add($"http://127.0.0.1:{port}/"); server.Start();
            var serving = Task.Run(async () => { var context = await server.GetContextAsync(); context.Response.ContentLength64 = bytes.Length; await context.Response.OutputStream.WriteAsync(bytes); context.Response.Close(); });
            try {
                var fictional = new TextModelFile("Fictional", "fictional-model.gguf", $"http://127.0.0.1:{port}/fictional-model.gguf", sha, bytes.Length);
                var model = new LocalTextModel(root, root) { Model = fictional, Source = fictional.Url };
                File.WriteAllText(Path.Combine(root, "fictional-model.gguf." + Guid.NewGuid() + ".download"), "stale"); File.WriteAllText(Path.Combine(root, "other.download"), "x"); File.WriteAllText(Path.Combine(root, "fictional-model.gguf.notaguid.download"), "x");
                Check("the sweep removes only our own stale partial download", model.SweepPartials() == 1 && Directory.GetFiles(root).Length == 2 && File.Exists(Path.Combine(root, "other.download")));
                var reported = new List<double>();
                model.Download(new Progress<double>(reported.Add), CancellationToken.None).GetAwaiter().GetResult(); Drain();
                Check("the download verified the file once and the model is in use", model.Hashes == 1 && model.CurrentInstalled && File.Exists(Path.Combine(root, "fictional-model.gguf")) && !Directory.GetFiles(root, "*.download").Any(f => f.Contains("fictional-model.gguf.") && !f.EndsWith("notaguid.download")));
                File.WriteAllText(Path.Combine(root, "llama-completion.exe"), "fictional engine"); Directory.CreateDirectory(Path.Combine(root, "text-engine")); File.Move(Path.Combine(root, "llama-completion.exe"), Path.Combine(root, "text-engine", "llama-completion.exe"));
                model.Prewarm().GetAwaiter().GetResult();
                Check("prewarm after the download does not hash the same bytes again", model.FilesPresent && model.Hashes == 1);
                Thread.Sleep(20); File.WriteAllBytes(Path.Combine(root, "fictional-model.gguf"), bytes);
                model.Prewarm().GetAwaiter().GetResult();
                Check("a rewritten file is hashed once more at prewarm, and then not again", model.Hashes == 2 && Run(() => model.Prewarm().GetAwaiter().GetResult()) && model.Hashes == 2);
            } finally { server.Stop(); try { serving.Wait(2000); } catch (Exception) { } if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }
    static bool Run(Action action) { action(); Drain(); return true; }
    /// The section card's body around a control: the StackPanel whose parent is the card's Border (a model row sits in between).
    static StackPanel CardAround(FrameworkElement control)
    {
        for (var node = control.Parent as FrameworkElement; node != null; node = node.Parent as FrameworkElement)
            if (node is StackPanel body && body.Parent is Border) return body;
        throw new Exception("no card around " + System.Windows.Automation.AutomationProperties.GetName(control));
    }
}
