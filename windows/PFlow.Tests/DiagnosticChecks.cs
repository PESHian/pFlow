using PFlow.Core;

// The diagnostic recorder (Settings → Save a diagnostic report): a fictional take runs through the real
// live-typing session and live-window rules with the recorder listening, and the saved report must say
// what happened (windows, verdicts, writes, why typing stopped) without a single dictated word, window
// title, path or account name. Plus its bounds (20 takes, about 2 MB).
internal static class DiagnosticChecks
{
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }

    /// A field the test owns; it can refuse a write the way a browser that dropped characters would.
    sealed class Field(string value, bool keys = false) : ILiveTextField
    {
        public string Value = value;
        public TextSpan Caret = new(value.Length, 0);
        public bool DropNext, Held;
        public string LineBreak => keys ? " " : "\r\n";
        public string Method => keys ? "keys" : "range write";
        public bool ReadyToWrite => !Held;
        public bool AppendOnly => keys;
        public readonly List<TextSpan> Ranges = [];
        public LiveFieldState State() => new(7, LiveFieldState.Target, false, true, Value, Caret);
        public bool CanWriteRanges() => true;
        public bool Replace(TextSpan range, string text)
        {
            Ranges.Add(range);
            if (DropNext) { DropNext = false; text = text[..(text.Length / 2)]; }
            Value = Value[..range.Start] + text + Value[range.End..]; Caret = new(range.Start + text.Length, 0); return true;
        }
        public bool FailSelect; public int Collapses;
        public bool Select(TextSpan range) { if (FailSelect && range.Length > 0) return false; Caret = range; return true; }
        public bool Collapse() { Collapses++; Caret = new(Caret.End, 0); return true; }
    }

    /// Append-only fields (typed keys): a revised word stops live typing with no write; at the end pFlow's own
    /// words (and nothing else) are selected for the finished text to go over them the checked way, or left
    /// with the card when the field is not as pFlow left it; a cancel never removes anything.
    static void AppendOnly()
    {
        {
            var field = new Field("Note: ", keys: true); var slot = new LiveInlineSlot();
            slot.Begin("a", field); slot.Reconcile("a", "harbor lights"); slot.Reconcile("a", "harbor lights glow");
            var stop = slot.Reconcile("a", "harbor lighthouse keeper");
            Check("append only: a word already typed being revised stops live typing with no write", stop == LiveStop.Revised && field.Value == "Note: harbor lights" && field.Ranges.Count == 1);
            Check("append only: nothing more is typed for the take", slot.Reconcile("a", "harbor lights glow over the water") == null && field.Value == "Note: harbor lights");
            var final = slot.Finalize("a", "harbor lights glow tonight.");
            Check("end of take: exactly pFlow's own typed words are selected, no key, for the finished text to replace", final.Result == LiveFinal.Replace && field.Value == "Note: harbor lights"
                && field.Caret == new TextSpan(6, "harbor lights".Length) && field.Ranges.Count == 1);
        }
        {
            var field = new Field("Note: ", keys: true); var slot = new LiveInlineSlot();
            slot.Begin("b", field); slot.Reconcile("b", "harbor lights"); slot.Reconcile("b", "harbor lights glow");
            var final = slot.Finalize("b", "Harbor lights glow.");
            Check("end of take: different finished text (capitals, punctuation) still selects only pFlow's words", final.Result == LiveFinal.Replace && field.Caret == new TextSpan(6, "harbor lights".Length) && field.Ranges.Count == 1);
            Check("after a refused replace the selection ends without a key", slot.Collapse("b") && field.Collapses == 1 && field.Caret == new TextSpan(6 + "harbor lights".Length, 0) && field.Value == "Note: harbor lights");
        }
        {
            var field = new Field("Note: ", keys: true); var slot = new LiveInlineSlot();
            slot.Begin("e", field); slot.Reconcile("e", "harbor lights"); slot.Reconcile("e", "harbor lights glow");
            field.Value += " QQ"; field.Caret = new(field.Value.Length, 0);
            var final = slot.Finalize("e", "Harbor lights glow.");
            Check("end of take: a field the person changed is left as it is, nothing selected (card)", final.Result == LiveFinal.Left && final.Stop == LiveStop.Text && field.Caret.Length == 0 && field.Ranges.Count == 1);
        }
        {
            var field = new Field("Note: ", keys: true) { FailSelect = true }; var slot = new LiveInlineSlot();
            slot.Begin("f", field); slot.Reconcile("f", "harbor lights"); slot.Reconcile("f", "harbor lights glow");
            var final = slot.Finalize("f", "Harbor lights glow.");
            Check("end of take: a selection that cannot be confirmed is ended and the words are left (card)", final.Result == LiveFinal.Left && field.Collapses == 1 && field.Caret.Length == 0);
        }
        {
            var field = new Field("Note:", keys: true); var slot = new LiveInlineSlot();
            slot.Begin("h", field); slot.Reconcile("h", "harbor lights"); slot.Reconcile("h", "harbor lights glow");
            var final = slot.Finalize("h", "Harbor lights glow.");
            Check("end of take: the space pFlow typed before its words stays outside the selection", final.Result == LiveFinal.Replace && field.Value == "Note: harbor lights" && field.Caret == new TextSpan(6, "harbor lights".Length));
        }
        {
            var field = new Field("Note: ", keys: true); var slot = new LiveInlineSlot();
            slot.Begin("g", field); slot.Reconcile("g", "harbor lights"); slot.Reconcile("g", "harbor lights glow");
            Check("end of take: typed words that already are the finished text need nothing", slot.Finalize("g", "harbor lights").Result == LiveFinal.Applied && field.Caret.Length == 0);
        }
        {
            var field = new Field("Note: ", keys: true); var slot = new LiveInlineSlot();
            slot.Begin("c", field); slot.Reconcile("c", "harbor lights"); slot.Reconcile("c", "harbor lights glow");
            var cancel = slot.Cancel("c");
            Check("append only: a cancel never removes the typed words", cancel.Result == LiveCancel.Left && field.Value == "Note: harbor lights" && field.Ranges.Count == 1);
        }
        {
            var field = new Field("Note: ", keys: true); var slot = new LiveInlineSlot();
            slot.Begin("d", field);
            Check("append only: with nothing typed, the finished text goes in the normal way", slot.Finalize("d", "Harbor lights.").Result == LiveFinal.NotTyped && field.Ranges.Count == 0);
        }
    }

    public static void Run()
    {
        passed = 0;
        var saved = Diagnostics.Recorder;
        long now = 0;
        var recorder = new DiagnosticRecorder(() => now, () => new DateTimeOffset(2026, 10, 23, 9, 30, 0, TimeSpan.FromHours(-5)));
        var compact = new List<string>(); recorder.Compact = compact.Add;
        Diagnostics.Recorder = recorder;
        try {
            string[] fixture = ["Marigold", "lighthouse", "keeper", "Tessaly", "Quorvane", "copper", "kettle"];
            const string title = "Quorvane budget draft - Notepad", path = @"C:\Users\Tessaly Marigold\Documents\quorvane notes.txt";
            recorder.Event("worker.start", new DiagField("result", "ready"), new DiagField("ms", 1840));
            recorder.Log("insert failed: IOException: Could not open '" + path + "'");
            recorder.BeginTake(new DiagField("trigger", "hold"), new DiagField("key", "right-ctrl"), new DiagField("liveText", "type"));
            recorder.Log("take: app=notepad field=Document/RichEditD2DPT/Win32 insertable live=type copy=False");
            recorder.Log("insert failed: IOException: The file " + path + " is in use");
            // Live windows through the real speed rule: one quick, then two slow ones in a row end live words.
            var session = new LiveSession(3, clock: () => now);
            var pcm = new short[16_000 * 3]; for (int i = 0; i < pcm.Length; i++) pcm[i] = (short)(i % 40 < 20 ? 6000 : -6000);
            session.Append(pcm);
            foreach (long took in new long[] { 900, 7000, 9500 }) {
                now += 1000;
                var request = session.Next()!;
                session.Begin(request); now += took;
                session.Complete(request, [new WhisperWindowSegment(0, 1000, fixture[(int)(took % 7)] + " " + fixture[1], 0.01)]);
                var verdict = session.LastVerdict!.Value;
                recorder.Detail("live.window", new DiagField("seq", verdict.Sequence), new DiagField("audioMs", verdict.AudioMs), new DiagField("tookMs", verdict.TookMs),
                    new DiagField("limitMs", verdict.LimitMs), new DiagField("slow", verdict.Slow), new DiagField("slowInARow", verdict.SlowRun), new DiagField("words", DiagnosticRecorder.Words(session.Text)));
                now += took; session.Append(pcm);
            }
            Check("the speed rule's verdicts are kept per window: 7,000 ms for 6 s of audio is slow, two slow in a row end live words",
                session.TooSlow && session.LastVerdict is { Slow: true, SlowRun: 2, TooSlow: true, LimitMs: 9000, TookMs: 9500, Judged: true });
            // Live typing through the real session: words agree and are typed, then a write the field drops ends typing.
            var field = new Field("Dear Quorvane team, ");
            var slot = new LiveInlineSlot();
            Check("typing begins", slot.Begin("t1", field) == null);
            slot.Reconcile("t1", "Marigold lighthouse");
            slot.Reconcile("t1", "Marigold lighthouse keeper");
            Check("the agreed words were typed", field.Value == "Dear Quorvane team, Marigold lighthouse");
            field.DropNext = true;
            var stop = slot.Reconcile("t1", "Marigold lighthouse keeper copper");
            Check("a later update after the stop writes nothing", slot.Reconcile("t1", "Marigold lighthouse keeper copper kettle") == null);
            now += 500;
            recorder.EndTake(new DiagField("result", "Inserted"), new DiagField("finalPassMs", 1234.56));
            // A second take into a keys field: a held key skips the update; finished text with line breaks is handed back.
            recorder.BeginTake(new DiagField("trigger", "double tap (hands-free)"));
            var web = new Field("", keys: true); var webSlot = new LiveInlineSlot();
            webSlot.Begin("t2", web);
            web.Held = true; webSlot.Reconcile("t2", "Tessaly copper"); webSlot.Reconcile("t2", "Tessaly copper kettle");
            Check("a held key writes nothing and does not stop typing", web.Value == "" && webSlot.Active);
            web.Held = false; webSlot.Reconcile("t2", "Tessaly copper kettle"); webSlot.Reconcile("t2", "Tessaly copper kettle lid");
            Check("keys typing resumes once the key is up", web.Value == "Tessaly copper kettle");
            var handed = webSlot.Finalize("t2", "Tessaly copper kettle.\nSecond line.");
            Check("end of take: finished text with a line break selects pFlow's words for the checked path (which pastes line breaks)", handed.Result == LiveFinal.Replace && web.Value == "Tessaly copper kettle" && web.Caret == new TextSpan(0, "Tessaly copper kettle".Length));
            Check("append only: no write ever replaced or removed characters", web.Ranges.All(range => range.Length == 0));
            AppendOnly();
            recorder.EndTake(new DiagField("result", "Inserted"));

            string report = recorder.Report([new DiagField("cpu.name", "Fictional Core 5 125U"), new DiagField("pflow.installedIn", path)]);
            string everything = report + string.Join("\n", compact);
            Console.WriteLine("DIAGNOSTIC REPORT EXCERPT:\n" + string.Join("\n", report.Split('\n').Where(l => l.Contains("typing.") || l.Contains("live.window")).Take(8)));
            Check("the report names why typing stopped and how the read-back differed (numbers only)",
                stop == LiveStop.Uncertain && report.Contains("typing.stop reason=Uncertain stage=live writeAccepted=yes") && report.Contains("firstDifferenceAt="));
            Check("the report keeps every live window with its verdict", report.Split('\n').Count(l => l.Contains(" live.window ")) == 3 && report.Contains("tookMs=7000 limitMs=6000 slow=yes slowInARow=1"));
            Check("the report keeps each write with its method, size and read-back", report.Contains("typing.write stage=live method=\"range write\"") && report.Contains("readBackMatches=no") && report.Contains("method=keys"));
            Check("the report says a held key paused typing and the end-of-take replace", report.Contains("typing.wait") && report.Contains("mode=\"replace own words\""));
            Check("the take's summary counts its steps in insertion.log", compact.Any(l => l.StartsWith("diag take 1 ") && l.Contains("take.end") && l.Contains("live.window=3") && l.Contains("typing.write=")));
            Check("insertion.log gets the decisions, not every window", compact.Any(l => l.Contains("typing.stop")) && !compact.Any(l => l.Contains(" live.window ")));
            Check("no fixture word appears in the report or the log lines", !fixture.Any(word => everything.Contains(word, StringComparison.OrdinalIgnoreCase)));
            Check("no window title, path or account name appears", !everything.Contains(title) && !everything.Contains(@"C:\") && !everything.Contains("Users")
                && !everything.Contains("Documents") && everything.Contains("<path>"));
            Check("timestamps are milliseconds since the take began", report.Contains("[take 1, began 09:30:00, ms since it began]") && report.Contains("+0 ms take.start trigger=hold"));

            // Bounds: 25 takes keep the last 20; a flood of lines stays near the 2 MB budget.
            for (int i = 0; i < 25; i++) { recorder.BeginTake(); for (int j = 0; j < 4100; j++) recorder.Detail("live.window", new DiagField("seq", j), new DiagField("label", new string('x', 200))); recorder.EndTake(); }
            Check($"only the last {DiagnosticRecorder.MaxTakes} takes are kept", recorder.TakeCount <= DiagnosticRecorder.MaxTakes);
            Check($"the report stays within about 2 MB ({recorder.Chars} characters)", recorder.Chars <= DiagnosticRecorder.MaxChars + 200_000);
            Check("a value cannot carry a paragraph: it is cut at 160 characters", DiagnosticRecorder.Value(new string('a', 500)).Length <= DiagnosticRecorder.MaxValueLength + 1);
            Check("control characters never break a line", !DiagnosticRecorder.Value("one\ntwo\rthree").Contains('\n'));
            Check("logs name only known apps; any other program is 'other'", PrivateLog.AppLabel("Notepad") == "Notepad" && PrivateLog.AppLabel("msedge") == "msedge"
                && PrivateLog.AppLabel("QuorvaneLedger") == "other" && PrivateLog.AppLabel(null) == "other");
            Check("Japanese, Chinese and Korean input languages compose text; English and German do not",
                InputLanguages.Composes(0x0411) && InputLanguages.Composes(0x0804) && InputLanguages.Composes(0x0404) && InputLanguages.Composes(0x0412) && !InputLanguages.Composes(0x0409) && !InputLanguages.Composes(0x0407));
        } finally { Diagnostics.Recorder = saved; }
        Console.WriteLine($"{passed} diagnostic checks passed.");
    }
}
