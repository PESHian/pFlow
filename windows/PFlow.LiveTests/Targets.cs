using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Interop;
using PFlow.Core;
using PFlow.Windows;

// Real targets the owner uses: a finger on the recording control, and Chromium fields
// (Gmail's compose body is a contenteditable with role=textbox). Fictional text only.
internal static partial class Program
{
    [DllImport("user32.dll")] static extern IntPtr GetFocus();
    [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo { public int Size, Flags; public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret; public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId, ref Guid iid, out IntPtr accessible);
    /// The classic screen-reader knock: WM_GETOBJECT with OBJID_CLIENT on the focused window.
    static string MsaaNudge(IntPtr window)
    {
        uint thread = Native.GetWindowThreadProcessId(window, out _);
        var info = new GuiThreadInfo { Size = Marshal.SizeOf<GuiThreadInfo>() };
        if (!GetGUIThreadInfo(thread, ref info)) return "no thread info";
        var iid = new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");
        int result = AccessibleObjectFromWindow(info.Focus, 0xFFFFFFFC, ref iid, out IntPtr accessible);
        if (accessible != IntPtr.Zero) Marshal.Release(accessible);
        return $"focus hwnd {info.Focus} ({LiveTextField.ClassName(info.Focus)}) hr=0x{result:X}";
    }
    /// PFLOW_EDGE_PROFILE=old reuses the fixture profile of earlier rounds; otherwise a fresh one per run.
    static string EdgeProfile(string name) => Environment.GetEnvironmentVariable("PFLOW_EDGE_PROFILE") == "old" ? "edge-fictional-profile" : "edge-fictional-profile-" + name[^8..];
    static string Show(string text) => Normalize(text).Replace("\n", "\\n") + " (" + text.Length + ")";

    /// --touch-capsule: a finger tap on the production recording control must not take
    /// the keyboard focus away from the app being dictated into (WS_EX_NOACTIVATE covers
    /// the mouse; touch asks the window through WM_POINTERACTIVATE).
    static async Task TouchCapsule()
    {
        string directory = Path.Combine(root, "touch-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        string name = "pflow-fictional-touch-" + Guid.NewGuid().ToString("N"), file = Path.Combine(directory, name + ".txt");
        File.WriteAllText(file, "Fictional prefix. ");
        var start = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; start.ArgumentList.Add(file); Process.Start(start);
        var notepad = await WindowWith(name); var edit = await Editor(notepad); await Focus(notepad, edit); End(edit);
        IntPtr notepadHandle = (IntPtr)notepad.Current.NativeWindowHandle;
        var store = new StateStore(directory);
        var capsule = new Capsule(store) { AudioLevel = () => 0.5 };
        var messages = new List<string>();
        capsule.ToggleRecording += () => messages.Add("CLICK");
        try {
            capsule.Set(Phase.Recording); await Task.Delay(400); await System.Windows.Threading.Dispatcher.Yield(System.Windows.Threading.DispatcherPriority.Background);
            HwndSource.FromHwnd(capsule.Handle)?.AddHook((IntPtr hwnd, int msg, IntPtr wp, IntPtr lp, ref bool handled) => {
                if (msg is 0x21 or 0x24B or 0x06 or 0x07 or 0x86 or 0x246 or 0x247 or 0x240 or 0x201 or 0x202) messages.Add($"0x{msg:X}");
                return IntPtr.Zero;
            });
            Check("capsule visible for the tap", capsule.IsVisible && Native.GetWindowRect(capsule.Handle, out var bounds) && bounds.Right > bounds.Left);
            Native.GetWindowRect(capsule.Handle, out var rect);
            int x = (rect.Left + rect.Right) / 2, y = (rect.Top + rect.Bottom) / 2;
            Check("Notepad is in front before the tap", Native.GetForegroundWindow() == notepadHandle);
            bool ready = InitializeTouchInjection(1, 1);
            Console.WriteLine($"TOUCH InitializeTouchInjection={ready} error {Marshal.GetLastWin32Error()}; finger at {x},{y} under {WindowFromPoint(new ScreenPoint { X = x, Y = y })} capsule {capsule.Handle}");
            if (!Touch(x, y, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT)) {
                syntheticTouch = CreateSyntheticPointerDevice(PT_TOUCH, 1, 1);
                Check("a synthetic touch device can be made", syntheticTouch != IntPtr.Zero);
                for (int wait = 0; wait < 10; wait++) { await Task.Delay(100); await System.Windows.Threading.Dispatcher.Yield(System.Windows.Threading.DispatcherPriority.Background); }
                Check("finger down on the capsule", Touch(x, y, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT));
            }
            await Task.Delay(80); Check("finger up", Touch(x, y, POINTER_FLAG_UP));
            for (int wait = 0; wait < 6; wait++) { await Task.Delay(100); await System.Windows.Threading.Dispatcher.Yield(System.Windows.Threading.DispatcherPriority.Background); }
            IntPtr foreground = Native.GetForegroundWindow();
            bool focusKept = false; string focused = "none";
            try { var now = AutomationElement.FocusedElement; focused = now?.Current.ClassName + "/" + now?.Current.Name; focusKept = now != null && now.GetRuntimeId().SequenceEqual(edit.GetRuntimeId()); } catch (Exception error) { focused = error.GetType().Name; }
            var target = InsertionTarget.Capture();
            Console.WriteLine($"TOUCH after tap: foreground={(foreground == notepadHandle ? "Notepad" : foreground == capsule.Handle ? "CAPSULE" : foreground.ToString())} focused={focused} capture.CanInsert={target.CanInsert} capsule messages: {string.Join(" ", messages)}");
            Check("a finger tap on the recording control leaves Notepad in front", foreground == notepadHandle);
            Check("a finger tap on the recording control leaves the Notepad field focused", focusKept);
            Check("the field captured after the tap can still take the text", target.CanInsert);
            // The same with the mouse, for comparison.
            messages.Clear();
            GetPhysicalCursorPos(out var previous); SetPhysicalCursorPos(x, y);
            Native.Send(new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 2 } } }, new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 4 } } });
            await Task.Delay(400); SetPhysicalCursorPos(previous.X, previous.Y);
            foreground = Native.GetForegroundWindow();
            Console.WriteLine($"MOUSE after click: foreground={(foreground == notepadHandle ? "Notepad" : foreground == capsule.Handle ? "CAPSULE" : foreground.ToString())} capsule messages: {string.Join(" ", messages)}");
            Check("a mouse click on the recording control leaves Notepad in front", foreground == notepadHandle);
        } finally {
            if (syntheticTouch != IntPtr.Zero) { DestroySyntheticPointerDevice(syntheticTouch); syntheticTouch = IntPtr.Zero; }
            capsule.Close();
            try { foreach (var p in Process.GetProcessesByName("Notepad")) if (p.MainWindowHandle == notepadHandle) p.CloseMainWindow(); } catch { }
            await Task.Delay(300); Directory.Delete(directory, true);
        }
    }

    /// --chromium-fields: Edge (Chromium) without forced accessibility, like Chrome on the
    /// owner's PC: a textarea, a single-line input and a Gmail-style contenteditable body.
    /// Captures the way the app does, inserts, and reads back. Fictional words only.
    static async Task ChromiumFields()
    {
        string name = "pflow-fictional-chromium-" + Guid.NewGuid().ToString("N");
        string html = Path.Combine(root, name + ".html");
        File.WriteAllText(html, "<!doctype html><meta charset=utf-8><title>" + name + "</title><style>body{font:16px sans-serif;margin:24px}[contenteditable]{min-height:120px;border:1px solid #888;padding:8px}</style>"
            + "<p>Fictional compose</p><textarea aria-label='Fictional area' rows=3 cols=40></textarea><br><input type=text aria-label='Fictional line' size=40><br>"
            + "<div contenteditable=true role=textbox aria-multiline=true aria-label='Fictional body'><div><br></div></div>");
        string edgePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe");
        var edge = new ProcessStartInfo(edgePath) { UseShellExecute = false };
        bool forced = Environment.GetEnvironmentVariable("PFLOW_FORCE_A11Y") == "1";
        foreach (var arg in new[] { "--user-data-dir=" + Path.Combine(root, EdgeProfile(name)), "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--app=" + new Uri(html).AbsoluteUri })
            edge.ArgumentList.Add(arg);
        if (forced) edge.ArgumentList.Add("--force-renderer-accessibility");
        foreach (var p in Process.GetProcessesByName("msedge")) { try { if (p.MainWindowTitle.Contains("pflow-fictional")) p.CloseMainWindow(); } catch { } }
        using var owner = new HwndSource(new HwndSourceParameters("pFlow fictional chromium owner") { Width = 10, Height = 10 });
        var process = Process.Start(edge)!;
        try {
            var window = await WindowWith(name);
            Console.WriteLine($"CHROMIUM forced accessibility={forced}; window {window.Current.ClassName}");
            foreach (string label in new[] { "Fictional area", "Fictional line", "Fictional body" }) {
                AutomationElement? field = null;
                for (int i = 0; i < 60 && field == null; i++) {
                    field = window.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, label));
                    if (field == null) await Task.Delay(100);
                }
                if (field == null) {
                    var all = window.FindAll(TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition);
                    Console.WriteLine($"CHROMIUM {label}: not found among {all.Count} descendants; window name=[{window.Current.Name}] handle={window.Current.NativeWindowHandle} edges={Process.GetProcessesByName("msedge").Length}");
                    foreach (AutomationElement c in all) if (c.Current.ControlType == ControlType.Edit || c.Current.ControlType == ControlType.Document) Console.WriteLine($"CHROMIUM   {c.Current.ControlType.ProgrammaticName} [{c.Current.Name}]");
                }
                Check(label + " is exposed", field != null);
                await Focus(window, field!);
                string describe = "";
                try { describe = LiveTextField.Describe(field!, (IntPtr)window.Current.NativeWindowHandle); } catch (Exception error) { describe = error.GetType().Name; }
                bool text = field!.TryGetCurrentPattern(TextPattern.Pattern, out _), value = field.TryGetCurrentPattern(ValuePattern.Pattern, out var v);
                Console.WriteLine($"CHROMIUM {label}: type={field.Current.ControlType.ProgrammaticName} class={field.Current.ClassName} framework={field.Current.FrameworkId} text={text} value={value}{(value ? " readOnly=" + ((ValuePattern)v).Current.IsReadOnly : "")} live[{describe}]");
                var target = InsertionTarget.Capture();
                Console.WriteLine($"CHROMIUM {label}: capture CanInsert={target.CanInsert} app={target.ApplicationName}");
                if (!target.CanInsert) { await Task.Delay(500); target = InsertionTarget.Capture(); Console.WriteLine($"CHROMIUM {label}: capture again after 500 ms CanInsert={target.CanInsert}"); }
                if (!target.CanInsert) { Console.WriteLine($"CHROMIUM {label}: not insertable; skipped"); continue; }
                string before = Read(field), valueBefore = value ? ((ValuePattern)v).Current.Value : "(no value pattern)";
                var selection = ((TextPattern)field.GetCurrentPattern(TextPattern.Pattern)).GetSelection();
                Console.WriteLine($"CHROMIUM {label}: before text=[{Show(before)}] value=[{Show(valueBefore)}] selections={selection.Length} selectionText=[{(selection.Length > 0 ? Show(selection[0].GetText(-1)) : "")}]");
                string result;
                try { result = await target.Insert("Fictional words one two.", owner.Handle, false, CancellationToken.None); }
                catch (Exception error) { result = "EXCEPTION " + error.GetType().Name + ": " + error.Message; }
                await Task.Delay(300);
                string after = Read(field), valueAfter = value ? ((ValuePattern)v).Current.Value : "(no value pattern)";
                Console.WriteLine($"CHROMIUM {label}: result=[{result}] after text=[{Show(after)}] value=[{Show(valueAfter)}]");
                Console.WriteLine($"CHROMIUM {label}: {(Normalize(after).Contains("Fictional words one two.") || valueAfter.Contains("Fictional words one two.") ? "RECEIVED" : "NOT RECEIVED")} {(result == "Inserted" ? "ACKNOWLEDGED" : "NOT ACKNOWLEDGED")}");
            }
        } finally {
            try { process.CloseMainWindow(); } catch { }
            foreach (var p in Process.GetProcessesByName("msedge")) { try { if (p.MainWindowTitle.Contains(name)) p.CloseMainWindow(); } catch { } }
            await Task.Delay(500);
            try { File.Delete(html); } catch { }
        }
    }

    /// --chromium-cold: Edge just opened, the first UI Automation call is the app's own
    /// capture, as on the owner's PC. Three pages: a Gmail-style body the page focuses
    /// itself (two-line text, so a non-Win32 target must paste, never type Enter), a
    /// password box, and a body left to Chromium's placeholder pane. Each outcome is
    /// honest: delivered and confirmed, or the text on the clipboard with the paste
    /// toast, or refused. Nothing is ever typed into a password box or a pane.
    static async Task ChromiumCold()
    {
        var log = new List<string>(); InsertionLog.Written += line => log.Add(line);
        foreach (var page in new[] { ("body", true, "Fictional cold words.\nSecond fictional line."), ("password", true, "Fictional secret words."), ("placeholder", false, "Fictional pane words.") })
            await ColdPage(page.Item1, page.Item2, page.Item3, log);
        await PasteNoticeEveryTime();
    }
    static async Task ColdPage(string variant, bool scriptFocus, string text, List<string> log)
    {
        string name = "pflow-fictional-cold-" + variant + "-" + Guid.NewGuid().ToString("N");
        string html = Path.Combine(root, name + ".html");
        string field = variant == "password" ? "<input id=body type=password aria-label='Fictional secret' autofocus>"
            : "<div id=body contenteditable=true role=textbox aria-multiline=true aria-label='Fictional body' autofocus><div><br></div></div>";
        File.WriteAllText(html, "<!doctype html><meta charset=utf-8><title>" + name + "</title><style>body{font:16px sans-serif;margin:24px}[contenteditable]{min-height:120px;border:1px solid #888;padding:8px}</style>"
            + "<p>Fictional compose</p>" + field
            + "<script>var b=document.getElementById('body');function mirror(){var t=b.value!==undefined?('len:'+b.value.length):b.innerText.replace(/\\s+/g,' ').trim();document.title='" + name + " | focus:'+(document.activeElement&&document.activeElement.id)+' | '+t;}"
            + "b.addEventListener('input',mirror);document.addEventListener('focusin',mirror);document.addEventListener('focusout',mirror);window.addEventListener('load',function(){" + (scriptFocus ? "b.focus();" : "") + "mirror();});</script>");
        string edgePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe");
        var edge = new ProcessStartInfo(edgePath) { UseShellExecute = false };
        foreach (var arg in new[] { "--user-data-dir=" + Path.Combine(root, EdgeProfile(name)), "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--app=" + new Uri(html).AbsoluteUri })
            edge.ArgumentList.Add(arg);
        foreach (var p in Process.GetProcessesByName("msedge")) { try { if (p.MainWindowTitle.Contains("pflow-fictional")) p.CloseMainWindow(); } catch { } }
        using var owner = new HwndSource(new HwndSourceParameters("pFlow fictional cold owner " + variant) { Width = 10, Height = 10 });
        var process = Process.Start(edge)!;
        try {
            IntPtr window = IntPtr.Zero;
            for (int i = 0; i < 100 && window == IntPtr.Zero; i++) {
                await Task.Delay(100);
                foreach (var p in Process.GetProcessesByName("msedge")) { try { if (p.MainWindowTitle.Contains(name)) window = p.MainWindowHandle; } catch { } }
            }
            Check(variant + ": Edge window appeared", window != IntPtr.Zero);
            await Task.Delay(1500);
            uint foregroundThread = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out _), me = GetCurrentThreadId();
            bool attached = foregroundThread != me && AttachThreadInput(me, foregroundThread, true);
            try { SetForegroundWindow(window); } finally { if (attached) AttachThreadInput(me, foregroundThread, false); }
            await Task.Delay(700);
            string Title() { var t = new System.Text.StringBuilder(512); GetWindowText(window, t, t.Capacity); return t.ToString(); }
            Console.WriteLine($"COLD {variant}: foreground is Edge={Native.GetForegroundWindow() == window}; title before=[{Title()}]");
            // The app's take start: capture; a placeholder pane is knocked and captured again at 300 and 700 ms (Program.CaptureAgainSoon).
            string outcome; string result;
            try {
                var target = InsertionTarget.Capture();
                Console.WriteLine($"COLD {variant}: capture CanInsert={target.CanInsert} placeholder={target.Placeholder} field={target.Kind} refusal={target.Refusal}");
                foreach (int wait in new[] { 300, 700 }) {
                    if (!target.Placeholder) break;
                    await Task.Delay(wait);
                    var again = InsertionTarget.Capture();
                    Console.WriteLine($"COLD {variant}: capture again after {wait} ms: CanInsert={again.CanInsert} placeholder={again.Placeholder} field={again.Kind} same window={target.SameWindow(again)}");
                    if (target.SameWindow(again) && again.CanInsert && !again.Placeholder) { target = again; break; }
                }
                result = await target.Insert(text, owner.Handle, false, CancellationToken.None);
                outcome = result == "Inserted" ? "delivered" : result == InsertionTarget.PasteReady ? "clipboard" : "other";
            } catch (InvalidOperationException error) { result = error.Message; outcome = "refused"; }
            await Task.Delay(800);
            string title = Title();
            Console.WriteLine($"COLD OUTCOME {variant}: {outcome} result=[{result}] title now=[{title}]");
            Check(variant + ": the outcome is delivered, clipboard or refused; never typing without a check", outcome != "other");
            Check(variant + ": never a bare 'Inserted' without the words on the page", result != "Inserted" || title.Contains("Second fictional line") || (variant != "body" && title.Contains(text)));
            if (variant == "password") Check("password: nothing was typed into the password box", title.Contains("len:0") && result != "Inserted");
            if (variant == "placeholder" && outcome == "clipboard") Check("placeholder: the pane got no keystrokes", !title.Contains("Fictional pane words"));
            if (outcome == "delivered" && variant == "body") Check("body: two lines went in by paste, never typed Enter", log.Any(l => l.Contains("path=clipboard")) && !log.Any(l => l.Contains("path=type")));
            if (outcome == "clipboard") {
                string clip = ""; try { clip = Clipboard.GetText(); } catch (Exception error) { clip = "EXCEPTION " + error.GetType().Name; }
                Check(variant + ": the paste toast comes with the text on the clipboard", clip == text);
                Check(variant + ": the log names the reason", log.Any(l => l.Contains("placeholder pane at insert time")));
                try { Clipboard.Clear(); } catch { }
            }
            log.Clear();
        } finally {
            try { process.CloseMainWindow(); } catch { }
            foreach (var p in Process.GetProcessesByName("msedge")) { try { if (p.MainWindowTitle.Contains(name)) p.CloseMainWindow(); } catch { } }
            await Task.Delay(500);
            try { File.Delete(html); } catch { }
        }
    }
    /// "Press Ctrl+V to paste" is said on every such take, never only the first.
    static async Task PasteNoticeEveryTime()
    {
        string directory = Path.Combine(root, "paste-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        try {
            var store = new StateStore(directory); await using var whisper = new Whisper(directory); var model = new LocalTextModel(directory);
            var pipeline = new DictationPipeline(store, whisper, model);
            var prepared = new DictationPipeline.Prepared("Fictional paste words.", null, 3, false, false, false);
            var notices = new List<string?>();
            for (int i = 0; i < 3; i++) { var r = await pipeline.Deliver(prepared, 1.0, new PasteOnlyTarget(), IntPtr.Zero, (_, _) => { }, CancellationToken.None); notices.Add(r.Notice); }
            Check("the paste toast is shown on every take (3 of 3)", notices.All(n => n == InsertionTarget.PasteReady));
        } finally { Directory.Delete(directory, true); }
    }
    sealed class PasteOnlyTarget : IInsertionTarget
    {
        public bool CanInsert => true; public string ApplicationName => "Fictional"; public string ApplicationId => "fictional";
        public Task<string> Insert(string text, IntPtr owner, bool keep, CancellationToken cancel, string? rtf = null) => Task.FromResult(InsertionTarget.PasteReady);
    }
}
