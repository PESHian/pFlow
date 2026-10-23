using System.Globalization;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace PFlow.Windows;

/// A web field in Chrome or Edge whose text UI Automation can read: live words go in as typed
/// characters (SendInput, Unicode), the way a person's typing would, because a browser has no range
/// write. The ownership rules decide every write (LiveInlineSession): only settled words, only at the
/// caret right after pFlow's own words, and a revision only of pFlow's own typed tail, selected with
/// Shift+Left and checked to be exactly that span before anything is typed over it. Each write is read
/// back through UI Automation before the next; a mismatch, a focus or caret change, or an unreadable
/// field ends live typing for the take, and the finished text then goes in at the end as before. Never a
/// password field, never Enter (line breaks are spaces while words come live; finished text with line
/// breaks takes pFlow's live words back out and goes in the normal, checked way), never Backspace
/// over text pFlow did not type, and never while a key the person holds would change the characters.
internal sealed class LiveKeyField : ILiveTextField
{
    static readonly string[] Browsers = ["chrome", "msedge"], Hosts = ["Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND"];
    const ushort Shift = 0x10, Left = 0x25, Right = 0x27, Back = 0x08;
    readonly AutomationElement element;
    readonly int[] runtimeId;
    readonly IntPtr window, control;
    readonly bool elevated;
    public string LineBreak => " ";
    public string Method => "keys";
    public bool KeepsLineBreaks => false;
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

    /// Types `text` over `range`, which ends at the caret (pFlow's own words end there). A range with
    /// characters in it is selected with Shift+Left first and must read back as exactly that span;
    /// then the characters are typed (or one Backspace removes the selected span). True once the
    /// field reads back as expected with the caret after the new text.
    public bool Replace(TextSpan range, string text)
    {
        if (text.IndexOfAny(['\r', '\n']) >= 0 || !ReadyToWrite) return false;
        var state = State();
        if (state.Element != LiveFieldState.Target || state.Value is not string value || state.Selection != new TextSpan(range.End, 0) || range.End > value.Length) return false;
        if (range.Length > 0) {
            int steps = new StringInfo(value.Substring(range.Start, range.Length)).LengthInTextElements;
            var keys = new List<Native.Input> { Native.Key(Shift) };
            for (int i = 0; i < steps; i++) { keys.Add(Native.Key(Left, extended: true)); keys.Add(Native.Key(Left, true, true)); }
            keys.Add(Native.Key(Shift, true));
            if (!Send([.. keys])) return false;
            if (!Until(() => Selection() == range, 600)) {
                // Not exactly pFlow's span: the selection is put back as a caret where it was, nothing is typed.
                Send(Native.Key(Right, extended: true), Native.Key(Right, true, true));
                return false;
            }
        }
        string expected = value[..range.Start] + text + value[range.End..];
        if (!Send(text.Length > 0 ? Native.UnicodeText(text) : [Native.Key(Back), Native.Key(Back, true)])) return false;
        var caret = new TextSpan(range.Start + text.Length, 0);
        return Until(() => Value() == expected && Selection() == caret, 800 + 15 * text.Length);
    }

    /// The caret or selection is already where the write left it; this only checks.
    public bool Select(TextSpan range) => Until(() => Selection() == range, 300);

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
