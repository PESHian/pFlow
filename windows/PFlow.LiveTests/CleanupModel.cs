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
                Console.WriteLine($"CLEANUP {audio}: words={TextProcessing.WordCount(raw)} cleanupMs={timing.GetValueOrDefault("cleanupMs"):F0} budgetMs={model.Budget(TextProcessing.WordCount(raw)).TotalMilliseconds:F0} outcome={(CleanupOutcome)(int)timing.GetValueOrDefault("cleanupOutcome")} issue={prepared.CleanupIssue ?? "none"} elapsed={clock.ElapsedMilliseconds}");
                Console.WriteLine($"CLEANUP {audio} raw: {raw}");
                Console.WriteLine($"CLEANUP {audio} model: {model.LastModelText}");
                Console.WriteLine($"CLEANUP {audio} final: {prepared.Text}");
                Check(audio + ": the model ran and its edit was used", stages.Contains("Cleaning up") && model.LastOutcome == CleanupOutcome.Applied && !prepared.CleanupIncomplete && prepared.CleanupIssue == null);
                Check(audio + ": cleanup time is recorded as its own number within the budget", timing.TryGetValue("cleanupMs", out double ms) && ms > 0 && ms < model.Budget(TextProcessing.WordCount(raw)).TotalMilliseconds && timing["cleanupOutcome"] == (double)CleanupOutcome.Applied);
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
            // A long flat take (286 fictional words, the owner's "15-20 sentence story" case): cleaned within the
            // model's own cut-off, every word and number kept, sentences and capitals added. The time is the number the owner asked for.
            // It keeps the spoken clock time "6 30": the model writes "6:30", and the fidelity rule accepts that one colon.
            const string story = "so last tuesday my cousin nora and i drove out to the old quarry road to look for the lost dog that the neighbors had been talking about for three days we packed two sandwiches a thermos of coffee and a bag of the cheap dog treats from the corner shop which cost us about 4 dollars and 50 cents the road was muddy from the storm and nora's little blue car slid twice before we even reached the gate um we parked by the broken fence and started calling the dog's name which was biscuit and honestly i didn't think we'd find anything after maybe forty minutes we heard barking from behind the water tower and there he was tangled up in some old wire fencing he wasn't hurt just scared and very very hungry so we fed him the whole bag of treats and half of my sandwich on the way back we stopped at the diner on route 9 and the waitress said the owner had been in that morning asking everyone about him we called the number on the flyer and a man named walter answered and he started crying right there on the phone he said biscuit had jumped out of the truck window on friday near mile marker 12 and he'd been driving up and down the road ever since we met him in the diner parking lot at about 6 30 and biscuit just about knocked him over walter tried to give us 100 dollars but nora wouldn't take it so he bought us pie instead which was uh fine with me anyway that's why we were late to your party and why the car smells like wet dog";
            var storyTiming = new Dictionary<string, double>();
            var storyPipeline = new DictationPipeline(store, whisper, model) { Timing = (name, ms) => storyTiming[name] = ms };
            var longTake = await storyPipeline.Shape(story, directory, (_, _) => { }, CancellationToken.None);
            Console.WriteLine($"CLEANUP story: words={TextProcessing.WordCount(story)} cleanupMs={storyTiming.GetValueOrDefault("cleanupMs"):F0} budgetMs={model.Budget(TextProcessing.WordCount(story)).TotalMilliseconds:F0} outcome={(CleanupOutcome)(int)storyTiming.GetValueOrDefault("cleanupOutcome")} issue={longTake.CleanupIssue ?? "none"} model={model.InUse?.Label} threads={LocalTextModel.Threads}");
            Console.WriteLine($"CLEANUP story final: {longTake.Text}");
            Check("a 286-word flat story is cleaned within its cut-off with every word and number kept, at least ten sentences, names and the first word capitalized",
                storyTiming["cleanupOutcome"] == (double)CleanupOutcome.Applied && longTake.CleanupIssue == null && storyTiming["cleanupMs"] < model.Budget(TextProcessing.WordCount(story)).TotalMilliseconds
                && TextFidelity.CleanupIsFaithful(story, longTake.Text) && longTake.Text.Count(c => c == '.') >= 10 && longTake.Text.StartsWith("So last Tuesday my cousin Nora and I ") && longTake.Text.Contains("Walter") && longTake.Text.Contains("route 9") && longTake.Text.Contains("mile marker 12") && longTake.Text.Contains("6:30") && !longTake.Text.Contains("  "));
            // A cut-off take delivered: the result names the issue once for the balloon and History keeps it with the status.
            var cutPipeline = new DictationPipeline(store, whisper, model) { CleanupBudget = TimeSpan.FromMilliseconds(1) };
            var cutPrepared = await cutPipeline.Shape(flat, directory, (_, _) => { }, CancellationToken.None);
            var delivered = await cutPipeline.Deliver(cutPrepared, 1.0, new InsertingTarget(), IntPtr.Zero, (_, _) => { }, CancellationToken.None);
            Check("a delivered cut-off take carries the cleanup issue and History says it with the status", delivered.Status == "Inserted" && delivered.CleanupIssue == LocalTextModel.TimedOutIssue
                && delivered.Notice == "Dictation inserted. " + LocalTextModel.TimedOutIssue && delivered.NoticeIsCleanup && store.History[0].InsertionStatus == "Inserted · " + LocalTextModel.TimedOutIssue && HistoryRow.Status(store.History[0].InsertionStatus) == HistoryRow.Inserted);
            // The same cut-off take whose clipboard could not be put back: that notice is not the cleanup one, so it is never the once-per-start balloon.
            const string blocked = "Clipboard restore was blocked. Keep pFlow open and check your clipboard.";
            var blockedTake = await cutPipeline.Deliver(cutPrepared, 1.0, new UncheckedTarget(blocked), IntPtr.Zero, (_, _) => { }, CancellationToken.None);
            Check("a cut-off take with a clipboard notice keeps that notice, which is not the cleanup one", blockedTake.Notice == blocked && blockedTake.CleanupIssue == LocalTextModel.TimedOutIssue && !blockedTake.NoticeIsCleanup
                && store.History[0].InsertionStatus == blocked + " · " + LocalTextModel.TimedOutIssue);
            store.Write("last-processing-times.json", new Dictionary<string, double> { ["totalAfterReleaseMs"] = 1, ["cleanupMs"] = 5000, ["cleanupOutcome"] = (double)CleanupOutcome.RejectedSymbols });
            Check("a symbols-only rejection is named on the processing line", ProcessingTimes.Read(directory).Contains("AI cleanup: 5.0 s (changed punctuation inside a number, so not used)"));
            // Local text model switched off with AI cleanup on: the processing line says which switch.
            store.Preferences.UseLocalAI = false; var offTiming = new Dictionary<string, double>();
            var off = new DictationPipeline(store, whisper, model) { Timing = (name, ms) => offTiming[name] = ms };
            var untouched = await off.Shape("fictional words with the model off", directory, (_, _) => { }, CancellationToken.None);
            store.Write("last-processing-times.json", new Dictionary<string, double>(offTiming) { ["totalAfterReleaseMs"] = 1 });
            Check("with the local text model off the processing line says so", untouched.Text == "fictional words with the model off" && ProcessingTimes.Read(directory).Contains("AI cleanup: not run (local text model off)"));
            store.Preferences.UseLocalAI = true;
            // AI cleanup on, model missing: the processing line says it was not run.
            var absent = new DictationPipeline(store, whisper, new LocalTextModel(Path.Combine(directory, "no-model"), Path.Combine(directory, "no-model")));
            var noModelTiming = new Dictionary<string, double>(); absent = new DictationPipeline(store, whisper, new LocalTextModel(Path.Combine(directory, "no-model"), Path.Combine(directory, "no-model"))) { Timing = (name, ms) => noModelTiming[name] = ms };
            var plain = await absent.Shape("fictional words with no model", directory, (_, _) => { }, CancellationToken.None);
            store.Write("last-processing-times.json", new Dictionary<string, double>(noModelTiming) { ["totalAfterReleaseMs"] = 1 });
            Check("without the model the processing line says AI cleanup was not run", plain.Text == "fictional words with no model" && ProcessingTimes.Read(directory).Contains("AI cleanup: not run (model not installed)"));
        } finally { Directory.Delete(directory, true); }
    }
}
