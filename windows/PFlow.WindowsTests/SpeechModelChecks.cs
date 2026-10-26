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
            // The real pins never match these fictional bytes: by name alone nothing is deleted any more.
            var untouched = whisper.RemoveRetiredModels();
            // Their unfinished downloads are always pFlow's own and go at once; the files stay.
            Check($"files under the retired names that are not pFlow's downloads (other size) are left alone; their unfinished downloads go ({string.Join(", ", untouched)})",
                untouched.Count == 2 && untouched.All(entry => entry.Contains("unfinished download")) && File.Exists(Path.Combine(root, turbo)) && File.Exists(Path.Combine(root, medium)));
            // Fictional pins with the fixture files' own sizes and checksums stand in for the real downloads.
            SpeechModel Pin(string file) { byte[] bytes = File.ReadAllBytes(Path.Combine(root, file)); return new SpeechModel(file, file, Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)), bytes.Length); }
            var pins = new[] { Pin(turbo), Pin(medium) };
            var removed = whisper.RemoveRetiredModels(pins);
            Check($"at start the two retired speech models (size and checksum matching the pins) are deleted ({string.Join(", ", removed)})",
                removed.Count == 2 && removed.Contains(turbo) && removed.Contains(medium) && doomed.All(file => !File.Exists(Path.Combine(root, file))));
            Check("nothing else in pFlow's folder is touched: small's copy, the text model and its download, look-alike names, the app's files, a subfolder", Snapshot() == expected);
            string log; lock (lines) log = string.Join("\n", lines);
            Check("the log names the removed files and never a path", log.Contains("removed retired speech models: ") && log.Contains(turbo) && log.Contains(medium) && !log.Contains(root) && !log.Contains(":\\"));
            Check("the next start finds nothing to remove and changes nothing", whisper.RemoveRetiredModels(pins).Count == 0 && Snapshot() == expected);
            // Same size, other bytes: not pFlow's download either, so it stays.
            var lookalike = new byte[pins[0].Bytes]; File.WriteAllBytes(Path.Combine(root, turbo), lookalike);
            Check("a file of the right size whose checksum differs is kept and logged", whisper.RemoveRetiredModels(pins).Count == 0 && File.Exists(Path.Combine(root, turbo)));
            lock (lines) log = string.Join("\n", lines);
            Check("the log says why a retired name was kept, without a path", log.Contains("retired speech model name kept: " + turbo) && !log.Contains(root));
            File.Delete(Path.Combine(root, turbo));
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
                    Check(tag + "Troubleshooting has one button, \"Save a diagnostic report\", with its one-line explanation and no status until it is used",
                        texts.Contains("TROUBLESHOOTING") && texts.Contains(DiagnosticReport.Explanation)
                        && Descendants<Button>(settings).Count(b => b.Content as string == DiagnosticReport.ButtonLabel) == 1 && !texts.Any(t => t.StartsWith("Saved in ", StringComparison.Ordinal)));
                    Check(tag + "Settings says \"Speech model: Whisper small (included)\" and shows nothing to choose or download for speech",
                        texts.Contains(SpeechModels.SettingsLine) && !Descendants<RadioButton>(settings).Any(r => r.GroupName == "SpeechModel")
                        && !texts.Any(t => t.Contains("large-v3-turbo") || t.Contains("Whisper medium")) && Descendants<DownloadControl>(settings).Count() == 1);
                    if (shots != null) {
                        Directory.CreateDirectory(shots);
                        var page = Descendants<ScrollViewer>(settings).First(x => x.Content is StackPanel);
                        foreach (var (name, label) in new[] { ("speech", "SPEECH RECOGNITION"), ("templates", "REPORT TEMPLATES (OPTIONAL)"), ("troubleshooting", "TROUBLESHOOTING") }) {
                            var heading = Descendants<TextBlock>(settings).First(t => t.Text == label);
                            page.ScrollToVerticalOffset(page.VerticalOffset + heading.TranslatePoint(new Point(0, 0), page).Y - 12); settings.UpdateLayout(); Drain();
                            Shoot(settings, Path.Combine(shots, $"{name}-{theme}-{width:F0}.png"), theme == "light");
                        }
                    }
                } finally { settings.Close(); }
            }
        } finally { Directory.Delete(states, true); }

        // Worker threads follow the processors Windows lets pFlow use (W027: spinning threads on fewer processors stall Whisper).
        {
            var self = System.Diagnostics.Process.GetCurrentProcess(); var all = self.ProcessorAffinity;
            try {
                int full = SpeechWorker.LogicalProcessors;
                self.ProcessorAffinity = (IntPtr)0b11; int two = SpeechWorker.LogicalProcessors;
                Check($"thread counts are sized for the processors pFlow may use: {full} with all, {two} when held to two", full == Environment.ProcessorCount && two == 2
                    && SpeechThreads.Live(two) == 1 && SpeechThreads.Final(two) == 1);
            } finally { self.ProcessorAffinity = all; }
        }
        // An own copy of small with the wrong size (0.1.26 failed every take on it): the package's copy is used and Settings says so.
        string damaged = Path.Combine(Path.GetTempPath(), "pflow-speech-own-copy-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path.Combine(damaged, "models"));
        try {
            File.WriteAllBytes(Path.Combine(damaged, SpeechModels.Small.FileName), new byte[4096]);
            var whisper = new Whisper(damaged, damaged);
            Check("a wrong-size own copy of Whisper small is passed over for the package's copy",
                whisper.ModelPath == Path.Combine(damaged, "models", SpeechModels.Small.FileName) && whisper.OwnCopy == Whisper.OwnCopyState.WrongSize && whisper.OwnCopyNote != null);
            Check("with no own copy there is nothing to say", new Whisper(Path.Combine(damaged, "models"), damaged).OwnCopyNote == null);
            // A right-size copy that failed its checksum once is remembered for that file (size + last write), not hashed every start.
            string sized = Path.Combine(damaged, "models", "own"); Directory.CreateDirectory(sized);
            string copy = Path.Combine(sized, SpeechModels.Small.FileName);
            using (var stream = File.Create(copy)) stream.SetLength(SpeechModels.Small.Bytes);
            Check("a right-size own copy with no verdict is used", new Whisper(sized, damaged).OwnCopy == Whisper.OwnCopyState.Usable);
            new Whisper(sized, damaged).MarkOwnCopyDamaged();
            var later = new Whisper(sized, damaged);
            Check("a later start remembers the failed checksum for that file and uses the package's copy", later.OwnCopy == Whisper.OwnCopyState.Damaged && later.ModelPath == Path.Combine(damaged, "models", SpeechModels.Small.FileName) && later.OwnCopyNote != null);
            File.SetLastWriteTimeUtc(copy, DateTime.UtcNow.AddMinutes(1));
            Check("a changed own copy is checked again", new Whisper(sized, damaged).OwnCopy == Whisper.OwnCopyState.Usable);
            File.Delete(copy);
            string? shots = Environment.GetEnvironmentVariable("PFLOW_SHOTS");
            foreach (string theme in new[] { "light", "dark" }) {
                var store = new StateStore(damaged); store.Preferences.Theme = theme;
                using var hook = new KeyboardHook(_ => { }) { Enabled = false };
                var settings = new SettingsWindow(store, whisper, new LocalTextModel(damaged), hook, () => { }, () => false) { ShowActivated = false, Width = 420, Height = 740 };
                try {
                    settings.Show(); settings.UpdateLayout(); Drain();
                    Check(theme + ": Settings says the damaged own copy is passed over", Descendants<TextBlock>(settings).Any(t => t.Text == whisper.OwnCopyNote));
                    if (shots != null) {
                        var page = Descendants<ScrollViewer>(settings).First(x => x.Content is StackPanel);
                        var heading = Descendants<TextBlock>(settings).First(t => t.Text == "SPEECH RECOGNITION");
                        page.ScrollToVerticalOffset(page.VerticalOffset + heading.TranslatePoint(new Point(0, 0), page).Y - 12); settings.UpdateLayout(); Drain();
                        Shoot(settings, Path.Combine(shots, $"own-copy-{theme}-420.png"), theme == "light");
                    }
                } finally { settings.Close(); }
            }
        } finally { Directory.Delete(damaged, true); }
    }
}
