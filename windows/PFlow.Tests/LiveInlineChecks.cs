using PFlow.Core;
using System.Text.Json.Nodes;

// "Type in the current app": the shared ownership fixtures (the very files the
// Mac app runs, linked into the test output), settled words, and one take's
// session and slot against a field the test owns completely.
internal static class LiveInlineChecks
{
    static int passed;
    static void Check(string name, bool value) { if (!value) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }

    public static int Run()
    {
        passed = 0;
        OwnershipFixtures(); SettledWords(); Limits(); Sessions(); Notes();
        Console.WriteLine($"{passed} live typing checks passed.");
        return passed;
    }

    static TextSpan Span(JsonNode? pair) => new((int)pair![0]!, (int)pair[1]!);

    static void OwnershipFixtures()
    {
        var files = Directory.GetFiles(Path.Combine(AppContext.BaseDirectory, "live-text", "inline-ownership"), "*.json").OrderBy(x => x, StringComparer.Ordinal).ToArray();
        Check($"the shared ownership fixtures are present ({files.Length})", files.Length >= 28);
        foreach (var file in files) {
            string name = Path.GetFileName(file);
            var root = JsonNode.Parse(File.ReadAllText(file))!;
            var start = root["begin"]!["field"]!;
            var state = new LiveFieldState((long)start["app"]!, (string)start["element"]!, (bool)start["secure"]!, (bool)start["trusted"]!,
                (string?)start["value"], Span(start["selection"]));
            var ownership = LiveInlineOwnership.Begin(state, (bool)root["begin"]!["writable"]!, out var refused);
            string expectedBegin = (string)root["beginResult"]!;
            Check(name + " begins as " + expectedBegin, ownership != null ? expectedBegin == "ready" : refused.ToString()!.ToLowerInvariant() == expectedBegin);
            if (ownership == null) continue;
            int index = 0;
            foreach (var step in root["steps"]!.AsArray()) {
                string op = (string)step!["op"]!, label = $"{name} step {index++} {op}";
                LiveStep? result = null;
                switch (op) {
                    case "edit": {
                        var range = Span(step["range"]); string text = (string)step["text"]!;
                        state = state with { Value = state.Value![..range.Start] + text + state.Value[range.End..],
                            Selection = step["caret"] is JsonNode caret ? Span(caret) : new TextSpan(range.Start + text.Length, 0) };
                        break;
                    }
                    case "select": state = state with { Selection = Span(step["range"]) }; break;
                    case "app": state = state with { App = (long)step["pid"]! }; break;
                    case "focus": state = state with { Element = (string)step["element"]! }; break;
                    case "secure": state = state with { Secure = (bool)step["secure"]! }; break;
                    case "trust": state = state with { Trusted = (bool)step["trusted"]! }; break;
                    case "update": result = ownership.Update((string)step["text"]!, state); break;
                    case "final": result = ownership.Finalize((string)step["text"]!, state); break;
                    case "cancel": result = ownership.Cancel(state); break;
                    default: throw new Exception(label + ": unknown op");
                }
                if (result != null && step["expect"] is JsonNode expect) {
                    switch ((string)expect["action"]!) {
                        case "none": Check(label + " writes nothing", result is LiveStep.Nothing); break;
                        case "stop": Check(label + " stops: " + (string)expect["reason"]!, result is LiveStep.Stopped stopped && stopped.Reason.ToString().ToLowerInvariant() == (string)expect["reason"]!); break;
                        default: {
                            var write = new LiveStep.Write(Span(expect["range"]), (string)expect["text"]!, expect["select"] is JsonNode select ? Span(select) : null);
                            Check(label + " writes exactly " + Describe(write) + " (got " + Describe(result) + ")", result == write);
                            bool accepted = true;
                            if (step["apply"] is JsonNode apply) {
                                state = state with { Value = (string?)apply["value"] ?? state.Value, Selection = apply["selection"] is JsonNode s ? Span(s) : state.Selection };
                                accepted = (bool?)apply["accepted"] ?? true;
                            } else {
                                state = state with { Value = state.Value![..write.Range.Start] + write.Text + state.Value[write.Range.End..],
                                    Selection = write.Select ?? new TextSpan(write.Range.Start + write.Text.Length, 0) };
                            }
                            var confirmed = ownership.Confirm(accepted, state);
                            bool uncertain = (string?)expect["confirm"] == "uncertain";
                            Check(label + " confirms " + (uncertain ? "uncertain" : "ok"), uncertain ? confirmed == new LiveStep.Stopped(LiveStop.Uncertain) : confirmed is LiveStep.Nothing);
                            break;
                        }
                    }
                }
                if (step["field"] is JsonNode field) {
                    Check(label + " leaves the field text", string.Equals(state.Value, (string)field["value"]!, StringComparison.Ordinal));
                    Check(label + " leaves the selection", state.Selection == Span(field["selection"]));
                }
            }
        }
    }

