using System.IO;
using System.Diagnostics;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Interop;
using PFlow.Core;
using PFlow.Windows;

// Speed measurement with fixed fictional recordings: the real live path, the
// real resident worker and the real whole-recording pass, as Program runs a
// take. No microphone, no key events. Options:
//   --speed files=a.wav,b.wav modes=preview,off takes=2 label=name
// The first take in a process is cold (worker just started, as at app launch);
// later takes are warm. --speed-insert measures verified insertion into a
// test-owned Edit box in a separate process (needs the signed-in desktop).
internal static partial class Program
{
    static bool speedOnly, speedInsertOnly;
    static readonly Dictionary<string, string> speedOptions = [];

    static void SpeedArguments(string[] args)
    {
        speedOnly = args.Contains("--speed"); speedInsertOnly = args.Contains("--speed-insert");
        foreach (string arg in args) if (arg.IndexOf('=') is > 0 and var at) speedOptions[arg[..at]] = arg[(at + 1)..];
    }

    static string SpeedOption(string name, string fallback) => speedOptions.TryGetValue(name, out var value) ? value : fallback;

    /// Word-level edit distance over the reference length.
    static double WordErrorRate(string hypothesis, string reference)
    {
        var h = Words(hypothesis).Split(' ', StringSplitOptions.RemoveEmptyEntries); var r = Words(reference).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (r.Length == 0) return h.Length == 0 ? 0 : 1;
        var row = Enumerable.Range(0, h.Length + 1).ToArray();
        for (int i = 1; i <= r.Length; i++) {
            int previous = row[0]; row[0] = i;
            for (int j = 1; j <= h.Length; j++) { int current = row[j]; row[j] = Math.Min(Math.Min(row[j] + 1, row[j - 1] + 1), previous + (r[i - 1] == h[j - 1] ? 0 : 1)); previous = current; }
        }
        return (double)row[h.Length] / r.Length;
    }

    static string Reference(string audio) => File.ReadAllText(Path.ChangeExtension(Path.Combine(root, audio), ".txt")).Trim();

