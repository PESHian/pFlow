using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Automation;
using System.Windows.Interop;
using PFlow.Core;
using PFlow.Windows;

// W027: Type-mode takes as Program runs them, with the diagnostic recorder listening.
// --diag-takes   one take into Notepad and one into a warm Edge field; the saved report is read back
//                and scanned (no fixture words, no paths, no account name).
// --chrome-live  live typing in Edge (cold and warm: contenteditable body, textarea, input; password)
//                and Chrome (body): live writes, time to first write, final text exactly once.
// --report-button  Settings → Troubleshooting: the real button pressed through UI Automation, light and dark at
//                420 and 900 px: the file lands on the Desktop, Explorer opens on it, the line under the button names it.
// --slow-live    the "too slow here" rule on a starved worker: Notepad takes with the speech worker held
//                to fewer cores (PFLOW_SLOW_CORES, e.g. "6,2,1").
internal static partial class Program
{
    static bool diagTakesOnly, chromeLiveOnly, slowLiveOnly, reportButtonOnly, chromeGuardOnly;
    static readonly string[] FixtureWords = ["Saturday", "market", "square", "stalls", "honey", "pottery", "Ellis", "fountain", "samples", "plum", "bakery", "cousin", "Ruth", "jars", "Morgan", "tomato", "storm", "folding", "shed"];

    sealed class TypeResult
    {
        public int Writes, Matched; public double FirstWriteMs = -1;
        public List<LiveStop> Stops = []; public string Status = "", Final = "", FieldWhy = "", Section = "";
        public string? Refused; public bool Typed, LateBegin; public TakeReport Report = new();
    }

    /// One Type-mode take as Program runs it: BeginTake, capture, typing begins before any pFlow window
    /// (or later, when Chromium's field becomes readable during the take: CaptureAgainSoon + BeginTypingLate),
    /// live updates reconciled, then the pipeline's finish with the take's LiveTyping, EndTake.
    static async Task<TypeResult> TypeTake(string name, string audio, Whisper whisper, StateStore store, LocalTextModel textModel, LivePreview preview, Capsule capsule, IntPtr owner, string directory, string? expectApp = null)
    {
        var result = new TypeResult(); var recorder = Diagnostics.Recorder;
        recorder.BeginTake(new DiagField("trigger", "hold"), new DiagField("key", store.Preferences.ActivationKey), new DiagField("liveText", LiveTextModes.TypeInApp));
        var target = InsertionTarget.Capture();
        // Never a window the check does not own: the take stops before anything is typed if focus is elsewhere.
        if (expectApp != null && !string.Equals(target.ApplicationName, expectApp, StringComparison.OrdinalIgnoreCase)) {
            recorder.EndTake(new DiagField("result", "wrong window"));
            Check($"{name}: the take starts in {expectApp} (focus was in {target.ApplicationName})", false);
        }
        InsertionLog.Record("take: app=" + target.LogName + " field=" + target.Kind + (target.CanInsert ? " insertable" : " not insertable: " + target.Refusal) + " live=" + LiveTextModes.TypeInApp);
        var slot = new LiveInlineSlot(); string session = name; bool typing = false;
        var field = target.LiveField(out string why); result.FieldWhy = why;
        if (field == null) recorder.Event("typing.field", new DiagField("result", "none"), new DiagField("why", why));
        var refused = slot.Begin(session, field);
        typing = refused == null; result.Refused = refused?.ToString();
        if (refused != null) InsertionLog.Record("live typing not started: " + refused);
        recorder.Event("capture.detail", DiagnosticEnvironment.Take(target));
        var clock = Stopwatch.StartNew(); int look = 0; int[] looks = [300, 1000, 2500, 5500];
        async Task During(TakeReport report, LiveRecognizer? live)
        {
            await Task.CompletedTask;
            if (!target.Placeholder || look >= looks.Length || clock.ElapsedMilliseconds < looks[look]) return;
            int wait = looks[look++];
            InsertionTarget again;
            try { again = InsertionTarget.Capture(); }
            catch (InvalidOperationException error) { InsertionLog.Record("take: capture again refused: " + InsertionLog.Reason(error)); look = looks.Length; return; }
            if (!target.SameWindow(again)) { InsertionLog.Record("take: focus left the window; placeholder kept"); look = looks.Length; return; }
            if (again.CanInsert && !again.Placeholder) {
                target = again; InsertionLog.Record("take: field readable after " + wait + " ms: " + again.Kind); look = looks.Length;
                if (typing) return;
                var late = again.LiveField(out string lateWhy);
                if (late == null) { recorder.Event("typing.field", new DiagField("result", "none"), new DiagField("stage", "field readable during the take"), new DiagField("why", lateWhy)); return; }
                var lateRefused = slot.Begin(session, late);
                if (lateRefused != null) { InsertionLog.Record("live typing not started: " + lateRefused); return; }
                typing = true; result.LateBegin = true;
            } else InsertionLog.Record("take: still the placeholder after " + wait + " ms");
        }
        result.Report = await FeedTake(name, audio, LiveTextModes.TypeInApp, false, whisper, store, preview, capsule, During,
            typed: text => { if (typing && slot.Reconcile(session, text) is LiveStop stop) { result.Stops.Add(stop); InsertionLog.Record("live: " + LiveInlineText.StoppedNote(stop)); } });
        result.Typed = typing && slot.Typed(session);
        InsertionLog.Record("live: windows=" + result.Report.Windows + " typed=" + result.Typed);
        string wav = Path.Combine(directory, name + ".wav"); File.Copy(Path.Combine(root, audio), wav, true);
        var timing = new Dictionary<string, double>();
        var pipeline = new DictationPipeline(store, whisper, textModel) { Timing = (key, ms) => timing[key] = ms };
        var final = Stopwatch.StartNew();
        DictationPipeline.Result run;
        try {
            run = await pipeline.Run(wav, result.Report.AudioMs / 1000, target, directory, owner, (_, _) => { }, CancellationToken.None, result.Report.LiveWords,
                typing ? new LiveTyping(text => slot.Finalize(session, text), () => slot.Typed(session), () => slot.Cancel(session)) : null);
        } catch (RecognitionFailure error) {
            // As Program.Finish does: the take failed; the recorder says so.
            InsertionLog.Record("take failed: " + InsertionLog.Reason(error));
            recorder.EndTake(new DiagField("result", "failed"), new DiagField("reason", PrivateLog.Reason(error)));
            result.Status = "failed: " + error.Message; result.Report.FinalMs = final.Elapsed.TotalMilliseconds;
            string failed = recorder.Report([]); result.Section = failed[failed.LastIndexOf("\n[take ", StringComparison.Ordinal)..];
            return result;
        }
        result.Report.FinalMs = final.Elapsed.TotalMilliseconds;
        result.Status = run.Status; result.Final = store.History.Count > 0 ? store.History[0].Text : "";
        InsertionLog.Record("take done: " + (result.Report.AudioMs / 1000).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " s, status=" + run.Status);
        recorder.EndTake([new DiagField("result", run.Status), .. timing.Select(t => new DiagField(t.Key, t.Value))]);
        // The take's own lines in the recorder: live writes, how many read back right, the first one's time.
        string report = recorder.Report([]); result.Section = report[report.LastIndexOf("\n[take ", StringComparison.Ordinal)..];
        foreach (string line in result.Section.Split('\n').Where(l => l.Contains(" typing.write stage=live "))) {
            result.Writes++;
            if (line.Contains("readBackMatches=yes")) { result.Matched++; if (result.FirstWriteMs < 0) result.FirstWriteMs = double.Parse(line[1..line.IndexOf(" ms", StringComparison.Ordinal)]); }
        }
        return result;
    }