    static string Describe(LiveStep step) => step switch {
        LiveStep.Write w => $"[{w.Range.Start},{w.Range.Length}] '{w.Text}'" + (w.Select is TextSpan s ? $" select [{s.Start},{s.Length}]" : ""),
        LiveStep.Stopped s => "stop " + s.Reason,
        _ => "none"
    };

    static void SettledWords()
    {
        Check("the first update settles nothing", LiveStableText.Agreed(null, "The harbor") == "");
        Check("an unfinished word is not settled", LiveStableText.Agreed("The harb", "The harbor opens") == "The");
        Check("a finished word is settled", LiveStableText.Agreed("The harbor", "The harbor opens") == "The harbor");
        Check("punctuation that changes is cut back", LiveStableText.Agreed("Hello world.", "Hello world, how") == "Hello world");
        Check("an apostrophe continues the word", LiveStableText.Agreed("I don", "I don't know") == "I");
        Check("each Chinese character ends a word", LiveStableText.Agreed("你好世", "你好世界") == "你好世");
        Check("identical updates settle everything", LiveStableText.Agreed("Same words", "Same words") == "Same words");
        Check("an invented first phrase settles nothing", LiveStableText.Agreed("On the first cold night.", "The harbor") == "");
        Check("an emoji with a skin tone is one character", LiveStableText.Characters("a👋🏽b").Length == 3);
        Check("a combining mark stays with its letter", LiveStableText.Characters("café").Length == 4);
        Check("CRLF is one character", LiveStableText.Characters("a\r\nb").Length == 3);
    }

    static LiveFieldState Field(string value, TextSpan? selection = null) =>
        new(1, LiveFieldState.Target, false, true, value, selection ?? new TextSpan(value.Length, 0));

    static void Limits()
    {
        string longest = new('a', LiveInlineOwnership.MaxFieldLength);
        Check("a field at the length limit can be typed into", LiveInlineOwnership.Begin(Field(longest), true, out _) != null);
        Check("a longer field uses Preview", LiveInlineOwnership.Begin(Field(longest + "a"), true, out var over) == null && over == LiveStop.Unsupported);
        Check("a caret between the halves of an emoji uses Preview", LiveInlineOwnership.Begin(Field("Hi 👋", new TextSpan(4, 0)), true, out var split) == null && split == LiveStop.Unsupported);
        Check("a selection ending inside an emoji uses Preview", LiveInlineOwnership.Begin(Field("👋 hi", new TextSpan(0, 1)), true, out _) == null);
        Check("no single selection uses Preview", LiveInlineOwnership.Begin(Field("Hi") with { Selection = null }, true, out var none) == null && none == LiveStop.Unsupported);
        Check("a password field never begins", LiveInlineOwnership.Begin(Field("") with { Secure = true }, true, out var secure) == null && secure == LiveStop.Secure);
        Check("an admin app (no permission) never begins", LiveInlineOwnership.Begin(Field("") with { Trusted = false }, true, out var trust) == null && trust == LiveStop.Permission);
    }

    /// A field a test owns completely. Writes behave like a well-behaved
    /// native control unless `OnReplace` says otherwise.
    sealed class SimulatedField(string value, TextSpan? selection = null, string lineBreak = "\r\n") : ILiveTextField
    {
        public LiveFieldState Current = Field(value, selection);
        public bool Writable = true;
        public readonly List<(TextSpan Range, string Text)> Replaced = [];
        public Func<SimulatedField, TextSpan, string, bool>? OnReplace;
        public string Value => Current.Value ?? "";
        public string LineBreak => lineBreak;
        public int Reads;
        public LiveFieldState State() { Reads++; return Current; }
        public bool CanWriteRanges() => Writable;
        public bool Replace(TextSpan range, string text)
        {
            Replaced.Add((range, text));
            if (OnReplace != null) return OnReplace(this, range, text);
            Current = Current with { Value = Value[..range.Start] + text + Value[range.End..], Selection = new TextSpan(range.Start + text.Length, 0) };
            return true;
        }
        public bool Select(TextSpan range) { Current = Current with { Selection = range }; return true; }
        /// The person edits the field directly.
        public void Edit(TextSpan range, string text) =>
            Current = Current with { Value = Value[..range.Start] + text + Value[range.End..], Selection = new TextSpan(range.Start + text.Length, 0) };
    }

