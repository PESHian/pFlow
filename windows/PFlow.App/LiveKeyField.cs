using System.Globalization;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace PFlow.Windows;

/// A web field in Chrome or Edge whose text UI Automation can read: live words go in as typed
/// characters (SendInput, Unicode), the way a person's typing would, because a browser has no range
/// write. Append only while words come: pFlow only ever adds settled words at the caret right after its
/// own words; it never presses Backspace, Shift or an arrow, and never revises what it typed. A word the
/// recognizer revises ends live typing for the take (LiveInlineSession). At the end pFlow's own words are
/// selected through UI Automation (no keys), read back, and the finished text goes over them the normal
/// checked way (InsertionTarget.InsertOverSelection); any doubt leaves the words, ends the selection and
/// offers the finished text in the Copy card. Each write is read back before the next. Never a password field,
/// never Enter (line breaks are spaces while words come live), and every key batch is sent only right
/// after the checks in `Unsafe` (one rule, `SendChecked`).
/// ON again in 0.1.28: 0.1.27's append-only ending left partial words and the Copy card, so it was off; the
/// end-of-take replace ends every take with exactly the finished text (VM: 60/60 Edge and Chrome takes).
/// `Enabled` false turns browser live typing off (the 0.1.27 behaviour: the finished text goes in at the end).
internal sealed class LiveKeyField : ILiveTextField
{
    internal static bool Enabled { get; set; } = true;
    static readonly string[] Browsers = ["chrome", "msedge"], Hosts = ["Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND"];
    readonly AutomationElement element;
    readonly int[] runtimeId;
    readonly IntPtr window, control;
    readonly bool elevated;
    public string LineBreak => " ";
    public string Method => "keys";
    public bool AppendOnly => true;
    public bool ReadyToWrite => !new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => Native.GetAsyncKeyState(key) < 0);

    /// Internal for the native checks of Collapse; the app makes one only through Create.
    internal LiveKeyField(AutomationElement element, IntPtr window, IntPtr control, bool elevated) { this.element = element; runtimeId = element.GetRuntimeId(); this.window = window; this.control = control; this.elevated = elevated; }

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

    /// An empty range: no keys, the caret is already where the last write left it; this only checks.
    /// pFlow's own words at the end of a take: selected through UI Automation (no keys) only when the field
    /// and the window are still as the key checks require and the range's text is exactly what the field
    /// shows there; then read back. Any doubt ends the selection again (Collapse) and returns false.
    public bool Select(TextSpan range)
    {
        if (range.Length == 0) return Until(() => Selection() == range, 300);
        // From here to the first key of the finished text, any key or click of the person's refuses the replace.
        watch?.Stop(); watch = InputWatch.Start();
        string? why = aborted ? "typing already stopped" : Unsafe();
        if (why != null) { Diagnostics.Recorder.Event("typing.guard", new DiagField("stopped", why), new DiagField("stage", "select own words")); return false; }
        try {
            var pattern = (TextPattern)element.GetCurrentPattern(TextPattern.Pattern); var document = pattern.DocumentRange;
            if (Value() is not string value || range.Start + range.Length > value.Length) return false;
            var span = document.Clone();
            span.MoveEndpointByRange(TextPatternRangeEndpoint.End, document, TextPatternRangeEndpoint.Start);
            if (span.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, range.Start + range.Length) != range.Start + range.Length
                || span.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, range.Start) != range.Start) return false;
            if (span.GetText(-1).Replace('\u00A0', ' ') != value.Substring(range.Start, range.Length)) return false;
            span.Select();
            if (Until(() => Selection() == range && Value() == value, 500)) return true;
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException or ArgumentException) { }
        Collapse();
        return false;
    }

    /// Ends any selection in the field at its end, through UI Automation (no keys), only while the field still
    /// has the focus in the window in front: a selection in a field the person left is left alone (in Chrome a
    /// UI Automation select there can pull the caret back). False when nothing was done.
    /// The person's key or click since Select (InputWatch); asked once, right before the first key, and the watch ends.
    public bool PersonActedSinceSelect()
    {
        var asked = watch; watch = null;
        bool acted = asked?.End() ?? true;
        if (acted) Diagnostics.Recorder.Event("typing.guard", new DiagField("stopped", "the person pressed a key or a mouse button after pFlow selected its words"), new DiagField("stage", "replace own words"));
        return acted;
    }
    InputWatch? watch;

    public bool Collapse()
    {
        watch?.Stop(); watch = null;
        if (Native.GetForegroundWindow() != window || !SameElement()) { Diagnostics.Recorder.Event("typing.collapse", new DiagField("result", "left alone: the field no longer has the focus")); return false; }
        try {
            var selections = ((TextPattern)element.GetCurrentPattern(TextPattern.Pattern)).GetSelection();
            if (selections.Length != 1) return false;
            if (selections[0].CompareEndpoints(TextPatternRangeEndpoint.Start, selections[0], TextPatternRangeEndpoint.End) == 0) return true;
            var end = selections[0].Clone(); end.MoveEndpointByRange(TextPatternRangeEndpoint.Start, end, TextPatternRangeEndpoint.End); end.Select();
            return Until(() => Selection() is { Length: 0 }, 300);
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { return false; }
    }

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
        if (InputComposition.PanelOpen()) return "the emoji or clipboard panel is open";
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
