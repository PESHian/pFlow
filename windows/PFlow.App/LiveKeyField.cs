using System.Globalization;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace PFlow.Windows;

/// A web field in Chrome or Edge whose text UI Automation can read: live words go in as typed
/// characters (SendInput, Unicode), the way a person's typing would, because a browser has no range
/// write. Append only: pFlow only ever adds settled words at the caret right after its own words; it
/// never selects, never presses Backspace, Shift or an arrow, and never revises what it typed. A word the
/// recognizer revises ends live typing for the take (LiveInlineSession); at the end the finished text is
/// added only if it starts with exactly what was typed, otherwise what is there stays and the finished
/// text is offered in the Copy card. Each write is read back before the next. Never a password field,
/// never Enter (line breaks are spaces while words come live), and every key batch is sent only right
/// after the checks in `Unsafe` (one rule, `SendChecked`).
/// OFF in 0.1.27 (`Enabled` is false; only the guard checks turn it on): append-only typing ended every
/// browser take worse than 0.1.26 (partial live words and the Copy card), so browsers get no live typing.
internal sealed class LiveKeyField : ILiveTextField
{
    internal static bool Enabled { get; set; }
    static readonly string[] Browsers = ["chrome", "msedge"], Hosts = ["Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND"];
    readonly AutomationElement element;
    readonly int[] runtimeId;
    readonly IntPtr window, control;
    readonly bool elevated;
    public string LineBreak => " ";
    public string Method => "keys";
    public bool AppendOnly => true;
    public bool ReadyToWrite => !new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => Native.GetAsyncKeyState(key) < 0);

    LiveKeyField(AutomationElement element, IntPtr window, IntPtr control, bool elevated) { this.element = element; runtimeId = element.GetRuntimeId(); this.window = window; this.control = control; this.elevated = elevated; }

    /// The focused field when it is a readable, editable text field in a web page in Chrome or Edge (an
    /// edit control under the page's document, so never the address bar or other browser controls) with
    /// only a caret (no selection); otherwise null with the reason.
    internal static LiveKeyField? Create(AutomationElement element, IntPtr window, uint process, string program, out string why)
    {
        try {
            var current = element.Current; IntPtr control = LiveTextField.FocusedControl(window);
            why = current.FrameworkId != "Chrome" ? "not a Chromium field (" + current.FrameworkId + ")"
                : !Browsers.Contains(program, StringComparer.OrdinalIgnoreCase) ? "Chromium app other than Chrome or Edge"
                : !Hosts.Contains(LiveTextField.ClassName(control)) ? "focus is not in a browser window"
                : current.IsPassword ? "password field"
                : current.ControlType != ControlType.Edit ? "not a text field (" + current.ControlType.ProgrammaticName.Replace("ControlType.", "") + ")"
                : !InPage(element) ? "not in a web page (browser control)"
                : Composing(window, control) ? "an input method that composes text is active"
                : !element.TryGetCurrentPattern(TextPattern.Pattern, out _) ? "no text pattern" : "ok";
            if (why != "ok") return null;
            var field = new LiveKeyField(element, window, control, LiveTextField.TargetAboveUs(process));
            if (field.Selection() is not { Length: 0 }) { why = "text is selected or the caret is unreadable"; return null; }
            return field;
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { why = "field went away (" + error.GetType().Name + ")"; return null; }
    }

    /// A web page's fields sit under its document; the browser's own controls (address bar, find bar) do not.
    static bool InPage(AutomationElement element)
    {
        var walker = TreeWalker.ControlViewWalker;
        for (var node = walker.GetParent(element); node != null && node != AutomationElement.RootElement; node = walker.GetParent(node))
            if (node.Current.ControlType == ControlType.Document) return true;
        return false;
    }

    public LiveFieldState State()
    {
        IntPtr front = Native.GetForegroundWindow(); Native.GetWindowThreadProcessId(front, out uint app);
        bool same = front == window && LiveTextField.FocusedControl(front) == control && SameElement();
        bool secure = false;
        try { secure = element.Current.IsPassword; } catch (Exception error) when (error is ElementNotAvailableException or COMException) { same = false; }
        string? value = same ? Value() : null;
        return new LiveFieldState(app, same ? LiveFieldState.Target : "other", secure, !elevated, value, same && value != null ? Selection() : null);
    }

    public bool CanWriteRanges()
    {
        if (elevated) return false;
        try {
            if (!element.Current.IsEnabled || !((TextPattern)element.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute).Equals(false)) return false;
            return !element.TryGetCurrentPattern(ValuePattern.Pattern, out var value) || !((ValuePattern)value).Current.IsReadOnly;
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { return false; }
    }

    /// Adds `text` at the caret, which must be right after pFlow's own words (`range` is empty and there).
    /// Anything else (a revision) sends no key and returns false. True once the field reads back as
    /// expected with the caret after the new text.
    public bool Replace(TextSpan range, string text)
    {
        if (aborted || range.Length != 0 || text.Length == 0 || text.IndexOfAny(['\r', '\n']) >= 0 || !ReadyToWrite) return false;
        var state = State();
        if (state.Element != LiveFieldState.Target || state.Value is not string value || state.Selection != new TextSpan(range.Start, 0) || range.Start > value.Length) return false;
        string expected = value[..range.Start] + text + value[range.Start..];
        if (!SendChecked(Native.UnicodeText(text))) return false;
        var caret = new TextSpan(range.Start + text.Length, 0);
        return Until(() => Value() == expected && Selection() == caret, 800 + 15 * text.Length);
    }

    /// No keys: the caret is already where the last write left it; this only checks.
    public bool Select(TextSpan range) => Until(() => Selection() == range, 300);

    /// Test hooks: `BeforeSend` runs before the checks of a key batch; `AfterLookup` runs between the slow
    /// UI Automation checks and the fast ones (the window a person could switch during the lookup).
    internal static Action? BeforeSend { get; set; }
    internal static Action? AfterLookup { get; set; }
    bool aborted;

    /// Why keys must not be sent now, or null. The slow UI Automation checks (a cross-process call each)
    /// come first; the fast ones (front window, focused window, keys down, input method and input panels)
    /// run last, immediately before SendInput. What remains: a change in the microseconds between the
    /// last check and SendInput cannot be seen, and a composition in an input method this cannot detect
    /// (see `Composing`) changes the text; the read-back after each write then ends typing.
    string? Unsafe()
    {
        try {
            var focused = AutomationElement.FocusedElement;
            if (focused == null || !focused.GetRuntimeId().SequenceEqual(runtimeId)) return "focus moved to another field";
            if (focused.Current.IsPassword) return "a password field";
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { return "the focused field went away"; }
        AfterLookup?.Invoke();
        IntPtr front = Native.GetForegroundWindow();
        if (front != window) return "another window came to the front";
        if (LiveTextField.FocusedControl(front) != control) return "focus moved to another control";
        if (!ReadyToWrite) return "a key is held";
        if (KeyDown()) return "the person is typing";
        if (Composing(window, control)) return "an input method is active";
        if (InputPanelOpen()) return "the emoji or clipboard panel is open";
        return null;
    }

    bool SendChecked(params Native.Input[] inputs)
    {
        BeforeSend?.Invoke();
        if (Unsafe() is string why) {
            aborted = true;
            Diagnostics.Recorder.Event("typing.guard", new DiagField("stopped", why));
            return false;
        }
        return Send(inputs);
    }

    /// Any key down except mouse buttons and the toggles' lock state (the activation key pFlow holds is
    /// swallowed by its own hook and never reads as down).
    static bool KeyDown()
    {
        for (int key = 0x08; key <= 0xFE; key++)
            if (Native.GetAsyncKeyState(key) < 0) return true;
        return false;
    }

    /// The emoji panel (Win+.) or clipboard history (Win+V): a visible, uncloaked window of Windows'
    /// text input host. Not verified on the test VM (injected keys do not open the panel there).
    static bool InputPanelOpen()
    {
        bool open = false; var names = new Dictionary<uint, string>();
        EnumWindows((window, _) => {
            if (!IsWindowVisible(window)) return true;
            Native.GetWindowThreadProcessId(window, out uint process);
            if (!names.TryGetValue(process, out var name)) { try { using var p = Process.GetProcessById((int)process); name = p.ProcessName; } catch (ArgumentException) { name = ""; } names[process] = name; }
            if (name != "TextInputHost") return true;
            if (DwmGetWindowAttribute(window, 14, out int cloaked, 4) == 0 && cloaked != 0) return true;
            if (Native.GetWindowRect(window, out var bounds) && bounds.Right > bounds.Left && bounds.Bottom > bounds.Top) { open = true; return false; }
            return true;
        }, IntPtr.Zero);
        return open;
    }
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

    /// The window's thread types in a language whose input methods compose text (one rule:
    /// InputLanguages.Composes), or its input method reports itself open (WM_IME_CONTROL
    /// IMC_GETOPENSTATUS to its IME window, which works across processes).
    internal static bool Composing(IntPtr window, IntPtr control)
    {
        if (InputLanguages.Composes((int)(GetKeyboardLayout(Native.GetWindowThreadProcessId(window, out _)).ToInt64() & 0xFFFF))) return true;
        IntPtr ime = ImmGetDefaultIMEWnd(control != IntPtr.Zero ? control : window);
        return ime != IntPtr.Zero && SendMessageTimeout(ime, 0x0283, (IntPtr)0x0005, IntPtr.Zero, 0x0002, 100, out var open) != IntPtr.Zero && open != IntPtr.Zero;
    }
    [DllImport("imm32.dll")] static extern IntPtr ImmGetDefaultIMEWnd(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, int message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);

    static bool Send(params Native.Input[] inputs)
    {
        try { Native.Send(inputs); return true; } catch (InvalidOperationException) { return false; }
    }

    /// Waits for the browser to show a write. pFlow's own keyboard hook runs on this thread and sees every
    /// typed character first, so sent messages (the hook's calls) are handled while waiting; posted
    /// work (another live update) waits until this write is over.
    static bool Until(Func<bool> done, int milliseconds)
    {
        var clock = Stopwatch.StartNew();
        while (true) {
            if (done()) return true;
            if (clock.ElapsedMilliseconds > milliseconds) return false;
            PeekMessage(out _, IntPtr.Zero, 0, 0, PM_NOREMOVE | PM_QS_SENDMESSAGE);
            Thread.Sleep(10);
        }
    }

    bool SameElement()
    {
        try { return AutomationElement.FocusedElement?.GetRuntimeId().SequenceEqual(runtimeId) == true; }
        catch (Exception error) when (error is ElementNotAvailableException or COMException) { return false; }
    }

    /// The field's text as UI Automation reads it (an empty field's label is no text, one rule:
    /// InsertionTarget.DocumentText), with no-break spaces read as spaces: a browser shows a typed
    /// space at the end of a line as one.
    string? Value()
    {
        try {
            var range = ((TextPattern)element.GetCurrentPattern(TextPattern.Pattern)).DocumentRange;
            string text = InsertionTarget.DocumentText(element, range);
            return text.Length > LiveInlineOwnership.MaxFieldLength ? null : text.Replace(' ', ' ');
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { return null; }
    }

    TextSpan? Selection()
    {
        try {
            var pattern = (TextPattern)element.GetCurrentPattern(TextPattern.Pattern); var selections = pattern.GetSelection();
            if (selections.Length != 1) return null;
            var prefix = pattern.DocumentRange.Clone();
            prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, selections[0], TextPatternRangeEndpoint.Start);
            return new TextSpan(InsertionTarget.DocumentText(element, prefix).Length, selections[0].GetText(-1).Length);
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { return null; }
    }

    const uint PM_NOREMOVE = 0, PM_QS_SENDMESSAGE = 0x00400000;
    [StructLayout(LayoutKind.Sequential)] struct Message { public IntPtr Window; public uint Id; public IntPtr W, L; public uint Time; public int X, Y; }
    [DllImport("user32.dll")] static extern bool PeekMessage(out Message message, IntPtr window, uint first, uint last, uint remove);
}