    static string Flat(string text) => Regex.Replace(text.Replace('\u00A0', ' '), @"\s+", " ").Trim();

    /// A fictional page in a fresh Edge or Chrome window (its own fictional profile), the field focused by
    /// the page with the caret at the end; the title mirrors the field (a password box: its length only).
    static async Task<(Process Process, IntPtr Window, string Name, string Html)> OpenPage(string browser, string variant, string prefix, bool accessible = false)
    {
        string name = "pflow-fictional-live-" + variant + "-" + Guid.NewGuid().ToString("N");
        string html = Path.Combine(root, name + ".html");
        string field = variant switch {
            "password" => "<input id=b type=password aria-label='Fictional secret'>",
            "textarea" => "<textarea id=b aria-label='Fictional area' rows=6 cols=60>" + prefix + "</textarea>",
            "input" => "<input id=b type=text aria-label='Fictional line' size=80 value='" + prefix + "'>",
            "guard" or "slow" => "<div id=b contenteditable=true role=textbox aria-multiline=true aria-label='Fictional body'>" + prefix + "</div><input id=p type=password aria-label='Fictional secret'>"
                + (variant == "slow" ? "<script>var n=0;document.getElementById('b').addEventListener('beforeinput',function(){if(++n>20){var t=Date.now();while(Date.now()-t<400){}}});</script>" : ""),
            _ => "<div id=b contenteditable=true role=textbox aria-multiline=true aria-label='Fictional body'>" + prefix + "</div>"
        };
        File.WriteAllText(html, "<!doctype html><meta charset=utf-8><title>" + name + "</title><style>body{font:16px sans-serif;margin:24px}[contenteditable]{min-height:120px;border:1px solid #888;padding:8px}</style>"
            + "<p>Fictional compose</p>" + field
            + "<script>var b=document.getElementById('b');function mirror(){var t=b.type==='password'?('len:'+b.value.length):(b.value!==undefined?b.value:b.innerText);var p=document.getElementById('p');document.title='" + name + " | '+t.replace(/\\s+/g,' ')+(p?' | pw len:'+p.value.length:'');}"
            + "function end(){b.focus();if(b.setSelectionRange){b.setSelectionRange(b.value.length,b.value.length);}else{var r=document.createRange();r.selectNodeContents(b);r.collapse(false);var s=getSelection();s.removeAllRanges();s.addRange(r);}}"
            + "b.addEventListener('input',mirror);var pw=document.getElementById('p');if(pw)pw.addEventListener('input',mirror);window.addEventListener('load',function(){end();mirror();});</script>");
        string path = browser == "chrome" ? @"C:\Program Files\Google\Chrome\Application\chrome.exe"
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe");
        var start = new ProcessStartInfo(path) { UseShellExecute = false };
        foreach (var arg in new[] { "--user-data-dir=" + Path.Combine(root, (browser == "chrome" ? "chrome" : "edge") + "-fictional-profile-" + name[^8..]), "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--app=" + new Uri(html).AbsoluteUri })
            start.ArgumentList.Add(arg);
        // The guard checks are about typing, not about a cold page building its tree: there the tree is built from the start.
        if (accessible) start.ArgumentList.Add("--force-renderer-accessibility");
        var process = Process.Start(start)!;
        string image = browser == "chrome" ? "chrome" : "msedge";
        IntPtr window = IntPtr.Zero;
        for (int i = 0; i < 150 && window == IntPtr.Zero; i++) {
            await Task.Delay(100);
            foreach (var p in Process.GetProcessesByName(image)) { try { if (p.MainWindowTitle.Contains(name)) window = p.MainWindowHandle; } catch { } }
        }
        Check(browser + " " + variant + ": the window appeared", window != IntPtr.Zero);
        await Task.Delay(1500);
        Front(window); await Task.Delay(700);
        return (process, window, name, html);
    }

