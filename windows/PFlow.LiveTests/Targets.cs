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

    /// --chromium-cold: Edge just opened, the Gmail-style body focused by the page itself,
    /// and the first UI Automation call is the app's own capture, as on the owner's PC.
    /// Chromium builds its accessibility tree only once a client asks.
    static async Task ChromiumCold()
    {
        string name = "pflow-fictional-cold-" + Guid.NewGuid().ToString("N");
        string html = Path.Combine(root, name + ".html");
        File.WriteAllText(html, "<!doctype html><meta charset=utf-8><title>" + name + "</title><style>body{font:16px sans-serif;margin:24px}[contenteditable]{min-height:120px;border:1px solid #888;padding:8px}</style>"
            + "<p>Fictional compose</p><div id=body contenteditable=true role=textbox aria-multiline=true aria-label='Fictional body' autofocus><div><br></div></div>"
            + "<script>var b=document.getElementById('body');function mirror(){document.title='" + name + " | focus:'+(document.activeElement&&document.activeElement.id)+' | '+b.innerText.replace(/\\s+/g,' ').trim();}"
            + "b.addEventListener('input',mirror);document.addEventListener('focusin',mirror);document.addEventListener('focusout',mirror);window.addEventListener('load',function(){b.focus();mirror();});</script>");
        string edgePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe");
        var edge = new ProcessStartInfo(edgePath) { UseShellExecute = false };
        foreach (var arg in new[] { "--user-data-dir=" + Path.Combine(root, EdgeProfile(name)), "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--app=" + new Uri(html).AbsoluteUri })
            edge.ArgumentList.Add(arg);
        foreach (var p in Process.GetProcessesByName("msedge")) { try { if (p.MainWindowTitle.Contains("pflow-fictional")) p.CloseMainWindow(); } catch { } }
        Console.WriteLine("COLD profile " + EdgeProfile(name));
        using var owner = new HwndSource(new HwndSourceParameters("pFlow fictional cold owner") { Width = 10, Height = 10 });
        var process = Process.Start(edge)!;
        try {
            // Win32 only until the capture: no UI Automation call wakes Chromium's tree early.
            IntPtr window = IntPtr.Zero;
            for (int i = 0; i < 100 && window == IntPtr.Zero; i++) {
                await Task.Delay(100);
                foreach (var p in Process.GetProcessesByName("msedge")) { try { if (p.MainWindowTitle.Contains(name)) window = p.MainWindowHandle; } catch { } }
            }
            Check("Edge window appeared", window != IntPtr.Zero);
            await Task.Delay(1500);
            // Win32 activation only (no UI Automation element for the window).
            uint foregroundThread = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out _), me = GetCurrentThreadId();
            bool attached = foregroundThread != me && AttachThreadInput(me, foregroundThread, true);
            try { SetForegroundWindow(window); } finally { if (attached) AttachThreadInput(me, foregroundThread, false); }
            await Task.Delay(700);
            { var t = new System.Text.StringBuilder(512); GetWindowText(window, t, t.Capacity); Console.WriteLine($"COLD foreground is Edge={Native.GetForegroundWindow() == window}; title before=[{t}]"); }
            var clock = Stopwatch.StartNew();
            for (int attempt = 1; attempt <= 34; attempt++) {
                // Sustained use, as a screen reader would: the classic knock on the focused window each time.
                string knock = attempt >= 3 ? MsaaNudge(window) : "none";
                var target = InsertionTarget.Capture();
                if (attempt <= 3 || target.CanInsert || attempt % 5 == 0) Console.WriteLine($"COLD capture {attempt} at {clock.ElapsedMilliseconds} ms (knock {knock}): CanInsert={target.CanInsert} field={target.Kind} refusal={target.Refusal} app={target.ApplicationName}");
                if (target.CanInsert) {
                    string result;
                    try { result = await target.Insert("Fictional cold words.", owner.Handle, false, CancellationToken.None); }
                    catch (Exception error) { result = "EXCEPTION " + error.GetType().Name + ": " + error.Message; }
                    await Task.Delay(800);
                    var title = new System.Text.StringBuilder(512); GetWindowText(window, title, title.Capacity);
                    Console.WriteLine($"COLD insert result=[{result}] unverifiable={target.Unverifiable} title now=[{title}]");
                    Check("cold Chromium body got the typed words (page title mirrors its text)", title.ToString().Contains("Fictional cold words."));
                    // Chromium exposes its tree to some captures and not others: a readable field is confirmed
                    // and reported Inserted; an unreadable one is typed and reported as not checked.
                    Check("the take is honest about the check", result == (target.Unverifiable ? InsertionTarget.Unchecked : "Inserted"));
                    break;
                }
                await Task.Delay(300);
            }
        } finally {
            try { process.CloseMainWindow(); } catch { }
            foreach (var p in Process.GetProcessesByName("msedge")) { try { if (p.MainWindowTitle.Contains(name)) p.CloseMainWindow(); } catch { } }
            await Task.Delay(500);
            try { File.Delete(html); } catch { }
        }
    }
}
