using PFlow.Core;
using PFlow.Windows;
using System.Diagnostics;
using System.IO;
using System.Text.Json;

internal static partial class Program
{
    /// --cleanup-model [files=a.wav,b.wav]: the real pipeline with the real 2.5 GB text model
    /// (hard-linked into the harness package assets, never in the repo) on fictional takes:
    /// the raw recognition, the model's own text, the outcome, the time, the final text; then
    /// the same take under a 1 ms budget so the person is told plainly and the processing line
    /// says so. Evidence for the owner's "AI cleanup made it worse" report (W023).
    static async Task CleanupModel()
    {
        string directory = Path.Combine(root, "cleanup-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        string assets = PackageAssets;
        var store = new StateStore(directory); store.Preferences.Language = "en"; store.Preferences.Cleanup = true; store.Preferences.UseLocalAI = true; store.Preferences.UseAICleanup = true; store.Preferences.Paragraphs = false;
        await using var whisper = new Whisper(directory, assets); var model = new LocalTextModel(directory, assets);
        Check("the text model and engine are present for this check", model.FilesPresent);
        try {
            foreach (string audio in SpeedOption("files", "medium-1.wav,latency-numbers.wav").Split(',')) {
                var timing = new Dictionary<string, double>(); var stages = new List<string?>();
                var pipeline = new DictationPipeline(store, whisper, model) { Timing = (name, ms) => timing[name] = ms };
                string raw = await whisper.Transcribe(Path.Combine(root, audio), "en", [], CancellationToken.None);
                var clock = Stopwatch.StartNew();
                var prepared = await pipeline.Shape(raw, directory, (_, detail) => stages.Add(detail), CancellationToken.None);
                Console.WriteLine($"CLEANUP {audio}: words={TextProcessing.WordCount(raw)} cleanupMs={timing.GetValueOrDefault("cleanupMs"):F0} budgetMs={DictationPipeline.BudgetFor(TextProcessing.WordCount(raw)).TotalMilliseconds:F0} outcome={(CleanupOutcome)(int)timing.GetValueOrDefault("cleanupOutcome")} issue={prepared.CleanupIssue ?? "none"} elapsed={clock.ElapsedMilliseconds}");
                Console.WriteLine($"CLEANUP {audio} raw: {raw}");
                Console.WriteLine($"CLEANUP {audio} model: {model.LastModelText}");
                Console.WriteLine($"CLEANUP {audio} final: {prepared.Text}");
                Check(audio + ": the model ran and its edit was used", stages.Contains("Cleaning up") && model.LastOutcome == CleanupOutcome.Applied && !prepared.CleanupIncomplete && prepared.CleanupIssue == null);
                Check(audio + ": cleanup time is recorded as its own number within the budget", timing.TryGetValue("cleanupMs", out double ms) && ms > 0 && ms < DictationPipeline.BudgetFor(TextProcessing.WordCount(raw)).TotalMilliseconds && timing["cleanupOutcome"] == (double)CleanupOutcome.Applied);
                Check(audio + ": every word and number is as recognized", TextFidelity.CleanupIsFaithful(raw, prepared.Text));
                Check(audio + ": the final text has sentences and starts with a capital", prepared.Text.Count(c => c == '.') >= 2 && char.IsUpper(prepared.Text[0]) && prepared.Text.TrimEnd().EndsWith('.'));
                Check(audio + ": no double spaces in the recognition or the final text", !raw.Contains("  ") && !prepared.Text.Contains("  "));
                store.Write("last-processing-times.json", new Dictionary<string, double>(timing) { ["totalAfterReleaseMs"] = clock.ElapsedMilliseconds });
                string line = ProcessingTimes.Read(directory); Console.WriteLine("CLEANUP processing line: " + line.Replace('\n', ' '));
                Check(audio + ": the processing line shows the cleanup time and that it was used", line.Contains("AI cleanup: ") && line.Contains(" s (used)"));
                // The same take with no time: the words are kept and the person is told in plain words.
                var cut = new DictationPipeline(store, whisper, model) { Timing = (name, ms) => timing[name] = ms, CleanupBudget = TimeSpan.FromMilliseconds(1) };
                var kept = await cut.Shape(raw, directory, (_, _) => { }, CancellationToken.None);
                Check(audio + ": a cut-off cleanup keeps the words and says so plainly", kept.Text == raw && kept.CleanupIncomplete && kept.CleanupTimedOut && kept.CleanupIssue == LocalTextModel.TimedOutIssue && timing["cleanupOutcome"] == (double)CleanupOutcome.TimedOut);
                store.Write("last-processing-times.json", new Dictionary<string, double>(timing) { ["totalAfterReleaseMs"] = 1 });
                Check(audio + ": the processing line says the cleanup took too long", ProcessingTimes.Read(directory).Contains("(took too long, not used)"));
            }
            // Recognition without punctuation (the owner's case, fictional words): the pipeline's own cleanup
            // sentences, commas and capitalizes it, keeps the number and the words, and says nothing.
            const string flat = "once upon a time in a land far far away where the birds would fly there was this brown little fox that used to love to eat food and then it was a bad day the wolf came so next year in 4040 bc jimmy dean was born in a sea of pee";
            var flatTiming = new Dictionary<string, double>();
            var flatPipeline = new DictationPipeline(store, whisper, model) { Timing = (name, ms) => flatTiming[name] = ms };
            var shaped = await flatPipeline.Shape(flat, directory, (_, _) => { }, CancellationToken.None);
            Console.WriteLine($"CLEANUP flat: words={TextProcessing.WordCount(flat)} cleanupMs={flatTiming.GetValueOrDefault("cleanupMs"):F0} outcome={(CleanupOutcome)(int)flatTiming.GetValueOrDefault("cleanupOutcome")} issue={shaped.CleanupIssue ?? "none"}");
            Console.WriteLine($"CLEANUP flat final: {shaped.Text}");
            Check("unpunctuated recognition comes out with sentences, a capital start, the comma in far, far away and the number intact",
                flatTiming["cleanupOutcome"] == (double)CleanupOutcome.Applied && shaped.CleanupIssue == null && char.IsUpper(shaped.Text[0]) && shaped.Text.Count(c => c == '.') >= 3
                && shaped.Text.Contains("far, far away") && shaped.Text.Contains("4040 BC") && TextFidelity.CleanupIsFaithful(flat, shaped.Text) && !shaped.Text.Contains("  "));
            // AI cleanup on, model missing: the processing line says it was not run.
            var absent = new DictationPipeline(store, whisper, new LocalTextModel(Path.Combine(directory, "no-model"), Path.Combine(directory, "no-model")));
            var noModelTiming = new Dictionary<string, double>(); absent = new DictationPipeline(store, whisper, new LocalTextModel(Path.Combine(directory, "no-model"), Path.Combine(directory, "no-model"))) { Timing = (name, ms) => noModelTiming[name] = ms };
            var plain = await absent.Shape("fictional words with no model", directory, (_, _) => { }, CancellationToken.None);
            store.Write("last-processing-times.json", new Dictionary<string, double>(noModelTiming) { ["totalAfterReleaseMs"] = 1 });
            Check("without the model the processing line says AI cleanup was not run", plain.Text == "fictional words with no model" && ProcessingTimes.Read(directory).Contains("AI cleanup: not run (model not installed)"));
        } finally { Directory.Delete(directory, true); }
    }
}
