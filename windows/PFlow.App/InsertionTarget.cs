using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace PFlow.Windows;

/// Where a finished take goes. The real one is the field captured at the start of the take.
internal interface IInsertionTarget
{
    bool CanInsert { get; }
    string ApplicationName { get; }
    string ApplicationId { get; }
    Task<string> Insert(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf = null);
}

internal sealed class InsertionTarget : IInsertionTarget
{
    readonly AutomationElement element;
    readonly int[] runtimeId;
    readonly string before;
    readonly int start, length;
    readonly bool readable;
    /// A Chromium host (Chrome, Edge, Electron apps) builds its accessibility
    /// tree only for a screen reader, so its field cannot be read or checked:
    /// the text goes in as keystrokes and the person is told it was not checked,
    /// like the Mac's unconfirmed fallback for unreadable web fields.
    readonly bool blind;
    readonly IntPtr foreground;
    readonly uint processId;
    FieldState State => new(foreground.ToInt64(), processId, string.Join(".", runtimeId), before, start, length);
    public const string SavedToHistory = "Saved to History. Open History to copy your dictation.";
    public const string Unchecked = "Typed into the app; it did not let pFlow check the result. Look at the field before copying from History.";
    /// Chromium's top-level window class (Chrome, Edge, Electron) and its legacy content window.
    static readonly string[] ChromiumHosts = ["Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND"];
    public const string PlainOnly = "Inserted as plain text; bold headings could not be applied safely.";
    public bool CanInsert => readable || blind;
    /// Typed without a read-back: the field cannot be checked (see `blind`).
    internal bool Unverifiable => blind;
    public string ApplicationName { get; }
    public string ApplicationId { get; }
    /// The preview's "Typing in …" note for this app.
    internal string TypingNote { get; }
    /// Control kind, window class and UI framework of the field, for the insertion log. No text.
    internal string Kind { get; }
    /// Why the field cannot take text, for the log; null when it can.
    internal string? Refusal { get; }
    InsertionTarget(AutomationElement e, string text, int start, int length, bool readable, string? refusal)
    {
        element = e; runtimeId = e.GetRuntimeId(); before = text; this.start = start; this.length = length; this.readable = readable; Refusal = refusal;
        foreground = Native.GetForegroundWindow(); Native.GetWindowThreadProcessId(foreground, out processId);
        blind = !readable && refusal != null && ChromiumFocused();
        if (blind) Refusal = refusal + "; Chromium field, typed without a check";
        using var process = Process.GetProcessById((int)processId); ApplicationName = process.ProcessName; ApplicationId = process.ProcessName;
        TypingNote = TypingNoteFor(processId, ApplicationName); Kind = Describe(e);
    }
    /// The keyboard focus sits in a Chromium window whose tree is not built: the
    /// focused element is Chromium's placeholder pane, not a field and not a page.
    /// A built tree that shows a non-editable element is a refusal, never typing:
    /// keystrokes into a page without a field could fire its single-key shortcuts.
    bool ChromiumFocused()
    {
        if (!ChromiumHosts.Contains(LiveTextField.ClassName(LiveTextField.FocusedControl(foreground)))) return false;
        try { return element.Current.FrameworkId == "Chrome" && element.Current.ControlType == ControlType.Pane; }
        catch (Exception error) when (error is ElementNotAvailableException or COMException) { return false; }
    }
    static string Describe(AutomationElement e)
    {
        try { var c = e.Current; return c.ControlType.ProgrammaticName.Replace("ControlType.", "") + "/" + c.ClassName + "/" + c.FrameworkId; }
        catch (Exception error) when (error is ElementNotAvailableException or COMException) { return "unavailable"; }
    }
    /// Only the classic Win32 providers set a field's whole value in place
    /// reliably (an Edit control's WM_SETTEXT). Browsers, UWP and Electron
    /// fields take typed input instead, like a person typing.
    bool Win32 { get { try { return element.Current.FrameworkId == "Win32"; } catch (Exception error) when (error is ElementNotAvailableException or COMException) { return false; } } }
    void Log(string line) => InsertionLog.Record("insert " + ApplicationName + " " + Kind + ": " + line);
    internal static string TypingNoteFor(uint process, string program)
    {
        var version = VersionInfo(process);
        return LiveInlineText.TypingNote(version?.FileDescription, version?.ProductName, program);
    }
    /// The program file's version resource, read by path with limited query
    /// rights so it works for apps of another architecture; null if unreadable.
    static FileVersionInfo? VersionInfo(uint process)
    {
        IntPtr handle = OpenProcess(0x1000, false, process);
        if (handle == IntPtr.Zero) return null;
        try {
            var path = new System.Text.StringBuilder(1024); int size = path.Capacity;
            if (!QueryFullProcessImageName(handle, 0, path, ref size)) return null;
            return FileVersionInfo.GetVersionInfo(path.ToString(0, size));
        } catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
        finally { CloseHandle(handle); }
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint process);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern bool QueryFullProcessImageName(IntPtr process, int flags, System.Text.StringBuilder name, ref int size);
    /// The captured field for live typing, made before any pFlow window shows.
    /// Null when the field cannot take verified range writes: the take uses Preview.
    internal ILiveTextField? LiveField() => readable ? LiveTextField.Create(element, foreground, processId) : null;
    internal string DescribeLiveField() => LiveTextField.Describe(element, foreground);
    static void CheckSecure(AutomationElement e)
    {
        for (AutomationElement? node = e; node != null; node = TreeWalker.ControlViewWalker.GetParent(node))
            if (node.Current.IsPassword) throw new InvalidOperationException("Dictation is off in password fields.");
    }
    public static InsertionTarget Capture()
    {
        var e = AutomationElement.FocusedElement ?? throw new InvalidOperationException("Place the cursor in a text field first.");
        CheckSecure(e);
        if (!e.Current.IsEnabled || !e.Current.IsKeyboardFocusable) return new(e, "", 0, 0, false, "disabled or not keyboard-focusable");
        if (e.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)) {
            var tp = (TextPattern)pattern; var selections = tp.GetSelection();
            if (selections.Length != 1) return new(e, "", 0, 0, false, "selections=" + selections.Length);
            var document = tp.DocumentRange;
            if (document.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is true) return new(e, "", 0, 0, false, "read-only");
            string text = DocumentText(e, document);
            var prefix = document.Clone(); prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, selections[0], TextPatternRangeEndpoint.Start);
            var selected = selections[0].GetText(-1); int start = Math.Min(DocumentText(e, prefix).Length, text.Length);
            return new(e, text, start, Math.Min(selected.Length, text.Length - start), true, null);
        }
        // Unsupported fields still permit dictation, but can never receive input or clipboard data.
        return new(e, "", 0, 0, false, "no text pattern");
    }
    /// A Chromium field with nothing in it reports its label as its text (the
    /// value is empty): that is no text. Every other field reads as it is.
    static string DocumentText(AutomationElement e, TextPatternRange range)
    {
        string text = range.GetText(-1);
        if (text.Length == 0) return text;
        try {
            if (e.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && ((ValuePattern)value).Current.Value.Length == 0 && text == e.Current.Name) return "";
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { }
        return text;
    }
    /// The field shows the text: exactly, or the same words with other line
    /// breaks or spaces (editors reflow what they are given). Null when it does not.
    internal static string? Observed(string read, string expected) =>
        TextProcessing.SameText(read, expected) ? "exact" : TextProcessing.SameWords(read, expected) ? "words" : null;
    void Validate()
    {
        ValidateFocus();
        var now = Capture();
        if (!now.CanInsert) throw new InvalidOperationException("This field is no longer editable. Your text is in History.");
        FieldState.RequireUnchanged(State, now.State);
    }
    void ValidateFocus()
    {
        if (Native.GetForegroundWindow() != foreground) throw new InvalidOperationException("Focus changed. Your text is in History.");
        Native.GetWindowThreadProcessId(foreground, out var current);
        var focused = AutomationElement.FocusedElement;
        if (current != processId || focused == null || !focused.GetRuntimeId().SequenceEqual(runtimeId)) throw new InvalidOperationException("Focus changed. Your text is in History.");
        CheckSecure(focused);
    }
    internal readonly record struct Payload(string Text, string? Rtf, string Expected);
    internal static Payload Prepare(FieldState destination, string text, string? rtf = null)
    {
        var padding = InsertionSpacing.AtCaret(text, destination.Text, destination.Start, destination.Length);
        text = padding.Apply(text);
        return new(text, rtf == null ? null : RichText.Pad(rtf, padding.Before, padding.After), destination.Inserted(text));
    }
    public async Task<string> Insert(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf = null)
    {
        cancel.ThrowIfCancellationRequested();
        if (!readable && !blind) { Log("saved to History: " + Refusal); return SavedToHistory; }
        try { return readable ? await Deliver(text, clipboardOwner, keepClipboard, cancel, rtf) : await TypeUnchecked(text, clipboardOwner, keepClipboard, cancel, rtf); }
        catch (Exception error) when (error is not OperationCanceledException) { Log("refused: " + error.Message); throw; }
    }
    /// The same app, window and focused control as when the take began; the field itself cannot be read.
    void ValidateHost()
    {
        if (Native.GetForegroundWindow() != foreground) throw new InvalidOperationException("Focus changed. Your text is in History.");
        Native.GetWindowThreadProcessId(foreground, out var current);
        if (current != processId || !ChromiumHosts.Contains(LiveTextField.ClassName(LiveTextField.FocusedControl(foreground)))) throw new InvalidOperationException("Focus changed. Your text is in History.");
    }
    /// Keystrokes (or one paste when the clipboard copy is wanted) into a field pFlow cannot read back.
    async Task<string> TypeUnchecked(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf)
    {
        ValidateHost(); cancel.ThrowIfCancellationRequested();
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(x => Native.GetAsyncKeyState(x) < 0)) throw new InvalidOperationException("Release the shortcut keys first. Your text is in History.");
        if (keepClipboard) {
            Log("path=unchecked paste " + InsertionLog.Length(text));
            using var lease = new ClipboardLease(clipboardOwner, false);
            lease.Put(text, rtf); ValidateHost(); lease.DispatchPaste(); lease.Keep();
        } else {
            Log("path=unchecked typing " + InsertionLog.Length(text));
            Native.Send(Native.UnicodeText(text));
        }
        await Task.Delay(100);
        return Unchecked;
    }
    async Task<string> Deliver(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf)
    {
        Validate();
        if (start > before.Length || start + length > before.Length) throw new InvalidOperationException("The text selection could not be checked. Your text is in History.");
        var payload = Prepare(State, text, rtf);
        text = payload.Text; rtf = payload.Rtf; string expected = payload.Expected;
        // ValuePattern avoids the clipboard for plain Win32 controls that expose it.
        if (rtf == null && !keepClipboard && Win32 && element.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && !((ValuePattern)value).Current.IsReadOnly) {
            Log("path=value field " + InsertionLog.Length(before) + " -> expected " + InsertionLog.Length(expected));
            bool applied = ApplyPlainValue(element, (ValuePattern)value, expected, start + text.Length, ValidateFocus);
            Log(applied ? "confirmed" : "not confirmed: field reads " + InsertionLog.Length(Read()));
            return applied ? "Inserted" : Unconfirmed;
        }
        if (rtf == null && !keepClipboard) return await TypeUnicode(text, expected, cancel);
        ClipboardLease lease;
        try { lease = new ClipboardLease(clipboardOwner, !keepClipboard); }
        catch (InvalidOperationException error) when (!keepClipboard) {
            // Unsupported clipboard formats never block plain dictation or change the clipboard.
            Log("clipboard not saved (" + error.Message + "); typing instead");
            string fallback = await TypeUnicode(text, expected, cancel);
            return fallback == "Inserted" && rtf != null ? PlainOnly : fallback;
        }
        using var clipboardLifetime = lease;
        Validate(); cancel.ThrowIfCancellationRequested();
        try {
            Log("path=clipboard keep=" + keepClipboard + " rich=" + (rtf != null) + " field " + InsertionLog.Length(before) + " -> expected " + InsertionLog.Length(expected));
            lease.Put(text, rtf);
            Validate(); cancel.ThrowIfCancellationRequested();
            if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(x => Native.GetAsyncKeyState(x) < 0)) throw new InvalidOperationException("Release the shortcut keys first. Your text is in History.");
            lease.DispatchPaste();
            // Do not retry an uncertain paste. Restoration does not shorten when cancellation arrives.
            return await Confirm(expected, 20);
        } finally {
            if (keepClipboard) lease.Keep();
            else {
                bool restored = lease.Restore();
                for (int i = 0; !restored && i < 10; i++) { await Task.Delay(50); restored = lease.Restore(); }
                if (!restored) throw new InvalidOperationException("Clipboard restore was blocked. Keep pFlow open and check your clipboard.");
            }
        }
    }
    internal static bool ApplyPlainValue(AutomationElement field, ValuePattern value, string expected, int caret, Action validateFocus)
    {
        if (caret < 0 || caret > expected.Length) throw new ArgumentOutOfRangeException(nameof(caret));
        value.SetValue(expected);
        if (!TextProcessing.SameText(ReadText(field), expected)) { InsertionLog.Record("value: field does not read back as set"); return false; }
        var pattern = (TextPattern)field.GetCurrentPattern(TextPattern.Pattern);
        var originalSelection = pattern.GetSelection();
        if (originalSelection.Length != 1) { InsertionLog.Record("value: selections=" + originalSelection.Length); return false; }
        var document = pattern.DocumentRange;
        System.Windows.Automation.Text.TextPatternRange? position = null;
        string prefix = expected[..caret];
        if (prefix.Length == 0) {
            position = document.Clone();
            position.MoveEndpointByRange(TextPatternRangeEndpoint.End, position, TextPatternRangeEndpoint.Start);
        } else {
            // Text providers can normalize line endings and use different character units.
            // Locate the actual prefix instead of counting UTF-16 units as UIA characters.
            string lines = prefix.Replace("\r\n", "\n").Replace('\r', '\n');
            foreach (string candidate in new[] { prefix, lines, lines.Replace("\n", "\r\n"), lines.Replace('\n', '\r') }.Distinct()) {
                var found = document.FindText(candidate, false, false);
                if (found == null || found.CompareEndpoints(TextPatternRangeEndpoint.Start, document, TextPatternRangeEndpoint.Start) != 0 || !TextProcessing.SameText(found.GetText(-1), prefix)) continue;
                position = found;
                position.MoveEndpointByRange(TextPatternRangeEndpoint.Start, position, TextPatternRangeEndpoint.End);
                break;
            }
        }
        if (position == null) { InsertionLog.Record("value: caret position not found"); return false; }
        validateFocus();
        if (!TextProcessing.SameText(ReadText(field), expected)) { InsertionLog.Record("value: field changed while placing the caret"); return false; }
        var currentSelection = pattern.GetSelection();
        if (currentSelection.Length != 1
            || currentSelection[0].CompareEndpoints(TextPatternRangeEndpoint.Start, originalSelection[0], TextPatternRangeEndpoint.Start) != 0
            || currentSelection[0].CompareEndpoints(TextPatternRangeEndpoint.End, originalSelection[0], TextPatternRangeEndpoint.End) != 0) { InsertionLog.Record("value: selection moved while placing the caret"); return false; }
        position.Select();
        var selection = pattern.GetSelection();
        bool placed = selection.Length == 1 && selection[0].CompareEndpoints(TextPatternRangeEndpoint.Start, position, TextPatternRangeEndpoint.Start) == 0
            && selection[0].CompareEndpoints(TextPatternRangeEndpoint.End, position, TextPatternRangeEndpoint.End) == 0
            && TextProcessing.SameText(ReadText(field), expected);
        if (!placed) InsertionLog.Record("value: caret did not land after the text");
        return placed;
    }
    public const string Unconfirmed = "Insertion could not be confirmed; check the field before copying from History.";
    string Read() => ReadText(element);
    static string ReadText(AutomationElement field)
    {
        try { return field.TryGetCurrentPattern(TextPattern.Pattern, out var p) ? DocumentText(field, ((TextPattern)p).DocumentRange) : ""; }
        catch (ElementNotAvailableException) { return ""; }
    }
    /// Success only once the field shows the finished text; up to `tries` × 50 ms.
    async Task<string> Confirm(string expected, int tries)
    {
        var clock = Stopwatch.StartNew(); string read = "";
        for (int i = 0; i < tries; i++) {
            await Task.Delay(50); read = Read();
            if (Observed(read, expected) is { } how) { Log("confirmed (" + how + ") after " + clock.ElapsedMilliseconds + " ms"); return "Inserted"; }
        }
        Log("not confirmed after " + clock.ElapsedMilliseconds + " ms: field reads " + InsertionLog.Length(read) + ", expected " + InsertionLog.Length(expected));
        return Unconfirmed;
    }
    async Task<string> TypeUnicode(string text, string expected, CancellationToken cancel)
    {
        Validate(); cancel.ThrowIfCancellationRequested();
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(x => Native.GetAsyncKeyState(x) < 0)) throw new InvalidOperationException("Release the shortcut keys first. Your text is in History.");
        Log("path=type field " + InsertionLog.Length(before) + " -> expected " + InsertionLog.Length(expected));
        // One SendInput batch cannot interleave another input event. Never retry a partially delivered batch.
        var inputs = Native.UnicodeText(text);
        Native.Send(inputs);
        // The app takes the typed characters at its own pace: longer text gets longer to arrive.
        return await Confirm(expected, 40 + text.Length / 25);
    }
}
