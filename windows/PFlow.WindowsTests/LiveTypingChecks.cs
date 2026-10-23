using PFlow.Core;
using PFlow.Windows;
using System.IO;
using System.Windows;

// The end of a take in all three Live text modes, through the real pipeline:
// dictionary, cleanup, paragraphs and a template shape the words once, one
// History entry is saved, and the finished text goes in exactly once. Runs in
// the private window station, so the clipboard here is the test's own.
internal static partial class Program
{
    /// A field the test owns completely; `OnReplace` runs before each write lands.
    sealed class OwnedField(string value) : ILiveTextField
    {
        public LiveFieldState Current = new(1, LiveFieldState.Target, false, true, value, new TextSpan(value.Length, 0));
        public int Writes;
        public Action<OwnedField>? OnReplace;
        public string Value => Current.Value ?? "";
        public string LineBreak => "\r\n";
        public LiveFieldState State() => Current;
        public bool CanWriteRanges() => true;
        public bool Replace(TextSpan range, string text)
        {
            Writes++; OnReplace?.Invoke(this);
            Current = Current with { Value = Value[..range.Start] + text + Value[range.End..], Selection = new TextSpan(range.Start + text.Length, 0) };
            return true;
        }
        public bool Select(TextSpan range) { Current = Current with { Selection = range }; return true; }
    }

    /// Records the normal final delivery instead of touching a real app.
    sealed class RecordingTarget : IInsertionTarget
    {
        public readonly List<string> Inserted = [];
        public bool CanInsert => true;
        public string ApplicationName => "FictionalEditor";
        public string ApplicationId => "FictionalEditor";
        public string Outcome = "Inserted";
        public Task<string> Insert(string text, IntPtr owner, bool keepClipboard, CancellationToken cancel, string? rtf = null) { Inserted.Add(text); return Task.FromResult(Outcome); }
    }