    static void Sessions()
    {
        {
            var field = new SimulatedField("Note: "); var slot = new LiveInlineSlot();
            Check("typing begins in a plain field", slot.Begin("take-1", field) == null && slot.Active);
            slot.Reconcile("take-1", "the light"); slot.Reconcile("take-1", "the lighthouse");
            Check("only settled words are typed", field.Value == "Note: the");
            slot.Reconcile("take-1", "the lighthouse keeper");
            Check("the next settled word is added after pFlow's own words", field.Value == "Note: the lighthouse");
            Check("an update for another take never writes", slot.Reconcile("take-0", "stale words here please") == null && field.Value == "Note: the lighthouse");
            var final = slot.Finalize("take-1", "The lighthouse keeper waved.");
            Check("the finished text replaces the typed words once", final.Result == LiveFinal.Applied && field.Value == "Note: The lighthouse keeper waved." && field.Current.Selection == new TextSpan(34, 0));
            int writes = field.Replaced.Count;
            Check("after the final, the slot is empty and late updates never write", !slot.Active && slot.Reconcile("take-1", "late words arrive here") == null && field.Replaced.Count == writes);
            Check("a second final for the same take does nothing", slot.Finalize("take-1", "again").Result == LiveFinal.NotTyped && field.Replaced.Count == writes);
        }
        {
            var field = new SimulatedField("Dear Sam, "); var slot = new LiveInlineSlot(); slot.Begin("t", field);
            slot.Reconcile("t", "thanks for"); slot.Reconcile("t", "thanks for the map");
            Check("words typed before the caret moved", field.Value == "Dear Sam, thanks for");
            field.Current = field.Current with { Selection = new TextSpan(0, 0) };
            Check("moving the caret stops typing", slot.Reconcile("t", "thanks for the map and") == LiveStop.Caret);
            field.Current = field.Current with { Selection = new TextSpan(20, 0) };
            int reads = field.Reads;
            Check("putting the caret back does not resume typing", slot.Reconcile("t", "thanks for the map and the") == null && field.Replaced.Count == 1);
            Check("after typing stopped, later updates never read the field", field.Reads == reads);
            var final = slot.Finalize("t", "thanks for the map and the compass");
            Check("the finished text is kept for History, not written", final == (LiveFinal.Kept, LiveStop.Caret) && field.Value == "Dear Sam, thanks for");
        }
        {
            var field = new SimulatedField("Notes") { Writable = false }; var slot = new LiveInlineSlot();
            Check("a field that cannot take range writes uses Preview", slot.Begin("t", field) == LiveStop.Unsupported && !slot.Active);
            slot.Reconcile("t", "buy"); slot.Reconcile("t", "buy rope");
            Check("Preview never writes to the field", field.Replaced.Count == 0 && slot.Finalize("t", "buy rope").Result == LiveFinal.NotTyped);
            Check("no field at all uses Preview", slot.Begin("t2", null) == LiveStop.Unsupported);
        }
        foreach (bool userEdits in new[] { false, true }) {
            var field = new SimulatedField("Pack the old tent today", new TextSpan(9, 8)); var slot = new LiveInlineSlot(); slot.Begin("t", field);
            slot.Reconcile("t", "new"); slot.Reconcile("t", "new canvas");
            Check("live words replace the selected text", field.Value == "Pack the new today");
            if (userEdits) field.Edit(new TextSpan(0, 4), "Load");
            var cancel = slot.Cancel("t");
            if (userEdits) Check("cancel never undoes the person's later edit", cancel == (LiveCancel.Left, LiveStop.Text) && field.Value == "Load the new today");
            else Check("cancel puts the selected text back and selects it", cancel.Result == LiveCancel.Removed && field.Value == "Pack the old tent today" && field.Current.Selection == new TextSpan(9, 8));
        }
        foreach (string lineBreak in new[] { "\r\n", "\r" }) {
            var field = new SimulatedField("", lineBreak: lineBreak); var slot = new LiveInlineSlot(); slot.Begin("t", field);
            slot.Reconcile("t", "Use the police report"); slot.Reconcile("t", "Use the police report template. Officer");
            Check("the spoken template command can appear provisionally", field.Value == "Use the police report");
            var final = slot.Finalize("t", "Narrative\nOfficer Pesh arrived.\n\nSecond line.");
            string expected = $"Narrative{lineBreak}Officer Pesh arrived.{lineBreak}{lineBreak}Second line.";
            Check($"the command is replaced by the formatted text once, with the field's own line breaks ({lineBreak.Length})", final.Result == LiveFinal.Applied && field.Value == expected);
        }
        {
            var field = new SimulatedField("");
            field.OnReplace = (f, range, text) => { f.Current = f.Current with { Value = f.Value[..range.Start] + text + " " + f.Value[range.End..], Selection = new TextSpan(range.Start + text.Length + 1, 0) }; return true; };
            var slot = new LiveInlineSlot(); slot.Begin("t", field);
            slot.Reconcile("t", "rain");
            Check("a write that reads back differently stops typing", slot.Reconcile("t", "rain soon") == LiveStop.Uncertain);
            slot.Reconcile("t", "rain soon then");
            Check("an uncertain write is never retried", field.Replaced.Count == 1);
            Check("after an uncertain write the final stays in History", slot.Finalize("t", "rain soon then sun") == (LiveFinal.Kept, LiveStop.Uncertain) && field.Replaced.Count == 1);
        }
        {
            var field = new SimulatedField(""); field.OnReplace = (_, _, _) => false;
            var slot = new LiveInlineSlot(); slot.Begin("t", field);
            slot.Reconcile("t", "quiet"); slot.Reconcile("t", "quiet harbor");
            Check("a refused write is uncertain and cancel leaves the field alone", slot.Cancel("t") == (LiveCancel.Left, LiveStop.Uncertain) && field.Replaced.Count == 1);
        }
        {
            var field = new SimulatedField("Keep this. "); var slot = new LiveInlineSlot(); slot.Begin("t", field);
            slot.Reconcile("t", "um uh"); slot.Reconcile("t", "um uh");
            Check("a repeated update settles the last words", field.Value == "Keep this. um uh" && slot.Typed("t"));
            Check("a take with no finished text takes its words back out", slot.Cancel("t").Result == LiveCancel.Removed && field.Value == "Keep this. ");
        }
        {
            var field = new SimulatedField("A"); var slot = new LiveInlineSlot(); slot.Begin("t", field);
            field.Current = field.Current with { App = 2 };
            slot.Reconcile("t", "west"); slot.Reconcile("t", "west wind");
            Check("switching apps before the first write stops typing", field.Replaced.Count == 0);
            Check("nothing typed means the final goes the normal way", slot.Finalize("t", "West wind.").Result == LiveFinal.NotTyped);
        }
        {
            var field = new SimulatedField(""); var slot = new LiveInlineSlot(); slot.Begin("t", field);
            slot.Reconcile("t", "first take"); slot.Reconcile("t", "first take words");
            slot.Abandon();
            Check("an abandoned take never writes again", slot.Reconcile("t", "first take words more") == null && slot.Finalize("t", "x").Result == LiveFinal.NotTyped && field.Value == "first take");
        }
        Check("line breaks become the field's own", LiveInlineText.LineBreaks("a\nb\r\nc\rd", "\r") == "a\rb\rc\rd" && LiveInlineText.LineBreaks("a\nb\r\nc", "\r\n") == "a\r\nb\r\nc");
    }

