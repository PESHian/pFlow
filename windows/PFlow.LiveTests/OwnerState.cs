using System.Diagnostics;
using System.IO;
using System.Windows.Automation;
using System.Windows.Interop;
using PFlow.Core;
using PFlow.Windows;

// --owner-state: Type mode on an update from 0.1.25 as the owner has it: Live text Type, large-v3-turbo
// chosen and both retired speech models downloaded (fictional bytes under their names), the real text
// model in pFlow's folder (hashed at start as Program does), Settings open. Start as Program does:
// retired files removed before the worker starts, prewarm, then fictional narration typed live into our
// own Notepad tab, twice. Live words must reach the field before the narration ends.
internal static partial class Program
{
    static bool ownerStateOnly;
    static async Task OwnerState()
    {
        string directory = Path.Combine(root, "owner-state-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        foreach (string retired in SpeechModels.RetiredFiles) File.WriteAllBytes(Path.Combine(directory, retired), new byte[64 * 1024]);
        File.WriteAllText(Path.Combine(directory, "settings.json"), "{\"liveTextMode\":\"type\",\"speechModel\":\"large-v3-turbo-q8_0\",\"language\":\"en\",\"copyDictationToClipboard\":false}");
        string textModelFile = Path.Combine(PackageAssets, "models", "Qwen3-4B-Q4_K_M.gguf");
        if (File.Exists(textModelFile)) File.Copy(textModelFile, Path.Combine(directory, "Qwen3-4B-Q4_K_M.gguf"));
        string name = "pflow-fictional-owner-" + Guid.NewGuid().ToString("N"), file = Path.Combine(directory, name + ".txt");
        File.WriteAllText(file, "Fictional prefix. ");
        var store = new StateStore(directory);
        Check("the 0.1.25 settings load with Type mode kept", store.Preferences.LiveTextMode == LiveTextModes.TypeInApp && !store.Preferences.CopyDictationToClipboard);
        var whisper = new Whisper(directory, PackageAssets);
        var textModel = new LocalTextModel(directory, PackageAssets);
        // As Program.Start does, in its order.
        var removed = whisper.RemoveRetiredModels(); whisper.SweepPartials(); textModel.SweepPartials();
        var prewarm = Task.Run(() => whisper.Prewarm());
        _ = Task.Run(async () => { try { await textModel.Prewarm(); } catch (Exception) { } });
        // 0.1.27: only the exact downloads (size and checksum) are deleted; these fictional bytes are not them.
        Check($"start leaves fictional files under the retired names alone ({removed.Count} removed)", SpeechModels.RetiredFiles.All(f => File.Exists(Path.Combine(directory, f))) && removed.Count == 0);
        bool busy = false;
        using var hook = new KeyboardHook(_ => { }) { Enabled = false };
        var settings = new SettingsWindow(store, whisper, textModel, hook, () => { }, () => busy) { ShowActivated = false, Width = 460, Height = 740 };
        settings.Show();
        var start = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; start.ArgumentList.Add(file); Process.Start(start);
        var notepad = await WindowWith(name); var edit = await Editor(notepad);
        var capsule = new Capsule(store); var preview = new LivePreview(store);
        using var owner = new HwndSource(new HwndSourceParameters("pFlow fictional owner-state") { Width = 10, Height = 10 });
        try {
            await prewarm;
            Console.WriteLine($"LIVE owner-state: model {Path.GetFileName(whisper.ModelPath)}, engine '{whisper.EngineDescription}'");
            Check("the take runs on Whisper small with the live model loaded", Path.GetFileName(whisper.ModelPath) == SpeechModels.Small.FileName && whisper.LiveModelReady && !whisper.EngineDescription.Contains("missing"));
            var pipeline = new DictationPipeline(store, whisper, textModel);
            foreach (string take in new[] { "owner-1", "owner-2" }) {
                await Place(notepad, edit); End(edit);
                string before = Read(edit);
                var target = InsertionTarget.Capture(); var slot = new LiveInlineSlot();
                var refused = slot.Begin(take, target.LiveField());
                Check(take + " typing begins in Notepad", refused == null);
                int writes = 0; string last = before; double firstWrite = -1; var clock = Stopwatch.StartNew(); var stops = new List<LiveStop>();
                busy = true;
                var report = await FeedTake(take, "latency-long.wav", store.Preferences.LiveTextMode, false, whisper, store, preview, capsule,
                    eachBlock: () => { string now = Read(edit); if (now != last) { writes++; last = now; if (firstWrite < 0) firstWrite = clock.Elapsed.TotalMilliseconds; } },
                    typed: text => { if (slot.Reconcile(take, text) is LiveStop stop) stops.Add(stop); });
                string audio = Path.Combine(directory, take + ".wav"); File.Copy(Path.Combine(root, "latency-long.wav"), audio, true);
                var final = Stopwatch.StartNew();
                var result = await pipeline.Run(audio, report.AudioMs / 1000, target, directory, owner.Handle, (_, _) => { }, CancellationToken.None, report.LiveWords,
                    new LiveTyping(text => slot.Finalize(take, text), () => slot.Typed(take), () => slot.Cancel(take), () => slot.Collapse(take), () => slot.Selection(take)));
                busy = false;
                Console.WriteLine($"LIVE OWNER {take}: liveWrites={writes} firstWrite={firstWrite:F0}ms updates={report.Updates.Count} firstWords={report.FirstUpdateMs:F0}ms windows={report.Windows} failedAt={report.FailedAtMs:F0} tooSlowAt={report.TooSlowAtMs:F0} stops={string.Join(",", stops)} final={final.ElapsedMilliseconds}ms status={result.Status}");
                Check($"{take} live words reached Notepad before the narration ended ({writes} writes, first at {firstWrite:F0} ms)", writes >= 2 && firstWrite > 0 && firstWrite < report.AudioEndMs && stops.Count == 0 && report.FailedAtMs < 0 && report.TooSlowAtMs < 0);
                Check(take + " the finished text replaced the live words", result.Status == "Inserted" && Words(Read(edit)).EndsWith(Words("to its owner")));
            }
        } finally {
            preview.Close(); capsule.Close(); settings.Close();
            await whisper.DisposeAsync();
            await CloseOurNotepadTab(notepad, name);
            await Task.Delay(500);
            try { Directory.Delete(directory, true); } catch (IOException) { }
        }
    }
}
