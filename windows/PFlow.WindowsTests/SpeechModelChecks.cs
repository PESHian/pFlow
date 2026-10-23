using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

internal static partial class Program
{
    /// Whisper small is the one speech model (0.1.26). At start pFlow deletes the two downloads 0.1.25
    /// offered (large-v3-turbo q8_0, medium q5_0) and their unfinished downloads from its own folder:
    /// only those exact names, nothing else in the folder, the log naming files and never a path.
    /// Settings names the model and offers nothing to choose or download for speech.
    /// PFLOW_SHOTS writes speech-{theme}-{width}.png and templates-{theme}-{width}.png to look at.
    static void NativeSpeechModels()
    {
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        string root = Path.Combine(Path.GetTempPath(), "pflow-speech-models-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var lines = new List<string>(); void Logged(string line) { lock (lines) lines.Add(line); }
        InsertionLog.Written += Logged;
        try {
            // Fictional bytes under the real names, plus everything that must survive: small's own copy, the
            // text model and its unfinished download, look-alike names, the app's files, and a retired name
            // one folder down.
            static string Partial(string file) => file + "." + Guid.NewGuid() + ".download";
            string turbo = SpeechModels.RetiredFiles[0], medium = SpeechModels.RetiredFiles[1];
            var doomed = new[] { turbo, medium, Partial(turbo), Partial(medium) };
            var kept = new[] { SpeechModels.Small.FileName, Partial(SpeechModels.Small.FileName) + ".keep", "Qwen3-4B-Q4_K_M.gguf", Partial("Qwen3-4B-Q4_K_M.gguf"), medium + ".keep",
                "copy of " + turbo, turbo + ".download", "settings.json", "history.json", "insertion.log", Path.Combine("models", medium) };
            Directory.CreateDirectory(Path.Combine(root, "models"));
            int seed = 0; foreach (string file in doomed.Concat(kept)) { var bytes = new byte[4096 + seed]; new Random(seed++).NextBytes(bytes); File.WriteAllBytes(Path.Combine(root, file), bytes); }
            string Snapshot() => string.Join("|", Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal)
                .Select(path => Path.GetRelativePath(root, path) + ":" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(path)))));
            string expected = string.Join("|", Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).Where(path => !doomed.Contains(Path.GetRelativePath(root, path))).Order(StringComparer.Ordinal)
                .Select(path => Path.GetRelativePath(root, path) + ":" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(path)))));
            var whisper = new Whisper(root, root);
            var removed = whisper.RemoveRetiredModels();
            Check($"at start the two retired speech models and their unfinished downloads are deleted ({string.Join(", ", removed)})",
                removed.Count == 4 && removed.Contains(turbo) && removed.Contains(medium) && doomed.All(file => !File.Exists(Path.Combine(root, file))));
            Check("nothing else in pFlow's folder is touched: small's copy, the text model and its download, look-alike names, the app's files, a subfolder", Snapshot() == expected);
            string log; lock (lines) log = string.Join("\n", lines);
            Check("the log names the removed files and never a path", log.Contains("removed retired speech models: ") && log.Contains(turbo) && log.Contains(medium) && !log.Contains(root) && !log.Contains(":\\"));
            Check("the next start finds nothing to remove and changes nothing", whisper.RemoveRetiredModels().Count == 0 && Snapshot() == expected);
        } finally { InsertionLog.Written -= Logged; Directory.Delete(root, true); }

        // Settings: the speech card names the one model; no tiles, no rows, no speech download, in both themes at both widths.
        string states = Path.Combine(Path.GetTempPath(), "pflow-speech-settings-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(states);
        try {
            string? shots = Environment.GetEnvironmentVariable("PFLOW_SHOTS");
            foreach (string theme in new[] { "light", "dark" })
            foreach (double width in new[] { 420.0, 900.0 }) {
                var store = new StateStore(states); store.Preferences.Theme = theme;
                using var hook = new KeyboardHook(_ => { }) { Enabled = false };
                var settings = new SettingsWindow(store, new Whisper(states, states), new LocalTextModel(states), hook, () => { }, () => false) { ShowActivated = false, Width = width, Height = 740 };
                try {
                    settings.Show(); settings.UpdateLayout(); Drain();
                    string tag = $"{theme} {width:F0}: ";
                    var texts = Descendants<TextBlock>(settings).Select(t => t.Text).ToList();
                    Check(tag + "Settings says \"Speech model: Whisper small (included)\" and shows nothing to choose or download for speech",
                        texts.Contains(SpeechModels.SettingsLine) && !Descendants<RadioButton>(settings).Any(r => r.GroupName == "SpeechModel")
                        && !texts.Any(t => t.Contains("large-v3-turbo") || t.Contains("Whisper medium")) && Descendants<DownloadControl>(settings).Count() == 1);
                    if (shots != null) {
                        Directory.CreateDirectory(shots);
                        var page = Descendants<ScrollViewer>(settings).First(x => x.Content is StackPanel);
                        foreach (var (name, label) in new[] { ("speech", "SPEECH RECOGNITION"), ("templates", "REPORT TEMPLATES (OPTIONAL)") }) {
                            var heading = Descendants<TextBlock>(settings).First(t => t.Text == label);
                            page.ScrollToVerticalOffset(page.VerticalOffset + heading.TranslatePoint(new Point(0, 0), page).Y - 12); settings.UpdateLayout(); Drain();
                            Shoot(settings, Path.Combine(shots, $"{name}-{theme}-{width:F0}.png"), theme == "light");
                        }
                    }
                } finally { settings.Close(); }
            }
        } finally { Directory.Delete(states, true); }
    }
}
