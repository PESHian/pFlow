using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

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
                && whisper.ModelStatus == $"In use: {turbo.Title} (574 MB). Recognition stays on this PC.");
            File.WriteAllText(Path.Combine(root, turbo.FileName + "." + Guid.NewGuid() + ".download"), "partial");
            Check("a partial download of any speech model is swept", whisper.SweepPartials() == 1 && Directory.GetFiles(root, "*.download").Length == 0);

            // Settings: tiles, rows and the saved choice.
            var store = new StateStore(root);
            using var hook = new KeyboardHook(_ => { }) { Enabled = false };
            var picked = new Whisper(root, root) { ChosenId = () => store.Preferences.SpeechModel };
            var settings = new SettingsWindow(store, picked, new LocalTextModel(root), hook, () => { }, () => false) { ShowActivated = false, Width = 460, Height = 740 };
            try {
                settings.Show(); settings.UpdateLayout(); Drain();
                var tiles = Descendants<RadioButton>(settings).Where(r => r.GroupName == "SpeechModel").ToList();
                Check("every speech model is a visible tile, in the catalogue's order", tiles.Select(t => (string)t.Tag).SequenceEqual(SpeechModels.All.Select(m => m.Id)) && tiles.All(t => t.IsVisible));
                Check("small is the chosen tile; only the model with its file here can be chosen", tiles.Single(t => (string)t.Tag == SpeechModels.Small.Id).IsChecked == true
                    && tiles.Single(t => (string)t.Tag == turbo.Id).IsEnabled && tiles.Where(t => (string)t.Tag != turbo.Id && (string)t.Tag != SpeechModels.Small.Id).All(t => !t.IsEnabled));
                var rows = Descendants<StackPanel>(settings).Where(p => System.Windows.Automation.AutomationProperties.GetName(p)?.EndsWith(" row") == true).ToList();
                Check("each model has its own row with its size, its note and one download control", rows.Count == SpeechModels.All.Count && SpeechModels.All.All(m => rows.Any(r =>
                    Descendants<TextBlock>(r).Any(t => t.Text == m.Title + " · " + FileSize.Describe(m.Bytes)) && Descendants<TextBlock>(r).Any(t => t.Text == m.Note) && Descendants<DownloadControl>(r).Count() == 1)));
                var turboRow = rows.Single(r => System.Windows.Automation.AutomationProperties.GetName(r) == turbo.Title + " row");
                Check("the model whose file is here says Downloaded; the others offer Download with their size", Descendants<DownloadControl>(turboRow).Single().State == DownloadState.Installed
                    && rows.Except([turboRow]).All(r => Descendants<DownloadControl>(r).Single().State == DownloadState.Ready));
                tiles.Single(t => (string)t.Tag == turbo.Id).IsChecked = true; Drain();
                Check("choosing a tile saves the choice and the line under the tiles names the model in use", new StateStore(root).Preferences.SpeechModel == turbo.Id && picked.InUse == turbo
                    && Descendants<TextBlock>(settings).Any(t => t.Text == picked.ModelStatus && t.Text.Contains(turbo.Title)));
            } finally { settings.Close(); }
        } finally { Directory.Delete(root, true); }
    }
}