    static void NativeLiveTyping()
    {
        // 0.1.27 decision B, kept in 0.1.28: no live key typing in Chrome, Edge or Electron apps unless a guard check turns it on.
        Check("browser live key typing is off by default", !LiveKeyField.Enabled);
        string root = Path.Combine(Path.GetTempPath(), "pflow-live-typing-fictional-" + Guid.NewGuid().ToString("N"));
        try {
            // The preview names the app as it names itself, read from its program file only.
            var explorer = System.Diagnostics.Process.GetProcessesByName("explorer").FirstOrDefault();
            if (explorer != null) {
                // Read by path: a 32-bit test process cannot list a 64-bit process's modules.
                string program = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
                string expected = "Typing in " + System.Diagnostics.FileVersionInfo.GetVersionInfo(program).FileDescription!.Trim();
                Check("typing note uses the app's own name, not its program file name", InsertionTarget.TypingNoteFor((uint)explorer.Id, explorer.ProcessName) == expected && expected != "Typing in explorer");
            }
            Check("typing note falls back to the program name when the app cannot be read", InsertionTarget.TypingNoteFor(0, "fictionalpad") == "Typing in fictionalpad");
            var store = new StateStore(root);
            var template = new DictationTemplate { Name = "Harbor log", Title = "Harbor log", BoldHeadings = true, Sections = [new ReportSection { Title = "Narrative", IncludeFullDictation = true }] };
            store.Preferences.UseLocalAI = false; store.Preferences.Cleanup = true; store.Preferences.Paragraphs = true;
            store.Preferences.DictionaryReplacements = [new DictionaryEntry { Heard = "Senten", Replacement = "Sinton" }];
            store.Preferences.Templates = [template];
            var pipeline = new DictationPipeline(store, new Whisper(root), new LocalTextModel(root));
            string raw = "um Senten met us at the dock.\nThen we left.";
            T Wait<T>(Task<T> task) { while (!task.IsCompleted) { Drain(); Thread.Sleep(1); } return task.GetAwaiter().GetResult(); }
            var plain = Wait(pipeline.Shape(raw, root, (_, _) => { }, CancellationToken.None));
            Check("dictionary and cleanup shape the finished words once", plain.Text.StartsWith("Sinton met us at the dock.") && !plain.Text.Contains("um ") && plain.Text.Contains('\n') && plain.Rtf == null);
            store.Preferences.ActiveTemplateId = template.Id;
            var formatted = Wait(pipeline.Shape(raw, root, (_, _) => { }, CancellationToken.None));
            Check("the template formats the finished words", formatted.Text.Contains("Narrative") && formatted.Text.Contains("Sinton met us") && formatted.Rtf != null);

            foreach (var (mode, prepared) in new[] { (LiveTextModes.Off, plain), (LiveTextModes.TypeInApp, plain), (LiveTextModes.TypeInApp, formatted) }) {
                string label = mode + (prepared.Rtf != null ? " with a template" : "");
                Clipboard.SetText("Older fictional copy");
                var target = new RecordingTarget(); var phases = new List<Phase>();
                var field = new OwnedField("Log: "); var slot = new LiveInlineSlot(); LiveTyping? typing = null;
                if (mode == LiveTextModes.TypeInApp) {
                    Check(label + " typing begins", slot.Begin("take", field) == null);
                    // The person copies something else while pFlow types.
                    field.OnReplace = f => { if (f.Writes == 1) Clipboard.SetText("Newer fictional copy"); };
                    slot.Reconcile("take", "um senten met"); slot.Reconcile("take", "um senten met us");
                    Check(label + " provisional words are typed", field.Value == "Log: um senten met");
                    typing = new LiveTyping(text => slot.Finalize("take", text), () => slot.Typed("take"), () => slot.Cancel("take"));
                }
                int before = store.History.Count;
                var result = Wait(pipeline.Deliver(prepared, 3, target, IntPtr.Zero, (phase, _) => phases.Add(phase), CancellationToken.None, typing));
                Check(label + " saves one History entry with the finished text", store.History.Count == before + 1 && store.History[0].Text == prepared.Text);
                if (typing == null) {
                    Check(label + " delivers the finished text once the normal way", target.Inserted.SequenceEqual(new[] { prepared.Text }) && result.Status == "Inserted");
                    Check(label + " leaves the clipboard alone", Clipboard.GetText() == "Older fictional copy");
                } else {
                    string expected = "Log: " + LiveInlineText.LineBreaks(prepared.Text, "\r\n");
                    Check(label + " replaces the provisional words with the finished text once", field.Value == expected && target.Inserted.Count == 0);
                    Check(label + " reports the result honestly", result.Status == (prepared.Rtf != null ? InsertionTarget.PlainOnly : "Inserted") && store.History[0].InsertionStatus == result.Status && phases[^1] == Phase.Inserted);
                    Check(label + " keeps the newer clipboard copy", Clipboard.GetText() == "Newer fictional copy");
                }
            }
            {
                // "Copy dictation to clipboard" on: the finished words go there once, after they were typed; live words never do.
                uint calibrate = Native.GetClipboardSequenceNumber();
                ClipboardLease.KeepCopy(IntPtr.Zero, "Calibration fictional copy");
                uint perCopy = Native.GetClipboardSequenceNumber() - calibrate;
                store.Preferences.CopyDictationToClipboard = true;
                Clipboard.SetText("Older fictional copy");
                var target = new RecordingTarget(); var field = new OwnedField("Log: "); var slot = new LiveInlineSlot(); slot.Begin("t", field);
                uint before = Native.GetClipboardSequenceNumber();
                slot.Reconcile("t", "um senten met"); slot.Reconcile("t", "um senten met us");
                Check("copy on: live words are typed but never touch the clipboard", field.Value == "Log: um senten met" && Native.GetClipboardSequenceNumber() == before && Clipboard.GetText() == "Older fictional copy");
                var result = Wait(pipeline.Deliver(plain, 3, target, IntPtr.Zero, (_, _) => { }, CancellationToken.None,
                    new LiveTyping(text => slot.Finalize("t", text), () => slot.Typed("t"), () => slot.Cancel("t"))));
                Check("copy on: the finished text is typed once and reported inserted", result.Status == "Inserted" && field.Value == "Log: " + LiveInlineText.LineBreaks(plain.Text, "\r\n") && target.Inserted.Count == 0);
                Check("copy on: the clipboard holds the finished text, copied exactly once", perCopy > 0 && Clipboard.GetText() == plain.Text && Native.GetClipboardSequenceNumber() - before == perCopy);
                store.Preferences.CopyDictationToClipboard = false;
            }
            {
                // The person moves the caret after the first words: the finished text stays in History only.
                var target = new RecordingTarget(); var phases = new List<Phase>(); var field = new OwnedField(""); var slot = new LiveInlineSlot(); slot.Begin("t", field);
                slot.Reconcile("t", "um senten"); slot.Reconcile("t", "um senten met");
                field.Current = field.Current with { Selection = new TextSpan(0, 0) };
                slot.Reconcile("t", "um senten met us");
                var result = Wait(pipeline.Deliver(plain, 3, target, IntPtr.Zero, (phase, _) => phases.Add(phase), CancellationToken.None,
                    new LiveTyping(text => slot.Finalize("t", text), () => slot.Typed("t"), () => slot.Cancel("t"))));
                Check("after the cursor moved the final is kept in History with a plain message", result.Status == LiveInlineText.Kept(LiveStop.Caret) && store.History[0].InsertionStatus == result.Status && store.History[0].Text == plain.Text);
                Check("after the cursor moved nothing more is written anywhere", field.Value == "um senten" && target.Inserted.Count == 0 && phases[^1] == Phase.Saved);
            }
            {
                // Typing stopped before writing anything: the finished text goes in the normal way.
                var target = new RecordingTarget(); var field = new OwnedField("") ; var slot = new LiveInlineSlot(); slot.Begin("t", field);
                field.Current = field.Current with { Element = "other" };
                slot.Reconcile("t", "west"); slot.Reconcile("t", "west wind");
                var result = Wait(pipeline.Deliver(plain, 3, target, IntPtr.Zero, (_, _) => { }, CancellationToken.None,
                    new LiveTyping(text => slot.Finalize("t", text), () => slot.Typed("t"), () => slot.Cancel("t"))));
                Check("nothing typed means one normal delivery", target.Inserted.SequenceEqual(new[] { plain.Text }) && field.Writes == 0 && result.Status == "Inserted");
            }
            {
                // W028: words pasted into an app pFlow cannot read (Notepad++-like, PasteOnly) are a done take.
                var target = new RecordingTarget { Outcome = InsertionTarget.Pasted }; var phases = new List<Phase>();
                var result = Wait(pipeline.Deliver(plain, 3, target, IntPtr.Zero, (phase, _) => phases.Add(phase), CancellationToken.None));
                Check("pasted without a check: no Copy card, no balloon, History keeps it and says to check the field",
                    result.Prompt == null && result.Notice == null && phases.Last() == Phase.Inserted && store.History[0].InsertionStatus == InsertionTarget.Pasted
                    && HistoryRow.Status(store.History[0].InsertionStatus) == HistoryRow.CheckTheField && target.Inserted.Count == 1);
                target.Outcome = "The app did not take the text. Your words are in History.";
                result = Wait(pipeline.Deliver(plain, 3, target, IntPtr.Zero, (_, _) => { }, CancellationToken.None));
                Check("a paste the app's own text shows did not take gets the Copy card", result.Prompt != null);
            }
            {
                // Words were typed, then the whole-take recognition failed: they stay, History says so.
                var target = new RecordingTarget(); var field = new OwnedField("Note: "); var slot = new LiveInlineSlot(); slot.Begin("t", field);
                slot.Reconcile("t", "harbor lights"); slot.Reconcile("t", "harbor lights glow");
                var result = Wait(pipeline.Run(Path.Combine(root, "missing-fictional.wav"), 3, target, root, IntPtr.Zero, (_, _) => { }, CancellationToken.None, "harbor lights glow",
                    new LiveTyping(text => slot.Finalize("t", text), () => slot.Typed("t"), () => slot.Cancel("t"))));
                Check("a failed final keeps the live words with an honest status", result.Status == LiveInlineText.KeptTyped && store.History[0].Text == "harbor lights glow" && store.History[0].InsertionStatus == LiveInlineText.KeptTyped);
                Check("a failed final writes nothing more", field.Value == "Note: harbor lights" && target.Inserted.Count == 0);
            }
        } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}

internal static partial class Program
{
    /// Reports go to Downloads only when it is really local: a Downloads that is a junction or link into a
    /// cloud folder counts as cloud (W028, review minor).
    static void NativeReports()
    {
        string root = Path.Combine(Path.GetTempPath(), "pflow-reports-fictional-" + Guid.NewGuid().ToString("N"));
        try {
            string plainProfile = Path.Combine(root, "plain"), linkedProfile = Path.Combine(root, "linked"), cloud = Path.Combine(root, "OneDrive - Fictional", "Downloads");
            Directory.CreateDirectory(Path.Combine(plainProfile, "Downloads")); Directory.CreateDirectory(linkedProfile); Directory.CreateDirectory(cloud);
            var link = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c mklink /J \"" + Path.Combine(linkedProfile, "Downloads") + "\" \"" + cloud + "\"") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!;
            link.WaitForExit(10000);
            Check("fixture junction made", Directory.Exists(Path.Combine(linkedProfile, "Downloads")) && new DirectoryInfo(Path.Combine(linkedProfile, "Downloads")).LinkTarget != null);
            Check("an ordinary local Downloads is used", DiagnosticEnvironment.LocalDownloads(Path.Combine(plainProfile, "Downloads"), plainProfile));
            Check("a Downloads junction into OneDrive counts as cloud", !DiagnosticEnvironment.LocalDownloads(Path.Combine(linkedProfile, "Downloads"), linkedProfile));
        } finally { try { if (Directory.Exists(root)) { foreach (var d in Directory.GetDirectories(root, "*", SearchOption.AllDirectories).Where(d => new DirectoryInfo(d).LinkTarget != null)) Directory.Delete(d); Directory.Delete(root, true); } } catch (IOException) { } }
    }
}