    static void Notes()
    {
        Check("the typing note uses the app's own name", LiveInlineText.TypingNote("Notepad", "Microsoft Windows Operating System", "notepad") == "Typing in Notepad");
        Check("without a description it uses the product name", LiveInlineText.TypingNote("  ", "Fictional Writer", "fwriter") == "Typing in Fictional Writer");
        Check("without either it uses the program name", LiveInlineText.TypingNote(null, null, "notepad") == "Typing in notepad" && LiveInlineText.TypingNote(null, "", "") == "Typing in this app");
        Check("a long or odd app name is cleaned and shortened", LiveInlineText.TypingNote("Fictional\u0007 " + new string('x', 80), null, "f") is var note && note.Length == "Typing in ".Length + 61 && note.EndsWith('…') && !note.Contains('\u0007'));
        foreach (var stop in Enum.GetValues<LiveStop>()) {
            Check($"{stop} has a short stopped note", LiveInlineText.StoppedNote(stop).Length is > 0 and <= 26);
            Check($"{stop} has a one-line preview note", LiveInlineText.PreviewNote(stop).Length is > 0 and <= 50);
            Check($"{stop} explains where the finished text went", LiveInlineText.Kept(stop).EndsWith("The finished text is in History."));
        }
        Check("a field pFlow cannot type into live says the words still go in when the take stops", LiveInlineText.PreviewNote(LiveStop.Unsupported).Contains("when you stop"));
    }
}