    static void Front(IntPtr window)
    {
        uint foregroundThread = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out _), me = GetCurrentThreadId();
        bool attached = foregroundThread != me && AttachThreadInput(me, foregroundThread, true);
        try { SetForegroundWindow(window); } finally { if (attached) AttachThreadInput(me, foregroundThread, false); }
    }

    static string Title(IntPtr window) { var text = new System.Text.StringBuilder(8192); GetWindowText(window, text, text.Capacity); return text.ToString(); }

    static async Task ClosePage(string browser, (Process Process, IntPtr Window, string Name, string Html) page)
    {
        try { page.Process.CloseMainWindow(); } catch { }
        foreach (var p in Process.GetProcessesByName(browser == "chrome" ? "chrome" : "msedge")) { try { if (p.MainWindowTitle.Contains(page.Name)) p.CloseMainWindow(); } catch { } }
        await Task.Delay(800);
        try { File.Delete(page.Html); } catch { }
        // The fictional browser profile goes too (each is tens of MB).
        string profile = Path.Combine(root, (browser == "chrome" ? "chrome" : "edge") + "-fictional-profile-" + page.Name[^8..]);
        for (int i = 0; i < 20 && Directory.Exists(profile); i++) { try { Directory.Delete(profile, true); } catch (IOException) { await Task.Delay(500); } catch (UnauthorizedAccessException) { await Task.Delay(500); } }
    }

    static (StateStore Store, Whisper Whisper, LocalTextModel Text, LivePreview Preview, Capsule Capsule, HwndSource Owner, string Directory) Rig(string label)
    {
        string directory = Path.Combine(root, label + "-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        var store = new StateStore(directory); store.Preferences.Language = "en"; store.Preferences.LiveTextMode = LiveTextModes.TypeInApp; store.Preferences.CopyDictationToClipboard = false;
        var recorder = new DiagnosticRecorder { Compact = InsertionLog.Append }; Diagnostics.Recorder = recorder;
        return (store, new Whisper(directory, PackageAssets), new LocalTextModel(directory, PackageAssets), new LivePreview(store), new Capsule(store),
            new HwndSource(new HwndSourceParameters("pFlow fictional " + label + " owner") { Width = 10, Height = 10 }), directory);
    }

    static async Task ChromeLive()
    {
        var rig = Rig("chrome-live");
        try {
            await rig.Whisper.Prewarm();
            Console.WriteLine($"CHROME LIVE engine '{rig.Whisper.EngineDescription}'");
            string prefix = "Fictional prefix.";
            foreach (var (browser, variant) in new[] { ("edge", "body"), ("edge", "textarea"), ("edge", "input"), ("edge", "password"), ("chrome", "body") }) {
                var page = await OpenPage(browser, variant, variant == "password" ? "" : prefix);
                try {
                    foreach (string temperature in new[] { "cold", "warm" }) {
                        if (temperature == "warm") { Front(page.Window); await Task.Delay(500); }
                        string before = Title(page.Window);
                        string take = $"{browser}-{variant}-{temperature}";
                        TypeResult r;
                        try { r = await TypeTake(take, "medium-1.wav", rig.Whisper, rig.Store, rig.Text, rig.Preview, rig.Capsule, rig.Owner.Handle, rig.Directory, browser == "chrome" ? "chrome" : "msedge"); }
                        catch (InvalidOperationException error) when (variant == "password") {
                            // A password box pFlow can see refuses the take at its start, as Program does (no recording, nothing typed).
                            Diagnostics.Recorder.EndTake(new DiagField("result", "could not start"), new DiagField("reason", PrivateLog.Reason(error)));
                            Console.WriteLine($"CHROME LIVE {take}: refused at the start: {error.Message} shown={Title(page.Window)[(page.Name.Length + 3)..]}");
                            Check(take + ": a visible password box refuses the take and gets nothing", Title(page.Window).EndsWith("len:0", StringComparison.Ordinal));
                            continue;
                        }
                        await Task.Delay(600);
                        string title = Title(page.Window), shown = title.Length > page.Name.Length + 3 ? title[(page.Name.Length + 3)..] : "";
                        string beforeShown = before.Length > page.Name.Length + 3 ? before[(page.Name.Length + 3)..] : "";
                        string expected = variant == "password" ? "" : Flat(Flat(beforeShown) + " " + r.Final);
                        bool exact = variant != "password" && Flat(shown) == expected;
                        // New copies of the finished text's start: this take's, once (a warm take's field already holds the cold take's words).
                        int copies = r.Final.Length > 20 ? Occurrences(Flat(shown), Flat(r.Final)[..20]) - Occurrences(Flat(before), Flat(r.Final)[..20]) : -1;
                        Console.WriteLine($"CHROME LIVE {take}: writes={r.Writes} matched={r.Matched} firstWrite={r.FirstWriteMs:F0}ms late={r.LateBegin} refused={r.Refused ?? "-"} field=[{r.FieldWhy}] stops={string.Join(",", r.Stops)} windows={r.Report.Windows} firstWords={r.Report.FirstUpdateMs:F0}ms final={r.Report.FinalMs:F0}ms status=[{r.Status}] exact={exact} copies={copies} shown={shown.Length} chars");
                        if (variant == "password") {
                            Check(take + ": no live writes into a password field", r.Writes == 0 && !r.Typed);
                            Check(take + ": the password box got nothing it could see", shown == "len:0" || r.Status.StartsWith(InsertionTarget.Unchecked, StringComparison.Ordinal));
                            continue;
                        }
                        if (temperature == "cold" && r.Refused != null && !r.LateBegin && r.Status.StartsWith(InsertionTarget.Unchecked, StringComparison.Ordinal)) {
                            // A cold browser whose page tree never built during the take (its placeholder pane stayed to the end):
                            // nothing could be read, so no live words; the finished words went in unchecked, as before 0.1.27.
                            Console.WriteLine($"CHROME LIVE {take}: the placeholder pane never gave way during the take: no live typing possible (as in 0.1.26)");
                            Check(take + ": with the pane never giving way, nothing was typed live and the finished words arrived once", r.Writes == 0 && Flat(shown).EndsWith(Flat(r.Final).Replace("\n", " "), StringComparison.Ordinal));
                            continue;
                        }
                        Check($"{take}: live words reached the field before the take ended ({r.Matched} writes read back, first at {r.FirstWriteMs:F0} ms)",
                            r.Matched > 0 && r.FirstWriteMs > 0 && r.FirstWriteMs < r.Report.AudioEndMs);
                        Check($"{take}: every live write read back right, and typing stopped only for a revised word", r.Matched == r.Writes && r.Stops.All(stop => stop == LiveStop.Revised));
                        // Append only: the finished text is added when it starts with exactly the typed words; otherwise the field keeps the
                        // typed words, nothing is added or removed, and the Copy card offers the finished text.
                        if (r.Status == "Inserted") Check($"{take}: the finished text is in the field exactly once, after the prefix", exact && copies == 1);
                        else Check($"{take}: the finished text did not start with the typed words: the field keeps them, no duplicate, Copy card ({r.Status})",
                            r.Status.StartsWith("Live typing stopped because", StringComparison.Ordinal) && copies <= 1 && Flat(shown).StartsWith(Flat(beforeShown), StringComparison.Ordinal) && Flat(shown).Length > Flat(beforeShown).Length);
                    }
                } finally { await ClosePage(browser, page); }
            }
        } finally { rig.Preview.Close(); rig.Capsule.Close(); rig.Owner.Dispose(); await rig.Whisper.DisposeAsync(); try { Directory.Delete(rig.Directory, true); } catch (IOException) { } }
    }

    static async Task DiagTakes()
    {
        var rig = Rig("diag");
        string? notepadName = null; AutomationElement? notepad = null;
        try {
            await rig.Whisper.Prewarm();
            // Notepad: our own fictional file, caret at the end.
            notepadName = "pflow-fictional-diag-" + Guid.NewGuid().ToString("N"); string file = Path.Combine(rig.Directory, notepadName + ".txt");
            File.WriteAllText(file, "Fictional prefix. ");
            var start = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; start.ArgumentList.Add(file); Process.Start(start);
            notepad = await WindowWith(notepadName); var edit = await Editor(notepad);
            await Place(notepad, edit); End(edit);
            var n = await TypeTake("diag-notepad", "medium-1.wav", rig.Whisper, rig.Store, rig.Text, rig.Preview, rig.Capsule, rig.Owner.Handle, rig.Directory, "Notepad");
            Console.WriteLine($"DIAG notepad: writes={n.Writes} matched={n.Matched} firstWrite={n.FirstWriteMs:F0}ms stops={string.Join(",", n.Stops)} status=[{n.Status}]");
            Check("Notepad: live words typed and read back", n.Matched > 0 && n.Status == "Inserted");
            await CloseOurNotepadTab(notepad, notepadName); notepad = null;
            // Edge, warm: a first capture builds the tree, then the take.
            var page = await OpenPage("edge", "body", "Fictional prefix.");
            try {
                try { _ = InsertionTarget.Capture(); } catch (InvalidOperationException) { }
                await Task.Delay(1500);
                for (int i = 0; i < 5 && Native.GetForegroundWindow() != page.Window; i++) {
                    Front(page.Window); await Task.Delay(300);
                    if (Native.GetForegroundWindow() != page.Window) { try { AutomationElement.FromHandle(page.Window).SetFocus(); } catch (InvalidOperationException) { } await Task.Delay(500); }
                }
                var e = await TypeTake("diag-edge", "medium-1.wav", rig.Whisper, rig.Store, rig.Text, rig.Preview, rig.Capsule, rig.Owner.Handle, rig.Directory, "msedge");
                Console.WriteLine($"DIAG edge: writes={e.Writes} matched={e.Matched} firstWrite={e.FirstWriteMs:F0}ms late={e.LateBegin} stops={string.Join(",", e.Stops)} status=[{e.Status}]");
            } finally { await ClosePage("edge", page); }
            // The report as the button builds it, saved next to the harness (the button saves to the Desktop).
            string report = Diagnostics.Recorder.Report(DiagnosticEnvironment.Collect(rig.Whisper, rig.Store, rig.Store.Preferences.ActivationKey));
            string saved = Path.Combine(root, "diag-report-" + RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant() + ".txt"); File.WriteAllText(saved, report);
            Console.WriteLine("DIAG report " + report.Length + " chars, " + report.Split('\n').Length + " lines");
            foreach (string line in report.Split('\n').Where(l => Regex.IsMatch(l, @"^(cpu|engine|model|pflow|windows|power|settings)\.|take\.start|typing\.(begin|field|stop|final)|capture\.detail|live\.(stop|tooSlow)|worker\.start")).Take(40)) Console.WriteLine("DIAG> " + line.TrimEnd());
            foreach (string line in report.Split('\n').Where(l => l.Contains(" live.window ") || l.Contains(" typing.write ")).Take(6)) Console.WriteLine("DIAG> " + line.TrimEnd());
            Check("the report has the environment, both takes, live windows and typing writes",
                report.Contains("cpu.name:") && report.Contains("model.liveReady:") && Regex.Matches(report, @"\[take \d+").Count == 2 && report.Contains(" live.window ") && report.Contains(" typing.write ") && report.Contains(" worker.start "));
            string user = Environment.UserName, machine = Environment.MachineName;
            Check("the report holds no fixture word, path, account or computer name",
                !FixtureWords.Any(word => Regex.IsMatch(report, @"\b" + word + @"\b", RegexOptions.IgnoreCase)) && !report.Contains(@":\") && !report.Contains(@"\Users")
                && !Regex.IsMatch(report, @"\b" + Regex.Escape(user) + @"\b") && !report.Contains(machine, StringComparison.OrdinalIgnoreCase) && !report.Contains("pflow-fictional"));
        } finally {
            if (notepad != null && notepadName != null) await CloseOurNotepadTab(notepad, notepadName);
            rig.Preview.Close(); rig.Capsule.Close(); rig.Owner.Dispose(); await rig.Whisper.DisposeAsync(); try { Directory.Delete(rig.Directory, true); } catch (IOException) { }
        }
    }

    /// --chrome-live-guard: the review's unsafe moments, each made to happen at the worst time (just before a
    /// key batch, through LiveKeyField.BeforeSend): another window in front, a password box focused on the same
    /// page, the person typing, a composing input language, a page too slow to read back. Never a key where
    /// it was not meant to go; typing stops for the take; nothing half-typed.
    static async Task ChromeGuard()
    {
        string directory = Path.Combine(root, "guard-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        string noteName = "pflow-fictional-guard-" + Guid.NewGuid().ToString("N"), note = Path.Combine(directory, noteName + ".txt");
        File.WriteAllText(note, "Fictional other window. ");
        var startNote = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; startNote.ArgumentList.Add(note); Process.Start(startNote);
        var notepad = await WindowWith(noteName); var edit = await Editor(notepad);
        string noteBefore = Read(edit); IntPtr noteWindow = (IntPtr)notepad.Current.NativeWindowHandle;
        try {
            foreach (string slow in new[] { "", "slow" }) {
                var page = await OpenPage("edge", slow == "slow" ? "slow" : "guard", "Fictional prefix.", accessible: true);
                try {
                    // Never WindowWith here: it focuses the window itself, which moves the keyboard focus off the page's field.
                    var window = AutomationElement.FromHandle(page.Window);
                    Console.WriteLine($"GUARD page: Edge in front={Native.GetForegroundWindow() == page.Window}");
                    AutomationElement Find(string name)
                    {
                        for (int i = 0; i < 100; i++) {
                            // By name, or (names can lag in a cold tree) the page's text box or its password box.
                            var e = window.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, name))
                                ?? window.FindFirst(TreeScope.Descendants, new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
                                    new PropertyCondition(AutomationElement.IsPasswordProperty, name == "Fictional secret")));
                            if (e != null) return e;
                            // A cold Edge builds its tree only when knocked: the app's own capture knocks.
                            if (i % 10 == 0) { try { _ = InsertionTarget.Capture(); } catch (InvalidOperationException) { } }
                            Thread.Sleep(100);
                        }
                        var all = window.FindAll(TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition);
                        Console.WriteLine($"GUARD tree: {all.Count} elements; " + string.Join("; ", all.Cast<AutomationElement>().Take(30).Select(e => e.Current.ControlType.ProgrammaticName.Replace("ControlType.", "") + "[" + e.Current.Name + "]")));
                        throw new Exception("FAIL: Edge exposes " + name);
                    }

                    string Shown() { string t = Title(page.Window); int bar = t.IndexOf(" | ", StringComparison.Ordinal), pw = t.LastIndexOf(" | pw len:", StringComparison.Ordinal); return bar < 0 ? "" : pw > bar ? t[(bar + 3)..pw] : t[(bar + 3)..]; }
                    async Task<(LiveInlineSlot Slot, string Before)> Begin(string take)
                    {
                        LiveKeyField.BeforeSend = null; LiveKeyField.AfterLookup = null;
                        for (int i = 0; i < 5 && Native.GetForegroundWindow() != page.Window; i++) { Front(page.Window); await Task.Delay(300); }
                        // A click in the page's text box, then Ctrl+End: the caret at the end of its text, as a person would put it.
                        var bodyField = Find("Fictional body"); var box = bodyField.Current.BoundingRectangle;
                        Console.WriteLine($"GUARD {take}: body {bodyField.Current.ControlType.ProgrammaticName} [{bodyField.Current.Name}] at {box}");
                        GetPhysicalCursorPos(out var previous); SetPhysicalCursorPos((int)(box.Left + box.Width / 2), (int)(box.Top + box.Height / 2));
                        Native.Send(new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 2 } } }, new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 4 } } });
                        await Task.Delay(300); SetPhysicalCursorPos(previous.X, previous.Y);
                        Native.Send(Native.Key(0x11), Native.Key(0x23, extended: true), Native.Key(0x23, true, true), Native.Key(0x11, true)); await Task.Delay(300);
                        InsertionTarget target = InsertionTarget.Capture();
                        for (int i = 0; i < 20 && !target.CanInsert || i < 20 && target.Placeholder; i++) { await Task.Delay(250); target = InsertionTarget.Capture(); }
                        Console.WriteLine($"GUARD {take}: captured {target.Kind} placeholder={target.Placeholder}");
                        var slot = new LiveInlineSlot();
                        var field = target.LiveField(out string why);
                        Check($"{take}: typing begins in the Edge body ({why})", field is LiveKeyField && slot.Begin(take, field) == null);
                        string before = Shown();
                        slot.Reconcile(take, "harbor lights"); slot.Reconcile(take, "harbor lights glow");
                        await Task.Delay(200);
                        Check($"{take}: the first settled words are typed", Flat(Shown()) == Flat(before + " harbor lights") || Flat(Shown()) == Flat(before + "harbor lights"));
                        return (slot, Shown());
                    }
                    if (slow == "slow") {
                        // The page takes 400 ms per typed character: the read-back cannot confirm in time.
                        var (slot, before) = await Begin("slow");
                        var stop = slot.Reconcile("slow", "harbor lights glow over the quiet water tonight");
                        stop ??= slot.Reconcile("slow", "harbor lights glow over the quiet water tonight again");
                        await Task.Delay(30_000);
                        string after = Flat(Shown()); string added = after.Length >= Flat(before).Length ? after[Flat(before).Length..].Trim() : "";
                        Console.WriteLine($"GUARD slow: stop={stop} added=[{added}]");
                        const string spoken = "glow over the quiet water tonight";
                        Check($"slow read-back: typing stops ({stop}) and the one write lands whole, no half word", stop == LiveStop.Uncertain && spoken.StartsWith(added, StringComparison.Ordinal)
                            && (added.Length == spoken.Length || spoken[added.Length] == ' '));
                        Check("slow read-back: nothing more is typed for the take", slot.Reconcile("slow", "harbor lights glow over the quiet water tonight again and again") == null && Flat(Shown()) == after);
                        continue;
                    }
                    // 1. Another window comes to the front just before the key batch.
                    {
                        var (slot, before) = await Begin("away");
                        LiveKeyField.BeforeSend = () => { Front(noteWindow); Thread.Sleep(300); };
                        var stop = slot.Reconcile("away", "harbor lights glow over");
                        stop ??= slot.Reconcile("away", "harbor lights glow over water");
                        LiveKeyField.BeforeSend = null; await Task.Delay(500);
                        Check($"another window in front: no key reaches it, typing stops ({stop})", Read(edit) == noteBefore && stop != null && Shown() == before);
                    }
                    // 1b. The window is switched during the slow UI Automation lookup, after the field checks passed:
                    // the fast checks run last, so no key goes to the window now in front.
                    {
                        var (slot, before) = await Begin("away-lookup");
                        IntPtr sawFront = IntPtr.Zero;
                        LiveKeyField.AfterLookup = () => { Front(noteWindow); Thread.Sleep(300); sawFront = Native.GetForegroundWindow(); };
                        var stop = slot.Reconcile("away-lookup", "harbor lights glow over");
                        stop ??= slot.Reconcile("away-lookup", "harbor lights glow over water");
                        LiveKeyField.AfterLookup = null; await Task.Delay(500);
                        Console.WriteLine($"GUARD away-lookup: front after the lookup={(sawFront == noteWindow ? "Notepad" : "other")} notepad changed={Read(edit) != noteBefore} stop={stop}");
                        // Positive control: a key sent the same way now does reach Notepad (then it is taken out again).
                        Front(noteWindow); await Task.Delay(300); Native.Send(Native.UnicodeText("Z")); await Task.Delay(400);
                        bool probe = Read(edit) != noteBefore; if (probe) { Native.Send(Native.Key(0x08), Native.Key(0x08, true)); await Task.Delay(300); }
                        Check("positive control: a key sent to Notepad in front does land there (so 'no key reached it' means something)", probe);
                        Check($"a window switched during the field lookup gets no key, typing stops ({stop})", sawFront == noteWindow && Read(edit) == noteBefore && stop != null && Flat(Shown()) == Flat(before));
                    }
                    // 1c. Recognition revises a word pFlow already typed: live typing ends with no key at all (no
                    // selection, no Backspace); at the end, finished text that starts with exactly the typed words is
                    // only appended, anything else leaves the field as it is (the Copy card offers the text).
                    {
                        var (slot, before) = await Begin("revised");
                        var stop = slot.Reconcile("revised", "harbor lighthouse keeper waves");
                        stop ??= slot.Reconcile("revised", "harbor lighthouse keeper waves again");
                        await Task.Delay(400);
                        var sel = ((TextPattern)AutomationElement.FocusedElement.GetCurrentPattern(TextPattern.Pattern)).GetSelection();
                        bool caret = sel.Length == 1 && sel[0].GetText(-1).Length == 0;
                        Check($"a revised word ends live typing with nothing sent: field unchanged, no selection ({stop})", stop == LiveStop.Revised && Shown() == before && caret);
                        var (final, finalStop) = slot.Finalize("revised", "Harbor lighthouse keeper waves.");
                        await Task.Delay(400);
                        Check($"finished text that does not start with the typed words leaves the field as it is ({final}, {finalStop})", final == LiveFinal.Kept && Shown() == before);
                    }
                    {
                        var (slot, before) = await Begin("revised-append");
                        var stop = slot.Reconcile("revised-append", "harbor lighthouse keeper");
                        var (final, _) = slot.Finalize("revised-append", "harbor lights glow tonight.");
                        await Task.Delay(400);
                        Check($"finished text that starts with exactly the typed words is appended after them ({stop}, {final})", stop == LiveStop.Revised && final == LiveFinal.Applied && Flat(Shown()) == Flat(before + " glow tonight."));
                    }
                    // 3. The person presses a real key (a letter, held down) between pFlow's checks: the last, fast check
                    // sees it, typing stops, and pFlow's batch never mixes with the person's typing.
                    {
                        var (slot, before) = await Begin("person");
                        LiveKeyField.AfterLookup = () => { Native.Send(Native.Key(0x51)); Thread.Sleep(200); };
                        var stop = slot.Reconcile("person", "harbor lights glow over");
                        stop ??= slot.Reconcile("person", "harbor lights glow over water");
                        LiveKeyField.AfterLookup = null; Native.Send(Native.Key(0x51, true)); await Task.Delay(800);
                        string after = Flat(Shown());
                        Console.WriteLine($"GUARD person: stop={stop} shown=[{after[Math.Max(0, after.Length - 40)..]}]");
                        Check($"the person typing: typing stops ({stop}) and the field holds only their key, no pFlow words after it", stop != null && after == Flat(before + "q"));
                        Check("the person typing: nothing more is typed for the take", slot.Reconcile("person", "harbor lights glow over water and more words") == null && Flat(Shown()) == after);
                    }
                    // 2. A password box on the same page takes focus just before the key batch.
                    {
                        var (slot, before) = await Begin("password");
                        var secret = Find("Fictional secret");
                        bool secretFocused = false;
                        LiveKeyField.BeforeSend = () => { try { secret.SetFocus(); } catch (InvalidOperationException) { Native.Send(Native.Key(0x09), Native.Key(0x09, true)); } Thread.Sleep(300);
                            try { secretFocused = AutomationElement.FocusedElement.Current.IsPassword; } catch (Exception) { } };
                        var stop = slot.Reconcile("password", "harbor lights glow over");
                        stop ??= slot.Reconcile("password", "harbor lights glow over water");
                        LiveKeyField.BeforeSend = null; await Task.Delay(500);
                        bool untouched = Title(page.Window).Contains("pw len:0");
                        try { secret.SetFocus(); } catch (InvalidOperationException) { } await Task.Delay(300); Native.Send(Native.UnicodeText("Z")); await Task.Delay(500);
                        bool probe = Title(page.Window).Contains("pw len:1"); if (probe) { Native.Send(Native.Key(0x08), Native.Key(0x08, true)); await Task.Delay(300); }
                        Console.WriteLine($"GUARD password probe: a key sent to the focused password box lands there={probe}");
                        Console.WriteLine($"GUARD password: guard=[{Diagnostics.Recorder.Report([]).Split('\n').LastOrDefault(l => l.Contains("typing.guard"))?.Trim()}]");
                        Console.WriteLine($"GUARD password: focused before the batch={secretFocused} title tail=[{Title(page.Window)[^10..]}] stop={stop}");
                        Check($"a password box focused mid-take: it gets no key, typing stops ({stop})", secretFocused && untouched && stop != null && Shown() == before);
                        Check("positive control: a key sent to the focused password box does land there", probe);
                    }
                    // 4. A composing input language (Japanese) becomes active in Edge just before the batch.
                    {
                        IntPtr japanese = LoadKeyboardLayout("00000411", 0);
                        uint thread = Native.GetWindowThreadProcessId(page.Window, out _);
                        var (slot, before) = await Begin("ime");
                        LiveKeyField.BeforeSend = () => { PostMessage(page.Window, 0x0050, IntPtr.Zero, japanese); Thread.Sleep(500); };
                        var stop = slot.Reconcile("ime", "harbor lights glow over");
                        stop ??= slot.Reconcile("ime", "harbor lights glow over water");
                        LiveKeyField.BeforeSend = null;
                        bool switched = (GetKeyboardLayout(thread).ToInt64() & 0xFFFF) == 0x0411;
                        Console.WriteLine($"GUARD ime: layout switched={switched} stop={stop}");
                        // Not switching is a failure, never a NOT RUN.
                        Check("Edge took the Japanese layout for the check", switched);
                        {
                            Check($"a composing input language: typing stops ({stop}) with nothing typed", stop != null && Shown() == before);
                            var target = InsertionTarget.Capture(); target.LiveField(out string why);
                            Check($"a composing input language at take start: no key typing ({why})", why.Contains("input method"));
                        }
                        PostMessage(page.Window, 0x0050, IntPtr.Zero, LoadKeyboardLayout("00000409", 0)); await Task.Delay(500);
                        // The Japanese layout leaves the session's list again.
                        UnloadKeyboardLayout(japanese);
                    }
                } finally { LiveKeyField.BeforeSend = null; LiveKeyField.AfterLookup = null; await ClosePage("edge", page); }
            }
        } finally { await CloseOurNotepadTab(notepad, noteName); try { Directory.Delete(directory, true); } catch (IOException) { } }
    }
    /// `part` is empty or the first whole words of `spoken` (never half a word).
    static bool WholeWords(string part, string spoken) => part.Length == 0 || spoken.StartsWith(part, StringComparison.Ordinal) && (part.Length == spoken.Length || spoken[part.Length] == ' ');
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadKeyboardLayout(string id, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] static extern bool UnloadKeyboardLayout(IntPtr layout);

    static async Task ReportButton()
    {
        string directory = Path.Combine(root, "report-button-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        var (desktop, place) = DiagnosticEnvironment.ReportFolder();
        string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        Console.WriteLine($"REPORT folder: {place}");
        Check("reports go to the ordinary local Downloads folder or pFlow's own Reports folder", place == "pFlow's Reports folder" || DiagnosticEnvironment.LocalDownloads(desktop, profile));
        Check("Downloads under OneDrive, Dropbox, a network share or moved elsewhere is not used", !DiagnosticEnvironment.LocalDownloads(Path.Combine(profile, "OneDrive", "Downloads"), profile)
            && !DiagnosticEnvironment.LocalDownloads(@"\\fictional-server\share\Downloads", profile) && !DiagnosticEnvironment.LocalDownloads(@"D:\Elsewhere\Downloads", profile)
            && !DiagnosticEnvironment.LocalDownloads(Path.Combine(profile, "Dropbox", "Downloads"), profile));
        Directory.CreateDirectory(desktop);
        var explorersBefore = Explorers();
        try {
            foreach (string theme in new[] { "light", "dark" })
            foreach (double width in new[] { 420.0, 900.0 }) {
                var store = new StateStore(directory); store.Preferences.Theme = theme; store.Preferences.LiveTextMode = LiveTextModes.TypeInApp;
                var whisper = new Whisper(directory, PackageAssets);
                using var hook = new KeyboardHook(_ => { }) { Enabled = false };
                var settings = new SettingsWindow(store, whisper, new LocalTextModel(directory, PackageAssets), hook, () => { }, () => false) { Width = width, Height = 760 };
                try {
                    settings.Show(); settings.Activate(); await Task.Delay(400);
                    var page = Descendants<System.Windows.Controls.ScrollViewer>(settings).First(x => x.Content is System.Windows.Controls.StackPanel);
                    var heading = Descendants<System.Windows.Controls.TextBlock>(settings).First(t => t.Text == "TROUBLESHOOTING");
                    page.ScrollToVerticalOffset(page.VerticalOffset + heading.TranslatePoint(new System.Windows.Point(0, 0), page).Y - 12); settings.UpdateLayout(); await Task.Delay(300);
                    var window = AutomationElement.FromHandle(new WindowInteropHelper(settings).Handle);
                    var button = window.FindFirst(TreeScope.Descendants, new AndCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button), new PropertyCondition(AutomationElement.NameProperty, DiagnosticReport.ButtonLabel)));
                    Check($"{theme} {width:F0}: the button is there for UI Automation", button != null);
                    var files = Directory.GetFiles(desktop, "pFlow diagnostic report *.txt").ToHashSet();
                    ((InvokePattern)button!.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
                    string? saved = null;
                    for (int i = 0; i < 50 && saved == null; i++) { await Task.Delay(100); saved = Directory.GetFiles(desktop, "pFlow diagnostic report *.txt").FirstOrDefault(f => !files.Contains(f)); }
                    await Task.Delay(500);
                    var status = Descendants<System.Windows.Controls.TextBlock>(settings).FirstOrDefault(t => t.Text.StartsWith("Saved in " + place + ": ", StringComparison.Ordinal));
                    Check($"{theme} {width:F0}: the report file is in {place} with the expected name, and the line under the button names it",
                        saved != null && File.Exists(saved) && Regex.IsMatch(Path.GetFileName(saved), @"^pFlow diagnostic report \d{4}-\d{2}-\d{2} \d{6}\.txt$")
                        && status != null && status.IsVisible && status.Text.EndsWith(Path.GetFileName(saved), StringComparison.Ordinal)
                        && Descendants<System.Windows.Controls.TextBlock>(settings).Any(t => t.Text == DiagnosticReport.Explanation && t.Text.Contains(place)));
                    string report = File.ReadAllText(saved!);
                    Console.WriteLine($"REPORT checks: cpu={report.Contains("cpu.name:")} live={report.Contains("settings.liveText: type")} drive={report.Contains(@":\")} user[{Environment.UserName}]={Regex.IsMatch(report, @"\b" + Regex.Escape(Environment.UserName) + @"\b")} machine={report.Contains(Environment.MachineName, StringComparison.OrdinalIgnoreCase)}");
                    Check($"{theme} {width:F0}: the saved report has the PC's facts and nothing private ({report.Length} chars)", report.Contains("cpu.name:") && report.Contains("settings.liveText: type")
                        && !report.Contains(@":\") && !Regex.IsMatch(report, @"\b" + Regex.Escape(Environment.UserName) + @"\b") && !report.Contains(Environment.MachineName, StringComparison.OrdinalIgnoreCase));
                    if (theme == "light" && width == 420) File.Copy(saved!, Path.Combine(root, "report-button-sample.txt"), true);
                    File.Delete(saved!);
                    ShootWindow(settings, Path.Combine(root, $"troubleshooting-clicked-{theme}-{width:F0}.png"), theme == "light");
                } finally { settings.Close(); await whisper.DisposeAsync(); }
            }
            // The File Explorer windows the button opened on the reports are closed again.
            var opened = Explorers().Except(explorersBefore).ToList();
            Console.WriteLine($"REPORT explorer windows opened: {opened.Count}");
            foreach (var window in opened) PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero);
        } finally { try { Directory.Delete(directory, true); } catch (IOException) { } }
    }
    static HashSet<IntPtr> Explorers()
    {
        var found = new HashSet<IntPtr>();
        EnumWindows((window, _) => { if (LiveTextField.ClassName(window) == "CabinetWClass") found.Add(window); return true; }, IntPtr.Zero);
        return found;
    }
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    static void ShootWindow(System.Windows.Window window, string path, bool light)
    {
        var content = (System.Windows.FrameworkElement)window.Content;
        int width = (int)Math.Ceiling(content.ActualWidth), height = (int)Math.Ceiling(content.ActualHeight);
        var scene = new System.Windows.Media.DrawingVisual();
        using (var dc = scene.RenderOpen()) {
            dc.DrawRectangle(new System.Windows.Media.SolidColorBrush(light ? System.Windows.Media.Color.FromRgb(0xF0, 0xF0, 0xF0) : System.Windows.Media.Color.FromRgb(0x20, 0x20, 0x24)), null, new System.Windows.Rect(0, 0, width, height));
            dc.DrawRectangle(new System.Windows.Media.VisualBrush(content) { Stretch = System.Windows.Media.Stretch.None }, null, new System.Windows.Rect(0, 0, width, height));
        }
        var shot = new System.Windows.Media.Imaging.RenderTargetBitmap(width * 2, height * 2, 192, 192, System.Windows.Media.PixelFormats.Pbgra32); shot.Render(scene);
        var png = new System.Windows.Media.Imaging.PngBitmapEncoder(); png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(shot));
        using var file = File.Create(path); png.Save(file);
    }

    /// Hypothesis (a): a starved speech worker. pFlow's process (and so its worker) is held to fewer processors
    /// (PFLOW_SLOW_CORES, default 2) and Notepad takes run with the 0.1.26 thread rule (counts for every
    /// processor) and the 0.1.27 rule (counts for the processors Windows allows).
    static async Task SlowLive()
    {
        var rig = Rig("slow-live");
        string name = "pflow-fictional-slow-" + Guid.NewGuid().ToString("N"); AutomationElement? notepad = null;
        var self = Process.GetCurrentProcess(); var all = self.ProcessorAffinity;
        try {
            string file = Path.Combine(rig.Directory, name + ".txt"); File.WriteAllText(file, "Fictional prefix. ");
            var start = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; start.ArgumentList.Add(file); Process.Start(start);
            notepad = await WindowWith(name); var edit = await Editor(notepad);
            foreach (string cores in (Environment.GetEnvironmentVariable("PFLOW_SLOW_CORES") ?? "2").Split(','))
            foreach (string rule in new[] { "0.1.26", "0.1.27" }) {
                self.ProcessorAffinity = (IntPtr)((1L << int.Parse(cores)) - 1);
                if (rule == "0.1.26") SpeechWorker.LogicalProcessors = Environment.ProcessorCount; else SpeechWorker.UseUsableProcessors();
                await using var whisper = new Whisper(rig.Directory, PackageAssets);
                await whisper.Prewarm();
                Console.WriteLine($"SLOW cores={cores} rule={rule}: worker threads {SpeechThreads.Final(SpeechWorker.LogicalProcessors)} final / {SpeechThreads.Live(SpeechWorker.LogicalProcessors)} live, affinity 0x{self.ProcessorAffinity.ToInt64():x}");
                await Place(notepad, edit); End(edit);
                var r = await TypeTake("slow-" + cores + "-" + rule, "medium-1.wav", whisper, rig.Store, rig.Text, rig.Preview, rig.Capsule, rig.Owner.Handle, rig.Directory, "Notepad");
                var windows = r.Section.Split('\n').Where(l => l.Contains(" live.window ")).ToList();
                var took = windows.Select(l => Regex.Match(l, @"tookMs=(-?\d+)")).Where(m => m.Success).Select(m => m.Groups[1].Value).ToList();
                var cpu = windows.Select(l => Regex.Match(l, @"workerCpuMs=(-?[\d.]+)")).Where(m => m.Success).Select(m => m.Groups[1].Value).ToList();
                Console.WriteLine($"SLOW cores={cores} rule={rule}: windows={windows.Count} slow={windows.Count(l => l.Contains(" slow=yes"))} tooSlow={r.Section.Contains("live.tooSlow")} firstWords={r.Report.FirstUpdateMs:F0}ms updates={r.Report.UpdatesBeforeEnd} writes={r.Matched} firstWrite={r.FirstWriteMs:F0}ms took=[{string.Join(",", took)}] workerCpu=[{string.Join(",", cpu)}] final={r.Report.FinalMs:F0}ms status=[{r.Status}]");
                if (rule == "0.1.27") Check($"cores={cores}, 0.1.27 rule: live words reach Notepad ({r.Matched} writes) and the take is inserted", r.Matched > 0 && r.Status == "Inserted");
            }
        } finally {
            self.ProcessorAffinity = all; SpeechWorker.UseUsableProcessors();
            if (notepad != null) await CloseOurNotepadTab(notepad, name);
            rig.Preview.Close(); rig.Capsule.Close(); rig.Owner.Dispose(); await rig.Whisper.DisposeAsync(); try { Directory.Delete(rig.Directory, true); } catch (IOException) { }
        }
    }
}
