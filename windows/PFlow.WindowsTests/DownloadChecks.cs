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
            Check("during: the bar, 'Downloading… 120 MB of 1.1 GB' and one Cancel; the Download button is gone", Buttons().SequenceEqual(["Cancel"]) && Bar() && Line() == "Downloading… 120 MB of 1.1 GB" && control.State == DownloadState.Downloading);
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
                    var textCard = (StackPanel)textControl.Parent; var speechCard = (StackPanel)speechControl.Parent;
                    Check(tag + "the text model control is in the Local intelligence card, the Whisper one in Speech recognition, each bar under its own button",
                        textCard != speechCard && Descendants<CheckBox>(textCard).Any(c => (string)c.Content == "AI cleanup (slower, English)") && Descendants<ComboBox>(speechCard).Any(c => System.Windows.Automation.AutomationProperties.GetName(c) == "Speech language")
                        && Descendants<ProgressBar>(textControl).Count() == 1 && Descendants<ProgressBar>(speechControl).Count() == 1 && !Descendants<ProgressBar>(textCard).Except(Descendants<ProgressBar>(textControl)).Any());
                    Check(tag + "before any download each card shows one Download button and no Cancel", Descendants<Button>(textCard).Count(b => b.IsVisible && b.Content is string s && s.StartsWith("Download")) == 1
                        && Descendants<Button>(speechCard).Count(b => b.IsVisible && b.Content is string s && s.StartsWith("Download")) == 1 && !Descendants<Button>(settings).Any(b => b.IsVisible && b.Content as string == "Cancel")
                        && !Descendants<Button>(settings).Any(b => b.IsVisible && b.Content as string == "Cancel download"));
                    Check(tag + "the Settings line names the model in use", Descendants<TextBlock>(textCard).Any(t => t.IsVisible && t.Text == "Local AI is unavailable until its model is installed. Plain dictation still works.") && !Descendants<Button>(textCard).Any(b => b.IsVisible && b.Content is string s && s.StartsWith("Remove old model")));
                    textControl.Show(DownloadState.Downloading, 120_000_000); speechControl.Show(DownloadState.Downloading, 61_000_000); settings.UpdateLayout(); Drain();
                    var bar = Descendants<ProgressBar>(textControl).Single(); var button = Descendants<Button>(textControl).Single(b => b.IsVisible);
                    var barAt = bar.TranslatePoint(new Point(0, 0), settings); var lineAt = textControl.Children.OfType<TextBlock>().Single(t => t.IsVisible).TranslatePoint(new Point(0, 0), settings);
                    var cardAt = textCard.TranslatePoint(new Point(0, 0), settings); var nextCard = speechCard.TranslatePoint(new Point(0, 0), settings);
                    Check(tag + "while downloading the bar and the line sit inside the Local intelligence card, above the next card", bar.IsVisible && barAt.Y > cardAt.Y && lineAt.Y > barAt.Y && lineAt.Y + 19 <= nextCard.Y && (string)button.Content == "Cancel");
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

        // Which model runs, by the files on this PC (fictional bytes, names only).
        {
            string root = Path.Combine(Path.GetTempPath(), "pflow-models-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
            try {
                var model = new LocalTextModel(root, root);
                Check("no model file: nothing in use, the Settings line says so, the budget is the new model's", model.InUse == null && !model.CurrentInstalled && !model.PreviousOnDisk && model.Status.StartsWith("Local AI is unavailable") && model.Budget(60) == TimeSpan.FromSeconds(19));
                File.WriteAllText(Path.Combine(root, LocalTextModel.Previous.FileName), "fictional");
                Check("only the old 4B file: it stays in use with its own slower cut-off and the line says until the smaller one is downloaded",
                    model.InUse == LocalTextModel.Previous && !model.CurrentInstalled && model.PreviousOnDisk && model.Status == "Text model in use: the older Qwen3-4B (2.5 GB), until the smaller Qwen3-1.7B is downloaded." && model.Budget(60) == TimeSpan.FromSeconds(33) && model.ModelPath.EndsWith(LocalTextModel.Previous.FileName));
                File.WriteAllText(Path.Combine(root, LocalTextModel.Current.FileName), "fictional");
                Check("both files: the new one is in use and the old one is still on disk, never removed on its own",
                    model.InUse == LocalTextModel.Current && model.CurrentInstalled && model.PreviousOnDisk && model.Status == "Text model in use: Qwen3-1.7B (1.1 GB). Processing stays on this PC." && model.ModelPath.EndsWith(LocalTextModel.Current.FileName)
                    && model.Budget(13) == TimeSpan.FromSeconds(18) && model.Budget(60) == TimeSpan.FromSeconds(19) && model.Budget(286) == TimeSpan.FromSeconds(52.9) && model.Budget(1000) == TimeSpan.FromSeconds(90));
                model.RemovePrevious();
                Check("Remove old model deletes only the old file", !model.PreviousOnDisk && model.CurrentInstalled && File.Exists(Path.Combine(root, LocalTextModel.Current.FileName)));
                var settings = new SettingsWindow(new StateStore(root), new Whisper(root), model, new KeyboardHook(_ => { }) { Enabled = false }, () => { }, () => false) { ShowActivated = false };
                try {
                    File.WriteAllText(Path.Combine(root, LocalTextModel.Previous.FileName), "fictional"); File.Delete(Path.Combine(root, LocalTextModel.Current.FileName));
                    var fresh = new SettingsWindow(new StateStore(root), new Whisper(root), model, new KeyboardHook(_ => { }) { Enabled = false }, () => { }, () => false) { ShowActivated = false };
                    try {
                        fresh.Show(); fresh.UpdateLayout(); Drain();
                        var remove = Descendants<Button>(fresh).Single(b => b.IsVisible && b.Content as string == "Remove old model (2.5 GB)");
                        Check("with the old file on disk Settings offers its removal beside the Download button and says the old one is in use",
                            Descendants<TextBlock>(fresh).Any(t => t.IsVisible && t.Text.StartsWith("Text model in use: the older Qwen3-4B")) && Descendants<Button>(fresh).Any(b => b.IsVisible && b.Content as string == "Download (1.1 GB)"));
                        remove.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); Drain();
                        Check("pressing Remove old model deletes it and the offer goes away", !model.PreviousOnDisk && !Descendants<Button>(fresh).Any(b => b.IsVisible && b.Content is string s && s.StartsWith("Remove old model")) && Descendants<TextBlock>(fresh).Any(t => t.IsVisible && t.Text.StartsWith("Local AI is unavailable")));
                    } finally { fresh.Close(); }
                } finally { settings.Close(); }
            } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
        }
    }
    static bool Run(Action action) { action(); Drain(); return true; }
}