    static async Task Speed()
    {
        string directory = Path.Combine(root, "speed-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        var store = new StateStore(directory); store.Preferences.Language = "en";
        // model=<id> runs the finished text on that speech model: its file is taken from <root>\models.
        if (SpeedOption("model", "") is { Length: > 0 } modelId) {
            var chosen = SpeechModels.Resolve(modelId); if (chosen.Id != modelId) throw new Exception("unknown speech model " + modelId);
            if (!chosen.Bundled) File.Copy(Path.Combine(root, "models", chosen.FileName), Path.Combine(directory, chosen.FileName));
            store.Preferences.SpeechModel = chosen.Id;
        }
        await using var whisper = new Whisper(directory, PackageAssets) { ChosenId = () => store.Preferences.SpeechModel };
        var capsule = new Capsule(store); var preview = new LivePreview(store);
        string label = SpeedOption("label", "run") + (SpeedOption("model", "") is { Length: > 0 } m ? "-" + m : "");
        var rows = new List<Dictionary<string, object>>();
        try {
            // cpus=N stands in for a computer with N logical processors: the worker is sized for N (final and live thread
            // rules) and pinned to the first N, so it is slow the way a small machine is, not oversubscribed.
            if (SpeedOption("cpus", "") is { Length: > 0 } cpus) SpeechWorker.LogicalProcessors = int.Parse(cpus);
            var warm = Stopwatch.StartNew(); await whisper.Prewarm(); double prewarmMs = warm.Elapsed.TotalMilliseconds;
            if (SpeedOption("cpus", "") is { Length: > 0 } cores && whisper.WorkerId is int pid) {
                var process = Process.GetProcessById(pid); process.ProcessorAffinity = (IntPtr)((1L << int.Parse(cores)) - 1);
                Console.WriteLine($"SPEED-CPUS worker {pid} sized for {cores} processors, mask 0x{process.ProcessorAffinity.ToInt64():x}");
            }
            var timing = new Dictionary<string, double>();
            var pipeline = new DictationPipeline(store, whisper, new LocalTextModel(directory, PackageAssets)) { Timing = (name, ms) => timing[name] = ms };
            int take = 0;
            foreach (string audio in SpeedOption("files", "short-1.wav").Split(','))
            for (int repeat = 1; repeat <= int.Parse(SpeedOption("takes", "2")); repeat++)
            foreach (string mode in SpeedOption("modes", LiveTextModes.TypeInApp).Split(',')) {
                take++;
                var report = await FeedTake($"{label}-{audio}-{mode}-{take}", audio, mode, false, whisper, store, preview, capsule);
                timing.Clear();
                var final = Stopwatch.StartNew();
                var prepared = await pipeline.Prepare(Path.Combine(root, audio), report.AudioMs / 1000, directory, (_, _) => { }, CancellationToken.None);
                report.FinalMs = final.Elapsed.TotalMilliseconds; report.Final = prepared.Text; preview.Clear();
                var gaps = report.Updates.Where(u => u.Ms <= report.AudioEndMs).Zip(report.Updates.Skip(1).Where(u => u.Ms <= report.AudioEndMs), (a, b) => b.Ms - a.Ms).OrderBy(x => x).ToList();
                string reference = Reference(audio);
                rows.Add(new() {
                    ["label"] = label, ["model"] = whisper.InUse.Id, ["file"] = audio, ["mode"] = report.Mode, ["take"] = take, ["cold"] = take == 1, ["prewarmMs"] = Math.Round(prewarmMs),
                    ["audioMs"] = Math.Round(report.AudioMs), ["firstWordsMs"] = Math.Round(report.FirstUpdateMs), ["updatesBeforeEnd"] = report.UpdatesBeforeEnd,
                    ["medianGapMs"] = gaps.Count > 0 ? Math.Round(gaps[gaps.Count / 2]) : -1, ["windows"] = report.Windows,
                    ["liveStopMs"] = Math.Round(report.StopMs), ["recognitionMs"] = Math.Round(timing.GetValueOrDefault("recognitionMs", -1)),
                    ["shapeMs"] = Math.Round(report.FinalMs - timing.GetValueOrDefault("recognitionMs", 0)),
                    ["stopToFinalMs"] = Math.Round(report.StopMs + report.FinalMs),
                    ["cpuSeconds"] = Math.Round(report.CpuSeconds, 2), ["cpuCores"] = Math.Round(report.CpuSeconds * 1000 / report.AudioMs, 2),
                    ["peakAppMB"] = report.PeakAppBytes / 1048576, ["peakWorkerMB"] = report.PeakWorkerBytes / 1048576,
                    ["workerHeartbeats"] = whisper.WorkerHeartbeats, ["liveTooSlowMs"] = Math.Round(report.TooSlowAtMs),
                    ["final"] = report.Final, ["wordErrorRate"] = Math.Round(WordErrorRate(report.Final, reference), 4),
                    ["lastWordKept"] = Words(report.Final).Split(' ').LastOrDefault() == Words(reference).Split(' ').LastOrDefault(),
                });
                Console.WriteLine("SPEED " + JsonSerializer.Serialize(rows[^1]));
                Check(audio + " finished text is not empty", !string.IsNullOrWhiteSpace(report.Final));
            }
            // How the typing note looks with an app's own long name, light and dark.
            if (SpeedOption("render", "") == "note") {
                string note = LiveInlineText.TypingNote("Fictional Harbor Notes and Lantern Logbook Studio Edition 2026", null, "fhnotes");
                foreach (string theme in new[] { "light", "dark" }) {
                    store.Preferences.Theme = theme; preview.ApplyTheme(); preview.Begin(); preview.SetNote(note); preview.ShowText("The ferry to Pebble Island leaves at seven forty.");
                    Render(preview, "typing-note-" + theme + "-100", 1, 1); Render(preview, "typing-note-" + theme + "-200", 2, 1);
                    // The two notes added after the owner's live test: a field pFlow cannot type into live, and a computer too slow for live words.
                    preview.SetNote(LiveInlineText.PreviewNote(LiveStop.Unsupported)); Render(preview, "web-note-" + theme + "-100", 1, 1); Render(preview, "web-note-" + theme + "-200", 2, 1);
                    preview.SetNote(LiveTake.TooSlowNote); Render(preview, "slow-note-" + theme + "-100", 1, 1); Render(preview, "slow-note-" + theme + "-200", 2, 1);
                }
                preview.Clear();
            }
        } finally {
            File.WriteAllText(Path.Combine(root, $"speed-{label}-{DateTime.UtcNow:yyyyMMddHHmmss}.json"), JsonSerializer.Serialize(rows, new JsonSerializerOptions { WriteIndented = true }));
            preview.Close(); capsule.Close(); Directory.Delete(directory, true);
        }
    }

    /// Off-mode delivery into a test-owned Edit box in another process:
    /// whole-recording pass, text shaping, verified insertion and History.
    static async Task SpeedInsert()
    {
        string directory = Path.Combine(root, "speed-insert-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        hostDirectory = Path.Combine(directory, "pflow-fictional-speed-" + Guid.NewGuid().ToString("N")[..8]);
        var store = new StateStore(directory); store.Preferences.Language = "en"; store.Preferences.CopyDictationToClipboard = false;
        await using var whisper = new Whisper(directory, PackageAssets);
        using var owner = new HwndSource(new HwndSourceParameters("pFlow fictional speed owner") { Width = 10, Height = 10 });
        var rows = new List<Dictionary<string, object>>();
        uint clipboard = Native.GetClipboardSequenceNumber();
        try {
            await StartHost(hostDirectory);
            var host = await WindowWith(Path.GetFileName(hostDirectory) + " host"); var field = Named(host, "Fictional plain");
            await whisper.Prewarm();
            int take = 0;
            foreach (string audio in SpeedOption("files", "short-1.wav").Split(','))
            for (int repeat = 1; repeat <= int.Parse(SpeedOption("takes", "2")); repeat++) {
                take++;
                await Place(host, field); PersonSelects(field, 1_000_000, 1_000_000);
                var before = await AskHost(hostDirectory);
                var target = InsertionTarget.Capture(); var timing = new Dictionary<string, double>();
                var pipeline = new DictationPipeline(store, whisper, new LocalTextModel(directory, PackageAssets)) { Timing = (name, ms) => timing[name] = ms };
                var watch = Stopwatch.StartNew();
                var result = await pipeline.Run(Path.Combine(root, audio), 20, target, directory, owner.Handle, (_, _) => { }, CancellationToken.None);
                double total = watch.Elapsed.TotalMilliseconds;
                var after = await AskHost(hostDirectory);
                bool inserted = result.Status == "Inserted" && after.plain.Length > before.plain.Length && Words(after.plain).EndsWith(Words(Reference(audio)).Split(' ').Last());
                rows.Add(new() { ["file"] = audio, ["take"] = take, ["cold"] = take == 1, ["status"] = result.Status, ["verified"] = inserted,
                    ["recognitionMs"] = Math.Round(timing.GetValueOrDefault("recognitionMs", -1)), ["insertionMs"] = Math.Round(timing.GetValueOrDefault("insertionMs", -1)),
                    ["historySaveMs"] = Math.Round(timing.GetValueOrDefault("historySaveMs", -1)), ["totalMs"] = Math.Round(total) });
                Console.WriteLine("SPEED " + JsonSerializer.Serialize(rows[^1]));
                Check(audio + " inserted and read back in the test box", inserted);
            }
            Check("speed insertion left the clipboard alone", Native.GetClipboardSequenceNumber() == clipboard);
        } finally {
            File.WriteAllText(Path.Combine(root, $"speed-insert-{DateTime.UtcNow:yyyyMMddHHmmss}.json"), JsonSerializer.Serialize(rows, new JsonSerializerOptions { WriteIndented = true }));
            QuitHost(hostDirectory); await Task.Delay(300); Directory.Delete(directory, true);
        }
    }
}
