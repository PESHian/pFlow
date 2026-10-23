using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Interop;
using PFlow.Core;
using PFlow.Windows;
using Forms = System.Windows.Forms;

// "Type in the current app" on Windows, in the signed-in session, against
// fields the test owns (a WinForms edit and rich edit in a separate host
// process, a throwaway Notepad tab, a local Edge page). Transcript updates are
// scripted or come from fictional narration through the live path; no
// microphone and no key events into other apps.
internal static partial class Program
{
    static bool inlineOnly, inlineElevatedOnly;
    const int WM_SETTEXT = 0x000C, EM_SETSEL = 0x00B1, EM_REPLACESEL = 0x00C2;
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, string lParam);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

    // ---------- The test-owned host window (its own process, so UI Automation and messages cross processes as with a real app).

    const string HostPlain = "Dear Sam,\r\nBefore  after.\r\n— cafe\u0301 中文 👋🏽 end";

    static int InlineHost(string directory)
    {
        Forms.Application.EnableVisualStyles();
        string name = Path.GetFileName(directory);
        var form = new Forms.Form { Text = name + " host", Width = 760, Height = 560, StartPosition = Forms.FormStartPosition.CenterScreen };
        var layout = new Forms.FlowLayoutPanel { Dock = Forms.DockStyle.Fill, FlowDirection = Forms.FlowDirection.TopDown, WrapContents = false };
        Forms.TextBox Box(string label, bool multiline) => new() { AccessibleName = label, Multiline = multiline, AcceptsReturn = multiline, Width = 700, Height = multiline ? 110 : 28 };
        var plain = Box("Fictional plain", true); plain.Text = HostPlain;
        var rich = new Forms.RichTextBox { AccessibleName = "Fictional rich", Width = 700, Height = 110 };
        rich.Rtf = @"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0 Segoe UI;}}{\colortbl;\red200\green0\blue0;}\f0\fs22\b Dear Sam,\b0\par Before  \cf1 after.\cf0\par " + RtfText("— cafe\u0301 中文 👋🏽 end") + "}";
        var secret = Box("Fictional password", false); secret.UseSystemPasswordChar = true;
        var fixer = Box("Fictional autocorrect", false);
        // An app that changes what was written: it capitalises the first letter.
        fixer.TextChanged += (_, _) => { if (fixer.Text.Length > 0 && char.IsLower(fixer.Text[0])) { int at = fixer.SelectionStart; fixer.Text = char.ToUpperInvariant(fixer.Text[0]) + fixer.Text[1..]; fixer.SelectionStart = at; } };
        foreach (var control in new Forms.Control[] { plain, rich, secret, fixer }) { control.Name = control.AccessibleName!.Replace(" ", ""); layout.Controls.Add(control); }
        form.Controls.Add(layout);
        int handled = 0;
        var timer = new Forms.Timer { Interval = 50 };
        timer.Tick += (_, _) => {
            string command = Path.Combine(directory, $"command-{handled + 1}.txt");
            if (!File.Exists(command)) return;
            string text = File.ReadAllText(command); handled++;
            if (text == "quit") { form.Close(); return; }
            // Formatting of the original runs, checked here because rich text formatting is not readable across processes.
            int bold = rich.Text.IndexOf("Dear Sam,", StringComparison.Ordinal), red = rich.Text.IndexOf("after.", StringComparison.Ordinal);
            int keepStart = rich.SelectionStart, keepLength = rich.SelectionLength;
            bool Bold() { rich.Select(bold, 9); return bold >= 0 && rich.SelectionFont?.Bold == true; }
            bool Red() { rich.Select(red, 6); return red >= 0 && rich.SelectionColor.R == 200 && rich.SelectionColor.G == 0; }
            var reply = new { plain = plain.Text, rich = rich.Text, bold = Bold(), red = Red(), fixer = fixer.Text, secret = secret.Text.Length };
            rich.Select(keepStart, keepLength);
            File.WriteAllText(Path.Combine(directory, $"reply-{handled}.json"), JsonSerializer.Serialize(reply));
        };
        form.Shown += (_, _) => { timer.Start(); File.WriteAllText(Path.Combine(directory, "ready.txt"), Environment.ProcessId.ToString()); };
        Forms.Application.Run(form);
        return 0;
    }

    static string RtfText(string text) => string.Concat(text.Select(c => c < 128 ? c.ToString() : $"\\u{(short)c}?"));

    sealed record HostReport(string plain, string rich, bool bold, bool red, string fixer, int secret);
    static int hostCommands;
    static async Task<HostReport> AskHost(string directory)
    {
        int id = ++hostCommands; File.WriteAllText(Path.Combine(directory, $"command-{id}.txt"), "report");
        string reply = Path.Combine(directory, $"reply-{id}.json");
        for (int i = 0; i < 100 && !File.Exists(reply); i++) await Task.Delay(50);
        await Task.Delay(50);
        return JsonSerializer.Deserialize<HostReport>(File.ReadAllText(reply))!;
    }
    static void QuitHost(string directory) => File.WriteAllText(Path.Combine(directory, $"command-{++hostCommands}.txt"), "quit");

    static async Task<int> StartHost(string directory)
    {
        Directory.CreateDirectory(directory);
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
        start.ArgumentList.Add(root); start.ArgumentList.Add("--inline-host"); start.ArgumentList.Add(directory);
        Process.Start(start);
        return await WaitHost(directory);
    }
    static async Task<int> WaitHost(string directory)
    {
        string ready = Path.Combine(directory, "ready.txt");
        for (int i = 0; i < 200 && !File.Exists(ready); i++) await Task.Delay(50);
        Check("test-owned host window is ready", File.Exists(ready));
        return int.Parse(File.ReadAllText(ready));
    }

    // ---------- Helpers acting as the person, only on our own windows and our own Notepad tab.

    static AutomationElement Named(AutomationElement window, string name) =>
        window.FindFirst(TreeScope.Descendants, new OrCondition(new PropertyCondition(AutomationElement.NameProperty, name), new PropertyCondition(AutomationElement.AutomationIdProperty, name.Replace(" ", ""))))
            ?? throw new Exception("No fixture field " + name);
    static IntPtr Handle(AutomationElement field) => new(field.Current.NativeWindowHandle);
    static void PersonSelects(AutomationElement field, int start, int end) => SendMessage(Handle(field), EM_SETSEL, new IntPtr(start), new IntPtr(end));
    static void PersonTypes(AutomationElement field, string text) => SendMessage(Handle(field), EM_REPLACESEL, new IntPtr(1), text);
    static TextSpan Selection(AutomationElement field)
    {
        var pattern = (TextPattern)field.GetCurrentPattern(TextPattern.Pattern); var selection = pattern.GetSelection()[0];
        var prefix = pattern.DocumentRange.Clone(); prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, selection, TextPatternRangeEndpoint.Start);
        return new TextSpan(prefix.GetText(-1).Length, selection.GetText(-1).Length);
    }
    /// Brings our window forward and focuses the field, waiting until UI Automation agrees.
    static async Task Place(AutomationElement window, AutomationElement field)
    {
        var id = field.GetRuntimeId();
        for (int attempt = 0; attempt < 3; attempt++) {
            await Activate(window, field);
            try { field.SetFocus(); } catch (InvalidOperationException) { }
            for (int i = 0; i < 20; i++) {
                await Task.Delay(50);
                try { if (AutomationElement.FocusedElement.GetRuntimeId().SequenceEqual(id)) return; } catch (ElementNotAvailableException) { }
            }
        }
        Check("fictional field focused", false);
    }
    static int Occurrences(string text, string part) => (text.Length - text.Replace(part, "").Length) / part.Length;

    /// Starts a take the way Program does: capture the field, then begin typing before any pFlow window shows.
    static (InsertionTarget Target, LiveInlineSlot Slot, LiveStop? Refused) Begin(string session)
    {
        var target = InsertionTarget.Capture(); var slot = new LiveInlineSlot();
        return (target, slot, slot.Begin(session, target.LiveField()));
    }

    // ---------- A6: revisions, Unicode, surrounding text and formatting, final once.

    static readonly string[] Script = ["Merci 🙏 à", "Merci 🙏 à bientôt", "Merci 🙏 à bientôt 再见", "Merci 🙏 à bientôt 再见", "Merci 🙏 a bientôt 再见", "Merci 🙏 a bientôt 再见"];
    const string ScriptFinal = "Merci 🙏, à bientôt 再见 cafe\u0301.\nSecond fictional line.";

    static async Task<string> Revisions(string label, AutomationElement window, AutomationElement field, string lineBreak)
    {
        string before = Read(field); int caret = before.IndexOf("Before ", StringComparison.Ordinal) + 7;
        Check(label + " fixture text is as written", caret > 7 && before.Contains("cafe\u0301 中文 👋🏽"));
        string head = before[..caret], tail = before[caret..];
        await Place(window, field); PersonSelects(field, caret, caret);
        var (target, slot, refused) = Begin(label);
        if (refused != null) { var probe = target.LiveField(); var state = probe?.State(); Console.WriteLine($"LIVE {label} refused={refused} field={(probe == null ? "none" : "native")} {target.DescribeLiveField()} state={(state == null ? "" : $"app={state.App} element={state.Element} secure={state.Secure} trusted={state.Trusted} value={state.Value?.Length} selection={state.Selection}")} writable={probe?.CanWriteRanges()} ui={Selection(field)}"); }
        Check(label + " typing begins (inline, not Preview)", refused == null && Selection(field) == new TextSpan(caret, 0));
        var written = new List<string>();
        foreach (string update in Script) {
            var stop = slot.Reconcile(label, update); string now = Read(field);
            Check($"{label} '{update}' keeps typing", stop == null);
            Check($"{label} '{update}' leaves the surrounding text exactly", now.StartsWith(head, StringComparison.Ordinal) && now.EndsWith(tail, StringComparison.Ordinal));
            Check($"{label} '{update}' leaves the caret after pFlow's words", Selection(field) == new TextSpan(now.Length - tail.Length, 0));
            written.Add(now[head.Length..^tail.Length]);
        }
        Check(label + " typed only settled words, revised in place", written.SequenceEqual(new[] { "", "Merci 🙏 à", "Merci 🙏 à bientôt", "Merci 🙏 à bientôt 再见", "Merci 🙏", "Merci 🙏 a bientôt 再见" }));
        var final = slot.Finalize(label, ScriptFinal);
        string after = Read(field), expected = head + LiveInlineText.LineBreaks(ScriptFinal, lineBreak) + tail;
        Check(label + " the finished text replaces the provisional words once", final.Result == LiveFinal.Applied && after == expected && Occurrences(after, "Second fictional line.") == 1);
        Check(label + " caret ends after the finished text", Selection(field) == new TextSpan(expected.Length - tail.Length, 0));
        Console.WriteLine($"LIVE {label} line break units={lineBreak.Length} final='{after[head.Length..^tail.Length].Replace("\r", "\\r").Replace("\n", "\\n")}'");
        // Selected text: live words replace it, cancel puts it back and selects it again.
        PersonSelects(field, 0, 4); string selected = Read(field);
        var (_, again, refusedAgain) = Begin(label + "-cancel");
        Check(label + " typing begins over a selection", refusedAgain == null && Selection(field) == new TextSpan(0, 4));
        again.Reconcile(label + "-cancel", "Hello there"); again.Reconcile(label + "-cancel", "Hello there friend");
        Check(label + " live words replace the selected word", Read(field) == "Hello there" + selected[4..]);
        var cancel = again.Cancel(label + "-cancel");
        Check(label + " cancel restores the selected word and selection", cancel.Result == LiveCancel.Removed && Read(field) == selected && Selection(field) == new TextSpan(0, 4));
        return after;
    }

    // ---------- A7: anything the person does stops typing for the take, and nothing is written later.

    static async Task Stops(AutomationElement host, AutomationElement notepad, AutomationElement notepadEdit)
    {
        var plain = Named(host, "Fictional plain"); var rich = Named(host, "Fictional rich");
        async Task<(LiveInlineSlot Slot, string Session, string Typed)> Typing(string name)
        {
            SendMessage(Handle(plain), WM_SETTEXT, IntPtr.Zero, "Log: ");
            await Place(host, plain); PersonSelects(plain, 5, 5);
            var (_, slot, refused) = Begin(name);
            Check(name + " typing begins", refused == null);
            slot.Reconcile(name, "west wind"); slot.Reconcile(name, "west wind rising");
            string typed = Read(plain);
            Check(name + " first words typed", typed == "Log: west wind");
            return (slot, name, typed);
        }
        async Task After(string name, LiveInlineSlot slot, LiveStop expected, Func<string> value, Func<Task>? undo = null)
        {
            var stop = slot.Reconcile(name, "west wind rising over");
            Check($"{name} stops typing ({stop})", stop == expected);
            string frozen = value();
            if (undo != null) await undo();
            Check(name + " putting things back does not resume typing", slot.Reconcile(name, "west wind rising over the hill") == null && value() == frozen);
            var final = slot.Finalize(name, "West wind rising over the hill.");
            Check(name + " keeps the finished text for History and writes nothing", final == (LiveFinal.Kept, expected) && value() == frozen);
        }
        {
            var (slot, name, typed) = await Typing("caret-moved");
            PersonSelects(plain, 0, 0);
            await After(name, slot, LiveStop.Caret, () => Read(plain), async () => { PersonSelects(plain, typed.Length, typed.Length); await Task.Yield(); });
        }
        {
            var (slot, name, typed) = await Typing("person-typed");
            PersonTypes(plain, "!");
            await After(name, slot, LiveStop.Text, () => Read(plain));
            Check("person-typed: the person's character is kept", Read(plain) == typed + "!");
        }
        {
            var (slot, name, _) = await Typing("owned-span-edited");
            PersonSelects(plain, 5, 9); PersonTypes(plain, "East");
            await After(name, slot, LiveStop.Text, () => Read(plain));
            Check("owned-span-edited: the person's edit is kept", Read(plain) == "Log: East wind");
        }
        {
            var (slot, name, _) = await Typing("app-switch");
            await Place(notepad, notepadEdit);
            await After(name, slot, LiveStop.App, () => Read(plain), () => Place(host, plain));
        }
        {
            var (slot, name, _) = await Typing("field-switch");
            await Place(host, rich);
            await After(name, slot, LiveStop.Focus, () => Read(plain), () => Place(host, plain));
        }
        {
            var (slot, name, _) = await Typing("password-mid-take");
            await Place(host, Named(host, "Fictional password"));
            var stop = slot.Reconcile(name, "west wind rising over");
            Check(name + " stops typing when a password field takes focus", stop is LiveStop.Focus or LiveStop.Secure);
            Check(name + " nothing reached the password field", (await AskHost(hostDirectory)).secret == 0);
            await Place(host, plain); slot.Abandon();
        }
        {
            await Place(host, Named(host, "Fictional password")); bool refused = false;
            try { InsertionTarget.Capture(); } catch (InvalidOperationException error) { refused = error.Message == "Dictation is off in password fields."; }
            Check("a password field never starts dictation", refused);
        }
        {
            var fixer = Named(host, "Fictional autocorrect");
            await Place(host, fixer);
            var (_, slot, refused) = Begin("uncertain");
            Check("uncertain: typing begins", refused == null);
            slot.Reconcile("uncertain", "rain soon");
            Check("uncertain: a write the app changed stops typing", slot.Reconcile("uncertain", "rain soon then") == LiveStop.Uncertain);
            string changed = Read(fixer);
            slot.Reconcile("uncertain", "rain soon then sun"); slot.Reconcile("uncertain", "rain soon then sun");
            Check("uncertain: the write is never retried", Read(fixer) == changed && changed == "Rain soon");
            Check("uncertain: the finished text stays in History only", slot.Finalize("uncertain", "Rain soon, then sun.") == (LiveFinal.Kept, LiveStop.Uncertain) && Read(fixer) == changed);
        }
        {
            var (slot, name, typed) = await Typing("cancel-after-edit");
            PersonSelects(plain, 0, 0); PersonTypes(plain, "Z");
            var cancel = slot.Cancel(name);
            Check("cancel never undoes a later edit by the person", cancel == (LiveCancel.Left, LiveStop.Text) && Read(plain) == "Z" + typed);
        }
        {
            // Notepad too: the person clicks elsewhere.
            notepadEdit = await Editor(notepad); await Place(notepad, notepadEdit); End(notepadEdit);
            var (_, slot, refused) = Begin("notepad-caret");
            Check("Notepad typing begins", refused == null);
            slot.Reconcile("notepad-caret", "pelican harbor"); slot.Reconcile("notepad-caret", "pelican harbor dawn");
            string typed = Read(notepadEdit); PersonSelects(notepadEdit, 0, 0);
            Check("Notepad caret move stops typing", slot.Reconcile("notepad-caret", "pelican harbor dawn chorus") == LiveStop.Caret);
            Check("Notepad keeps the words already typed and nothing more", slot.Finalize("notepad-caret", "Pelican harbor dawn chorus.").Result == LiveFinal.Kept && Read(notepadEdit) == typed);
        }
    }

    static string hostDirectory = "";

    static async Task Inline()
    {
        string directory = Path.Combine(root, "inline-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        hostDirectory = Path.Combine(directory, "pflow-fictional-inline-" + Guid.NewGuid().ToString("N")[..8]);
        string name = "pflow-fictional-live-" + Guid.NewGuid().ToString("N"), file = Path.Combine(directory, name + ".txt");
        File.WriteAllText(file, HostPlain);
        uint clipboard = Native.GetClipboardSequenceNumber();
        var matrix = new List<string>();
        AutomationElement? notepad = null;
        try {
            int hostId = await StartHost(hostDirectory);
            var host = await WindowWith(Path.GetFileName(hostDirectory) + " host");
            Check("host is a separate process", host.Current.ProcessId == hostId && hostId != Environment.ProcessId);
            await Revisions("winforms-edit", host, Named(host, "Fictional plain"), "\r\n");
            matrix.Add("Win32 Edit (WinForms TextBox, own process): inline");
            var richField = Named(host, "Fictional rich");
            await Revisions("winforms-richedit", host, richField, "\r");
            var report = await AskHost(hostDirectory);
            Check("rich edit keeps its bold and red runs", report.bold && report.red);
            matrix.Add("RichEdit 5.0 (WinForms RichTextBox): inline; plain text in the run's formatting, other runs unchanged");

            var start = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; start.ArgumentList.Add(file); Process.Start(start);
            notepad = await WindowWith(name); var notepadEdit = await Editor(notepad);
            await Revisions("notepad", notepad, notepadEdit, "\r");
            matrix.Add("Notepad 11 (RichEditD2DPT): inline");

            await Stops(host, notepad, notepadEdit);
            await Browser(directory, matrix);
            Console.WriteLine("LIVE Electron editor NOT RUN: no VS Code, Cursor or other Electron editor is installed on this VM.");
            matrix.Add("Electron (VS Code): absent on this VM, NOT RUN");
            await TypingWithNarration(directory, host, notepad);
            Check("live typing never touched the clipboard", Native.GetClipboardSequenceNumber() == clipboard);
            foreach (string line in matrix) Console.WriteLine("LIVE matrix: " + line);
        } finally {
            QuitHost(hostDirectory);
            if (notepad != null) await CloseOurNotepadTab(notepad, name);
            await Task.Delay(500);
            try { Directory.Delete(directory, true); } catch (IOException) { }
        }
    }

    // ---------- Edge: no safe range write, so the take shows the preview and the page is never touched.

    static async Task Browser(string directory, List<string> matrix)
    {
        string page = Path.Combine(directory, "pflow-fictional-page.html");
        File.WriteAllText(page, "<!doctype html><meta charset=utf-8><title>pflow-fictional-inline-page</title><input aria-label='Fictional input' value='Dear Sam, '><textarea aria-label='Fictional area'>Dear Sam,\nBefore </textarea>");
        string edgePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe");
        if (!File.Exists(edgePath)) { Console.WriteLine("LIVE Edge NOT RUN: not installed."); matrix.Add("Edge: NOT RUN"); return; }
        var edge = new ProcessStartInfo(edgePath) { UseShellExecute = false };
        foreach (var arg in new[] { "--user-data-dir=" + Path.Combine(directory, "edge-fictional-profile"), "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--force-renderer-accessibility", "--app=" + new Uri(page).AbsoluteUri }) edge.ArgumentList.Add(arg);
        var process = Process.Start(edge)!;
        try {
            var window = await WindowWith("pflow-fictional-inline-page");
            foreach (string label in new[] { "Fictional input", "Fictional area" }) {
                AutomationElement? field = null;
                for (int i = 0; i < 50 && field == null; i++) { field = window.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, label)); if (field == null) await Task.Delay(100); }
                Check("Edge exposes " + label, field != null);
                await Place(window, field!); End(field!);
                string before = Read(field!);
                var (_, slot, refused) = Begin("edge");
                slot.Reconcile("edge", "harbor lights"); slot.Reconcile("edge", "harbor lights glow");
                // 0.1.27: a readable Edge field takes live words as typed characters (LiveKeyField), append only.
                string typed = Read(field!);
                var (cancel, stop) = slot.Cancel("edge"); await Task.Delay(300);
                // Append only: a cancel never sends keys to take words back out; they stay and the person is told.
                Check($"Edge {label} types the settled words live; cancel leaves them, no keys ({refused?.ToString() ?? "typing"}, {cancel})",
                    refused == null && typed == before + "harbor lights" && cancel == LiveCancel.Left && stop == null && Read(field!) == typed);
                matrix.Add($"Edge {label} (Chromium, file:// page): typed live with keys (append only), read back, left on cancel");
            }
            if (window.TryGetCurrentPattern(WindowPattern.Pattern, out var pattern)) ((WindowPattern)pattern).Close();
        } finally {
            for (int i = 0; i < 40 && !process.HasExited; i++) await Task.Delay(100);
        }
    }

    // ---------- Real recognition of fictional narration, typed live into our own field and our Notepad tab, then the final once.

    static async Task TypingWithNarration(string directory, AutomationElement host, AutomationElement notepad)
    {
        string model = Path.Combine(directory, "ggml-small.bin");
        File.Copy(Path.Combine(PackageAssets, "models", "ggml-small.bin"), model);
        var store = new StateStore(directory); store.Preferences.Language = "en"; store.Preferences.CopyDictationToClipboard = false; store.Preferences.LiveTextMode = LiveTextModes.TypeInApp;
        await using var whisper = new Whisper(directory, PackageAssets);
        var capsule = new Capsule(store); var preview = new LivePreview(store);
        using var owner = new HwndSource(new HwndSourceParameters("pFlow fictional inline owner") { Width = 10, Height = 10 });
        try {
            await whisper.Prewarm();
            var pipeline = new DictationPipeline(store, whisper, new LocalTextModel(directory, PackageAssets));
            var plain = Named(host, "Fictional plain");
            foreach (var (take, window) in new[] { ("narration-edit", host), ("narration-notepad", notepad) }) {
                AutomationElement field = take == "narration-edit" ? plain : await Editor(notepad);
                if (take == "narration-edit") SendMessage(Handle(plain), WM_SETTEXT, IntPtr.Zero, "Fictional prefix. ");
                await Place(window, field); End(field);
                string before = Read(field);
                var (target, slot, refused) = Begin(take);
                Check(take + " typing begins", refused == null);
                int writes = 0; string last = before; var stops = new List<LiveStop>();
                var report = await FeedTake(take, "latency-long.wav", LiveTextModes.TypeInApp, false, whisper, store, preview, capsule,
                    eachBlock: () => { string now = Read(field); if (now != last) { writes++; last = now; } },
                    typed: text => { if (slot.Reconcile(take, text) is LiveStop stop) stops.Add(stop); });
                string atEnd = Read(field);
                Check(take + " words were typed into the field before the narration ended", writes >= 2 && atEnd.Length > before.Length && atEnd.StartsWith(before, StringComparison.Ordinal));
                Check(take + " typing never stopped", stops.Count == 0);
                capsule.Set(Phase.Processing); preview.Finishing();
                string audio = Path.Combine(directory, take + ".wav"); File.Copy(Path.Combine(root, "latency-long.wav"), audio, true);
                var result = await pipeline.Run(audio, report.AudioMs / 1000, target, directory, owner.Handle, (phase, detail) => capsule.Set(phase, detail), CancellationToken.None, report.LiveWords,
                    new LiveTyping(text => slot.Finalize(take, text), () => slot.Typed(take), () => slot.Cancel(take)));
                preview.Clear();
                string after = Normalize(Read(field)), final = new StateStore(directory).History[0].Text;
                string expected = Normalize(before) + Normalize(InsertionSpacing.AtCaret(final, before, before.Length, 0).Apply(final));
                Check(take + " the finished text replaced the live words once", result.Status == "Inserted" && after == expected && Occurrences(after, Normalize(final)) == 1);
                Check(take + " finished text includes the last words", Words(final).EndsWith(Words("to its owner")));
                Console.WriteLine($"LIVE {take}: {writes} live writes; at audio end '{atEnd[before.Length..]}'; final '{final}'");
            }
            Check("narration takes saved one History entry each", new StateStore(directory).History.Count == 2);
            // How the preview reads while typing, after a stop, and when an app cannot be typed into.
            foreach (string theme in new[] { "light", "dark" })
            foreach (var (tag, note) in new[] { ("typing", "Typing in Notepad"), ("stopped", LiveInlineText.StoppedNote(LiveStop.Uncertain)), ("refused", LiveInlineText.PreviewNote(LiveStop.Permission)) }) {
                store.Preferences.Theme = theme; preview.ApplyTheme(); preview.Begin(); preview.SetNote(note);
                preview.ShowText("The lighthouse keeper counted the copper lanterns while the pelicans waited.");
                Render(preview, $"inline-{tag}-{theme}", 2, 1);
                Check($"{theme} preview shows the note '{note}'", preview.Caption == note);
            }
            preview.Clear();
        } finally { preview.Close(); capsule.Close(); }
    }

    // ---------- An elevated (administrator) host: Windows blocks pFlow from it, so it is never typed into.

    static async Task InlineElevated()
    {
        string directory = Directory.GetDirectories(root, "pflow-fictional-inline-admin-*").Single();
        hostDirectory = directory;
        int hostId = await WaitHost(directory);
        Console.WriteLine($"LIVE integrity: checks=0x{LiveTextField.Integrity(0):X} host=0x{LiveTextField.Integrity((uint)hostId):X}");
        var host = await WindowWith(Path.GetFileName(directory) + " host");
        LiveStop? refused = null; bool captured = true; string layer = "pFlow's live check";
        try {
            // The host focuses its first field itself; pFlow below it cannot look inside with UI Automation.
            await Activate(host); await Task.Delay(300);
            var target = InsertionTarget.Capture(); var slot = new LiveInlineSlot();
            var field = target.LiveField();
            Console.WriteLine($"LIVE admin capture: canInsert={target.CanInsert} liveField={(field == null ? "none" : "native")}");
            refused = slot.Begin("admin", field);
            slot.Reconcile("admin", "harbor lights"); slot.Reconcile("admin", "harbor lights glow");
        } catch (Exception error) when (error is InvalidOperationException or ElementNotAvailableException or COMException) { captured = false; layer = "capture (" + error.Message + ")"; }
        Console.WriteLine($"LIVE admin host refused by {layer}");
        Console.WriteLine($"LIVE admin host: captured={captured} refused={refused}");
        Check("an administrator app is never typed into", !captured || refused is LiveStop.Permission or LiveStop.Unsupported);
        Check("the administrator app's text is unchanged", (await AskHost(directory)).plain == HostPlain);
        QuitHost(directory);
    }

    /// Closes only our own Notepad tab, choosing Don't save. The tab must be the
    /// active one (the window title shows its file name) and no other dialog may
    /// be open; otherwise the tab is left open and the run says so.
    static async Task CloseOurNotepadTab(AutomationElement window, string name)
    {
        try {
            var tab = window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem)).Cast<AutomationElement>().SingleOrDefault(x => x.Current.Name.Contains(name));
            if (tab == null) { Console.WriteLine("LIVE our Notepad tab is already closed"); return; }
            ((SelectionItemPattern)tab.GetCurrentPattern(SelectionItemPattern.Pattern)).Select(); await Task.Delay(300);
            bool popup = window.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ClassNameProperty, "Popup")) != null;
            if (!window.Current.Name.Contains(name) || popup) { Console.WriteLine("LIVE left our Notepad tab open: it is not the active tab or a dialog is open"); return; }
            await Activate(window);
            var file = window.FindFirst(TreeScope.Descendants, new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem), new PropertyCondition(AutomationElement.NameProperty, "File")));
            ((ExpandCollapsePattern)file.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand(); await Task.Delay(400);
            if (!window.Current.Name.Contains(name)) { Console.WriteLine("LIVE left our Notepad tab open: active tab changed"); return; }
            var close = AutomationElement.RootElement.FindFirst(TreeScope.Descendants, new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem), new PropertyCondition(AutomationElement.NameProperty, "Close tab"), new PropertyCondition(AutomationElement.ProcessIdProperty, window.Current.ProcessId)));
            ((InvokePattern)close.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
            for (int i = 0; i < 30; i++) {
                await Task.Delay(150);
                var skip = window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button)).Cast<AutomationElement>().FirstOrDefault(x => x.Current.Name is "Don't save" or "Don’t save");
                if (skip != null) { ((InvokePattern)skip.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); break; }
            }
            await Task.Delay(400);
            bool gone = !window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem)).Cast<AutomationElement>().Any(x => x.Current.Name.Contains(name));
            Console.WriteLine(gone ? "LIVE closed our Notepad tab without saving" : "LIVE our Notepad tab is still open");
        } catch (Exception error) when (error is ElementNotAvailableException or InvalidOperationException or NullReferenceException) { Console.WriteLine("LIVE could not close our Notepad tab: " + error.Message); }
    }
}
