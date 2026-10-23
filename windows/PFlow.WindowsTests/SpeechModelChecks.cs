using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

internal static partial class Program
{
    /// The speech model picker: the chosen model runs only when its file is here with its exact
    /// size (else small, so a removed download never stops dictation); in Settings every model is a
    /// visible tile, a tile is enabled once its file is here, each model has its own row with its own
    /// download control, and choosing a tile is saved. Fictional files of the right length stand in.
    static void NativeSpeechModels()
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        string root = Path.Combine(Path.GetTempPath(), "pflow-speech-models-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        try {
            string? chosen = null;
            var whisper = new Whisper(root, root) { ChosenId = () => chosen };
            var turbo = SpeechModels.Turbo;
            Check("nothing saved: small is chosen and in use", whisper.Chosen == SpeechModels.Small && whisper.InUse == SpeechModels.Small && whisper.ModelPath.EndsWith(SpeechModels.Small.FileName));
            chosen = "no-such-model";
            Check("an unknown saved choice falls back to small", whisper.Chosen == SpeechModels.Small);
            chosen = turbo.Id;
            Check("a chosen model whose file is missing: small stays in use", whisper.Chosen == turbo && !whisper.Installed(turbo) && whisper.InUse == SpeechModels.Small);
            using (var wrong = new FileStream(Path.Combine(root, turbo.FileName), FileMode.CreateNew)) wrong.SetLength(turbo.Bytes - 1);
            Check("a file of the wrong size does not count as installed", !whisper.Installed(turbo) && whisper.InUse == SpeechModels.Small);
            using (var right = new FileStream(Path.Combine(root, turbo.FileName), FileMode.Create)) right.SetLength(turbo.Bytes);
            Check("with its file here the chosen model is in use and its path is the download", whisper.Installed(turbo) && whisper.InUse == turbo && whisper.ModelPath == Path.Combine(root, turbo.FileName)
                && whisper.ModelStatus == $"In use: {turbo.Title} ({FileSize.Describe(turbo.Bytes)}). Recognition stays on this PC." && FileSize.Describe(turbo.Bytes) == "874 MB");
            File.WriteAllText(Path.Combine(root, turbo.FileName + "." + Guid.NewGuid() + ".download"), "partial");
            Check("a partial download of any speech model is swept", whisper.SweepPartials() == 1 && Directory.GetFiles(root, "*.download").Length == 0);

            // Settings: tiles, rows and the saved choice, in both themes; PFLOW_SHOTS writes speech-models-{theme}.png of the card.
            foreach (string theme in new[] { "dark", "light" }) {
            var store = new StateStore(root); store.Preferences.Theme = theme; store.Preferences.SpeechModel = SpeechModels.Small.Id; store.SavePreferences();
            using var hook = new KeyboardHook(_ => { }) { Enabled = false };
            var picked = new Whisper(root, root) { ChosenId = () => store.Preferences.SpeechModel };
            var settings = new SettingsWindow(store, picked, new LocalTextModel(root), hook, () => { }, () => false) { ShowActivated = false, Width = 460, Height = 740 };
            try {
                settings.Show(); settings.UpdateLayout(); Drain();
                if (Environment.GetEnvironmentVariable("PFLOW_SHOTS") is { } shots) {
                    // The card from its "Speech model" label down: tiles, the line under them and the model rows.
                    var page = Descendants<ScrollViewer>(settings).First(x => x.Content is StackPanel); var label = Descendants<TextBlock>(settings).First(t => t.Text == "Speech model");
                    page.ScrollToVerticalOffset(page.VerticalOffset + label.TranslatePoint(new Point(0, 0), page).Y - 12); settings.UpdateLayout(); Drain();
                    Shoot(settings, Path.Combine(shots, $"speech-models-{theme}.png"), theme == "light");
                }
                var tiles = Descendants<RadioButton>(settings).Where(r => r.GroupName == "SpeechModel").ToList();
                Check("every speech model is a visible tile, in the catalogue's order", tiles.Select(t => (string)t.Tag).SequenceEqual(SpeechModels.All.Select(m => m.Id)) && tiles.All(t => t.IsVisible));
                RadioButton Tile(SpeechModel m) => tiles.Single(t => (string)t.Tag == m.Id); TextBlock Label(RadioButton t) => (TextBlock)t.Content;
                var muted = (Brush)settings.FindResource("PeshMuted"); var bright = (Brush)settings.FindResource("PeshText"); var accent = (Brush)settings.FindResource("PeshAccent");
                var medium = SpeechModels.All.Single(m => m.Id == "medium-q5_0");
                // In this fixture the bundled file is absent too, so small is "chosen" by the saved choice but drawn as not downloaded.
                Check("every tile stays enabled; the downloaded one has plain bright text, the not-downloaded ones dimmed text and no outline",
                    tiles.All(t => t.IsEnabled) && Label(Tile(turbo)).Foreground == bright && Label(Tile(turbo)).FontWeight == FontWeights.Normal && Tile(turbo).IsChecked == false
                    && Label(Tile(medium)).Foreground == muted && Label(Tile(medium)).Opacity < 1 && Tile(medium).IsChecked == false);
                var rows = Descendants<StackPanel>(settings).Where(p => System.Windows.Automation.AutomationProperties.GetName(p)?.EndsWith(" row") == true).ToList();
                StackPanel Row(SpeechModel m) => rows.Single(r => System.Windows.Automation.AutomationProperties.GetName(r) == m.Title + " row");
                Check("each download has its own row with its size, its note and one download control; the bundled model's row only says Included, with no control",
                    rows.Count == SpeechModels.All.Count && SpeechModels.All.Where(m => !m.Bundled).All(m =>
                        Descendants<TextBlock>(Row(m)).Any(t => t.Text == m.Title + " · " + FileSize.Describe(m.Bytes)) && Descendants<TextBlock>(Row(m)).Any(t => t.Text == m.Note) && Descendants<DownloadControl>(Row(m)).Count() == 1)
                    && Descendants<TextBlock>(Row(SpeechModels.Small)).Any(t => t.Text == "Included · 488 MB") && !Descendants<DownloadControl>(Row(SpeechModels.Small)).Any()
                    && !Descendants<Button>(Row(SpeechModels.Small)).Any());
                Check("the model whose file is here says Downloaded; the other download offers Download with its size", Descendants<DownloadControl>(Row(turbo)).Single().State == DownloadState.Installed
                    && Descendants<DownloadControl>(Row(medium)).Single().State == DownloadState.Ready);
                // Tapping a not-downloaded tile does not choose it: its row comes into view and its title lights up in the accent.
                var sheet = Descendants<ScrollViewer>(settings).First(x => x.Content is StackPanel); sheet.ScrollToTop(); settings.UpdateLayout(); Drain();
                Tile(medium).IsChecked = true; settings.UpdateLayout(); Drain();
                var rowAt = Row(medium).TranslatePoint(new Point(0, 0), sheet);
                Check("tapping a not-downloaded tile keeps the saved choice, scrolls its Download row into view and highlights its title", new StateStore(root).Preferences.SpeechModel == SpeechModels.Small.Id
                    && Tile(medium).IsChecked == false && rowAt.Y >= 0 && rowAt.Y + Row(medium).ActualHeight <= sheet.ViewportHeight + 1 && Descendants<TextBlock>(Row(medium)).First().Foreground == accent);
                Tile(turbo).IsChecked = true; Drain();
                Check("choosing a downloaded tile saves the choice, outlines it with bright text and the line under the tiles names the model in use", new StateStore(root).Preferences.SpeechModel == turbo.Id && picked.InUse == turbo
                    && Tile(turbo).IsChecked == true && Label(Tile(turbo)).FontWeight == FontWeights.SemiBold && Label(Tile(turbo)).Foreground == bright
                    && Descendants<TextBlock>(settings).Any(t => t.Text == picked.ModelStatus && t.Text.Contains(turbo.Title)));
            } finally { settings.Close(); }
            }
        } finally { Directory.Delete(root, true); }
    }
}
