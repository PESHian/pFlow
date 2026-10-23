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
    /// The finished text over the selection pFlow made of its own live words, through the same checked path.
    Task<string> InsertOverSelection(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf = null) =>
        Task.FromResult("The field changed. Your text is in History.");
}

internal sealed class InsertionTarget : IInsertionTarget
{
    readonly AutomationElement element;
    readonly int[] runtimeId;
    readonly string before;
    readonly int start, length;
    readonly bool readable;
    /// A Chromium host (Chrome, Edge, Electron apps) builds its accessibility
    /// tree only when asked; until then the focus is its placeholder pane, which
    /// says nothing about the field under the caret. Such a take is knocked for
    /// the tree and captured again during the take and once more at insert
    /// time. If the pane is all there is even then, the words go in the way a
    /// person's typing would, without a check, and the status says so (the
    /// 0.1.19 behaviour the owner's PC relies on). A built tree that shows a
    /// non-editable element is a refusal, never typing. What stays unseen
    /// behind a pane that never gives way: a password box takes the words as
    /// dots, a page with no box focused gets keystrokes, and line breaks go in
    /// as spaces (Enter could send or submit).
    readonly bool placeholder;
    readonly IntPtr foreground;
    readonly uint processId;
    /// An app UI Automation cannot read (WeakField): read and checked its own way, or pasted unchecked.
    readonly WeakField? weak;
    FieldState State => new(foreground.ToInt64(), processId, string.Join(".", runtimeId), before, start, length);
    public const string SavedToHistory = "Saved to History. Open History to copy your dictation.";
    public const string Unreachable = "Couldn't reach that box. Your words are in History.";
    public const string Unchecked = "Typed into the app; it did not let pFlow check the result. Look at the field before copying from History.";
    /// Words pasted into an editable field pFlow cannot read (WeakField.Kinds.PasteOnly).
    public const string Pasted = "Pasted into the app; pFlow could not check it.";
    /// The one rule: these outcomes went into the app without a check. A done take, no card, no balloon.
    internal static bool WentInUnchecked(string status) => status.StartsWith(Unchecked, StringComparison.Ordinal) || status.StartsWith(Pasted, StringComparison.Ordinal);
    /// Chromium's top-level window class (Chrome, Edge, Electron) and its legacy content window.
    static readonly string[] ChromiumHosts = ["Chrome_WidgetWin_1", "Chrome_RenderWidgetHostHWND"];
    public const string PlainOnly = "Inserted as plain text; bold headings could not be applied safely.";
    public bool CanInsert => readable || placeholder || weak != null;
    /// Chromium's placeholder pane: worth capturing again shortly (see `placeholder`).
    internal bool Placeholder => placeholder;
    public string ApplicationName { get; }
    public string ApplicationId { get; }
    /// The preview's "Typing in …" note for this app.
    internal string TypingNote { get; }
    /// Control kind, window class and UI framework of the field, for the insertion log. No text.
    internal string Kind { get; }
    /// Why the field cannot take text, for the log; null when it can.
    internal string? Refusal { get; }
    InsertionTarget(AutomationElement e, string text, int start, int length, bool readable, string? refusal, WeakField? weak = null)
    {
        element = e; runtimeId = e.GetRuntimeId(); before = text; this.start = start; this.length = length; this.readable = readable; Refusal = refusal; this.weak = weak;
        foreground = Native.GetForegroundWindow(); Native.GetWindowThreadProcessId(foreground, out processId);
        placeholder = !readable && refusal != null && ChromiumFocused();
        if (placeholder) { Refusal = refusal + "; Chromium placeholder pane"; Knock(); }
        using var process = Process.GetProcessById((int)processId); ApplicationName = process.ProcessName; ApplicationId = process.ProcessName;
        TypingNote = TypingNoteFor(processId, ApplicationName); Kind = Describe(e) + (weak == null ? "" : " via " + weak.Kind);
    }
    /// The classic screen-reader knock on the focused Chromium window: WM_GETOBJECT
    /// with OBJID_CLIENT, which is what makes Chromium start building its tree.
    void Knock()
    {
        IntPtr control = LiveTextField.FocusedControl(foreground);
        if (control == IntPtr.Zero) return;
        var iid = new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");
        if (AccessibleObjectFromWindow(control, 0xFFFFFFFC, ref iid, out IntPtr accessible) == 0 && accessible != IntPtr.Zero) Marshal.Release(accessible);
    }
    [System.Runtime.InteropServices.DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId, ref Guid iid, out IntPtr accessible);
    /// The same window and process as this capture: a later capture may stand in for it.
    internal bool SameWindow(InsertionTarget other) => other.foreground == foreground && other.processId == processId;
    /// The keyboard focus sits in a Chromium window whose tree is not built: the
    /// focused element is Chromium's placeholder pane, not a field and not a page.
    bool ChromiumFocused()
    {
        if (!ChromiumHosts.Contains(LiveTextField.ClassName(LiveTextField.FocusedControl(foreground)))) return false;
        try { return element.Current.FrameworkId == "Chrome" && element.Current.ControlType == ControlType.Pane; }
        catch (Exception error) when (error is ElementNotAvailableException or COMException) { return false; }
    }
    /// "ControlType/class/framework". Only known classes are named (PrivateLog.ClassLabel); a web page's
    /// class names are the site's own text, so for Chromium (browsers, Electron apps) none is recorded.
    static string Describe(AutomationElement e)
    {
        try {
            var c = e.Current; string framework = c.FrameworkId is "Win32" or "WPF" or "XAML" or "WinForm" or "Chrome" or "DirectUI" ? c.FrameworkId : "other";
            return c.ControlType.ProgrammaticName.Replace("ControlType.", "") + "/" + (framework == "Chrome" ? "-" : PrivateLog.ClassLabel(c.ClassName)) + "/" + framework;
        }
        catch (Exception error) when (error is ElementNotAvailableException or COMException) { return "unavailable"; }
    }
    /// Only the classic Win32 providers set a field's whole value in place
    /// reliably (an Edit control's WM_SETTEXT). Browsers, UWP and Electron
    /// fields take typed input instead, like a person typing.
    bool Win32 { get { try { return element.Current.FrameworkId == "Win32"; } catch (Exception error) when (error is ElementNotAvailableException or COMException) { return false; } } }
    /// The app as logs and reports name it (one rule: PrivateLog.AppLabel).
    internal string LogName => PrivateLog.AppLabel(ApplicationName);
    void Log(string line) => InsertionLog.Record("insert " + LogName + " " + Kind + ": " + line);
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
    internal ILiveTextField? LiveField() => LiveField(out _);
    /// What the diagnostic report and insertion.log say for a browser field.
    internal const string BrowserNote = "live typing: not available in this app (browser)";
    /// The field live words can be typed into: a Win32 edit or rich edit control (range writes), else a
    /// readable Chrome or Edge web field (typed characters); null with the reason otherwise.
    internal ILiveTextField? LiveField(out string why)
    {
        if (!readable) { why = placeholder ? "Chromium placeholder pane (field not readable yet)" : "field not readable: " + Refusal; return null; }
        if (LiveTextField.Create(element, foreground, processId, out why) is { } win32) return win32;
        string win32Why = why;
        // Chrome and Edge: live words as typed keys, replaced by the finished text at the end (LiveKeyField).
        // With LiveKeyField off, browsers get no live typing (0.1.27: the finished text goes in at the end).
        if (!LiveKeyField.Enabled) {
            bool browser;
            try { browser = element.Current.FrameworkId == "Chrome"; } catch (Exception error) when (error is ElementNotAvailableException or COMException) { browser = false; }
            why = browser ? BrowserNote : win32Why;
            return null;
        }
        try { if (LiveKeyField.Create(element, foreground, processId, ApplicationName, out why) is { } web) return web; }
        catch (Exception error) { why = "web field check failed (" + error.GetType().Name + ")"; }
        why = win32Why + "; " + why;
        return null;
    }
    internal string DescribeLiveField() => LiveTextField.Describe(element, foreground);
    /// What the capture saw, for the diagnostic report: kinds, classes, patterns and yes/no only; never
    /// the field's text, its name or label, or a window title.
    internal DiagField[] Diagnose()
    {
        string patterns = "unreadable"; bool? password = null, focusable = null;
        try {
            patterns = string.Join(",", element.GetSupportedPatterns().Select(p => p.ProgrammaticName.Replace("PatternIdentifiers.Pattern", "")).Order(StringComparer.Ordinal));
            password = element.Current.IsPassword; focusable = element.Current.IsKeyboardFocusable;
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { }
        IntPtr control = LiveTextField.FocusedControl(foreground);
        return [new("app", LogName), new("appIntegrity", DiagnosticEnvironment.IntegrityName(LiveTextField.Integrity(processId))),
            new("pflowIntegrity", DiagnosticEnvironment.IntegrityName(LiveTextField.Integrity(0))), new("field", Kind),
            new("focusedControl", control == IntPtr.Zero ? "none" : PrivateLog.ClassLabel(LiveTextField.BaseClass(control))), new("patterns", patterns), new("password", password),
            new("keyboardFocusable", focusable), new("readable", readable), new("placeholder", placeholder), new("weakField", weak?.Describe() ?? "none"), new("refusal", Refusal),
            new("keyboardLayout", DiagnosticEnvironment.ForegroundLayout(foreground))];
    }
    static void CheckSecure(AutomationElement e)
    {
        for (AutomationElement? node = e; node != null; node = TreeWalker.ControlViewWalker.GetParent(node))
            if (node.Current.IsPassword) throw new InvalidOperationException("Dictation is off in password fields.");
    }
    public const string OwnWindow = "Click in the app where the words should go, then dictate. The cursor was in pFlow's own window.";
    /// pFlow's floating windows (the words card, the recording control, the live text card): never a
    /// target, because one that hides at take start would hand the take to whatever Windows activates
    /// next. Settings' own editable fields (templates, dictionary) are not listed and work as before.
    internal static readonly HashSet<IntPtr> RefusedWindows = [];
    internal static bool Refused(IntPtr window) => window != IntPtr.Zero && RefusedWindows.Contains(window);
    /// `foreground` stands in for the real foreground window in a test (a test process started by a
    /// scheduled task is never allowed to bring its own window to the front).
    public static InsertionTarget Capture(Func<IntPtr>? foreground = null)
    {
        IntPtr front = foreground != null ? foreground() : Native.GetForegroundWindow();
        if (Refused(front)) throw new InvalidOperationException(OwnWindow);
        var e = AutomationElement.FocusedElement ?? throw new InvalidOperationException("Place the cursor in a text field first.");
        if (e.Current.ProcessId == Environment.ProcessId && Refused((IntPtr)e.Current.NativeWindowHandle)) throw new InvalidOperationException(OwnWindow);
        CheckSecure(e);
        bool focusable = e.Current.IsEnabled && e.Current.IsKeyboardFocusable;
        if (focusable && e.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)) {
            var tp = (TextPattern)pattern; var selections = tp.GetSelection();
            if (selections.Length != 1) return new(e, "", 0, 0, false, "selections=" + selections.Length);
            var document = tp.DocumentRange;
            if (document.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is true) return new(e, "", 0, 0, false, "read-only");
            string text = DocumentText(e, document);
            var prefix = document.Clone(); prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, selections[0], TextPatternRangeEndpoint.Start);
            var selected = selections[0].GetText(-1); int start = Math.Min(DocumentText(e, prefix).Length, text.Length);
            return new(e, text, start, Math.Min(selected.Length, text.Length - start), true, null);
        }
        string refusal = focusable ? "no text pattern" : "disabled or not keyboard-focusable";
        // An app UI Automation cannot read (LibreOffice, Notepad++): its own accessibility or messages, else a
        // checked paste. Never in a Chromium window (browsers, Electron apps), which keep their own path.
        if (!ChromiumWindow(front)) {
            var weak = WeakField.Find(front, e, out string why);
            if (weak is { Protected: true }) throw new InvalidOperationException("Dictation is off in password fields.");
            if (weak != null) {
                var state = weak.State();
                return new(e, state?.Text ?? "", state?.Start ?? 0, state?.Length ?? 0, state != null, null, weak);
            }
            refusal += "; " + why;
        }
        // Unsupported fields still permit dictation, but can never receive input or clipboard data.
        return new(e, "", 0, 0, false, refusal);
    }
    /// The window or its focused control is Chromium's (Chrome, Edge, Electron apps).
    static bool ChromiumWindow(IntPtr window) =>
        ChromiumHosts.Contains(LiveTextField.ClassName(window)) || ChromiumHosts.Contains(LiveTextField.ClassName(LiveTextField.FocusedControl(window)));
    /// A Chromium field with nothing in it reports its label as its text (the
    /// value is empty): that is no text. Every other field reads as it is.
    internal static string DocumentText(AutomationElement e, TextPatternRange range)
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
        try {
            if (placeholder) return await InsertBehindPlaceholder(text, clipboardOwner, keepClipboard, cancel, rtf);
            if (weak != null) return await DeliverWeak(weak, text, clipboardOwner, keepClipboard, cancel, rtf);
            if (!readable) { Log("saved to History: " + Refusal); return SavedToHistory; }
            return await Deliver(text, clipboardOwner, keepClipboard, cancel, rtf);
        } catch (Exception error) when (error is not OperationCanceledException) { Log("refused: " + error.Message); throw; }
    }
    /// The end of a take with live words in a browser field: pFlow's own words are selected (LiveKeyField,
    /// no keys). The same field, read again now, with that selection, takes the finished text the 0.1.27
    /// way (typed, or pasted with line breaks), checked against what it then shows.
    public async Task<string> InsertOverSelection(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf = null)
    {
        cancel.ThrowIfCancellationRequested();
        var now = Capture();
        if (!SameWindow(now) || !now.runtimeId.SequenceEqual(runtimeId)) throw new InvalidOperationException("Focus changed. Your text is in History.");
        if (!now.readable || now.placeholder || now.weak != null || now.length == 0) throw new InvalidOperationException("The field changed. Your text is in History.");
        now.Log("over pFlow's selection: field " + InsertionLog.Length(now.before) + ", selection at " + now.start + "+" + now.length
            + (now.start > 0 && char.IsWhiteSpace(now.before[now.start - 1]) ? ", space before" : "") + (char.IsWhiteSpace(now.before[now.start]) ? ", starts with a space" : ""));
        try { return await now.Deliver(text, clipboardOwner, keepClipboard, cancel, rtf); }
        catch (Exception error) when (error is not OperationCanceledException) { now.Log("refused: " + error.Message); throw; }
    }
    /// The tree had the whole take to arrive, and gets a little longer now: a
    /// readable field takes the checked path (and a password field is refused);
    /// a built tree with nothing editable under the caret is a refusal; a pane
    /// that never gives way is typed into without a check.
    async Task<string> InsertBehindPlaceholder(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf)
    {
        var again = Capture();
        for (int look = 0; look < 3 && again.placeholder && SameWindow(again); look++) {
            await Task.Delay(250); cancel.ThrowIfCancellationRequested();
            again = Capture();
        }
        if (!SameWindow(again)) throw new InvalidOperationException("Focus changed. Your text is in History.");
        if (again.readable) { Log("placeholder: field readable at insert time: " + again.Kind); return await again.Deliver(text, clipboardOwner, keepClipboard, cancel, rtf); }
        if (!again.placeholder) { Log("placeholder: tree built, nothing editable at insert time: " + again.Refusal); return SavedToHistory; }
        Log("placeholder pane at insert time: " + Refusal + "; typed without a check");
        return await TypeUnchecked(text, clipboardOwner, keepClipboard, cancel, rtf);
    }
    /// The same app, window and focused Chromium control as when the take began; the field itself cannot be read.
    void ValidateHost()
    {
        if (Native.GetForegroundWindow() != foreground) throw new InvalidOperationException("Focus changed. Your text is in History.");
        Native.GetWindowThreadProcessId(foreground, out var current);
        if (current != processId || !ChromiumHosts.Contains(LiveTextField.ClassName(LiveTextField.FocusedControl(foreground)))) throw new InvalidOperationException("Focus changed. Your text is in History.");
    }
    /// Keystrokes into the field pFlow cannot read back: Chromium's pane,
    /// knocked and captured again, still hid the field under the caret. The
    /// words go in the way a person's typing would, on one line: a box pFlow
    /// cannot see may be a chat box that sends on Enter or a form box that
    /// submits on Enter or Shift+Enter, so line breaks become spaces here. The
    /// clipboard is not used, so a busy page can never paste something else
    /// late. The result is not checked, and the status says so; History keeps
    /// the text with its line breaks.
    async Task<string> TypeUnchecked(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf)
    {
        ValidateHost(); cancel.ThrowIfCancellationRequested();
        RequireNoShortcutKeys();
        string line = OneLine(text); bool flattened = text.IndexOfAny(['\n', '\r']) >= 0;
        Log("path=unchecked typing " + InsertionLog.Length(line) + (flattened ? " line breaks as spaces" : ""));
        Native.Send(Native.UnicodeText(line));
        await Task.Delay(100);
        string status = Unchecked;
        if (flattened) status += " Line breaks arrived as spaces.";
        if (rtf != null) status += " Template styles arrived as plain text.";
        if (keepClipboard) {
            // "Copy dictation to clipboard": the words, once, after they went in.
            try { ClipboardLease.KeepCopy(clipboardOwner, text); }
            catch (Exception error) when (error is InvalidOperationException or OutOfMemoryException) { Log("copy to clipboard failed: " + error.Message); status += " It could not be copied to the clipboard."; }
        }
        return status;
    }
    /// Shift, Ctrl, Alt or Windows still held would turn the words into shortcuts.
    static void RequireNoShortcutKeys()
    {
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(x => Native.GetAsyncKeyState(x) < 0)) throw new InvalidOperationException("Release the shortcut keys first. Your text is in History.");
    }
    /// The text on one line for a box pFlow cannot see: every run of line
    /// breaks, with the spaces around it, becomes one space.
    internal static string OneLine(string text) =>
        System.Text.RegularExpressions.Regex.Replace(text.Replace("\r\n", "\n").Replace('\r', '\n'), "[ \t]*\n+[ \t]*", " ").Trim();
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
            return applied ? "Inserted" : Unmatched(before, Read());
        }
        // Typed keystrokes turn a line break into Enter, which sends the message in chat apps and
        // web forms: only Win32 controls, or text without a line break, are typed. The rest is pasted.
        bool typeable = TypingSafe(Win32, text);
        if (rtf == null && !keepClipboard && typeable) return await TypeUnicode(text, expected, cancel);
        ClipboardLease lease;
        try { lease = new ClipboardLease(clipboardOwner, !keepClipboard); }
        catch (InvalidOperationException error) when (!keepClipboard && typeable) {
            // Unsupported clipboard formats never block plain dictation or change the clipboard.
            Log("clipboard not saved (" + error.Message + "); typing instead");
            string fallback = await TypeUnicode(text, expected, cancel);
            return fallback == "Inserted" && rtf != null ? PlainOnly : fallback;
        }
        return await Paste(lease, text, rtf, keepClipboard, "path=clipboard keep=" + keepClipboard + " rich=" + (rtf != null) + " field " + InsertionLog.Length(before) + " -> expected " + InsertionLog.Length(expected),
            () => Confirm(expected, 20), () => false, cancel);
    }
    /// The one paste: checks before and after the clipboard is set, Ctrl+V, the result's own check, then the
    /// person's clipboard back unless they asked to keep the words or `keepOurs` says the app may still read it.
    async Task<string> Paste(ClipboardLease lease, string text, string? rtf, bool keepClipboard, string log, Func<Task<string>> confirm, Func<bool> keepOurs, CancellationToken cancel)
    {
        using var clipboardLifetime = lease;
        Validate(); cancel.ThrowIfCancellationRequested();
        try {
            Log(log);
            lease.Put(text, rtf);
            Validate(); cancel.ThrowIfCancellationRequested();
            RequireNoShortcutKeys();
            lease.DispatchPaste();
            // Do not retry an uncertain paste. Restoration does not shorten when cancellation arrives.
            return await confirm();
        } finally {
            if (keepClipboard || keepOurs()) lease.Keep();
            else {
                bool restored = lease.Restore();
                for (int i = 0; !restored && i < 10; i++) { await Task.Delay(50); restored = lease.Restore(); }
                if (!restored) throw new InvalidOperationException("Clipboard restore was blocked. Keep pFlow open and check your clipboard.");
            }
        }
    }
    /// An app UI Automation cannot read: always pasted (typed keys would meet the app's autocorrect), then
    /// checked in what the app shows where it can be read; otherwise the status says it was not checked.
    async Task<string> DeliverWeak(WeakField field, string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf)
    {
        Validate();
        string expected;
        if (readable) {
            if (start > before.Length || start + length > before.Length) throw new InvalidOperationException("The text selection could not be checked. Your text is in History.");
            var payload = Prepare(State, text, rtf); text = payload.Text; rtf = payload.Rtf; expected = payload.Expected;
        } else expected = text;
        string? shownBefore = field.Shown();
        var lease = new ClipboardLease(clipboardOwner, !keepClipboard);
        bool busy = false;
        string path = "path=" + field.Kind + " paste keep=" + keepClipboard + " rich=" + (rtf != null) + " field " + InsertionLog.Length(before) + " -> expected " + InsertionLog.Length(expected) + (shownBefore == null ? " unreadable" : "");
        return await Paste(lease, text, rtf, keepClipboard, path, async () => {
            if (shownBefore != null) {
                var clock = Stopwatch.StartNew(); string? now = null;
                for (int i = 0; i < 40; i++) {
                    await Task.Delay(50); now = field.Shown();
                    if (now != null && ShownText.Landed(shownBefore, now, expected)) { Log("confirmed in what the app shows after " + clock.ElapsedMilliseconds + " ms"); return "Inserted"; }
                }
                Log("not confirmed after " + clock.ElapsedMilliseconds + " ms: app shows " + InsertionLog.Length(now ?? "") + ", before " + InsertionLog.Length(shownBefore));
                return now != null && shownBefore.Length > 0 && ShownText.Plain(now) == ShownText.Plain(shownBefore) ? NothingLanded : Unconfirmed;
            }
            // Nothing to read: give the app time to take the paste before the clipboard goes back. An app
            // that stops answering keeps pFlow's words on the clipboard, so a late paste is still the words.
            await Task.Delay(300);
            busy = !field.Responding(2000);
            if (!busy) await Task.Delay(500);
            Log("pasted, not checked" + (busy ? "; the app did not answer, clipboard kept" : ""));
            return busy ? Pasted + " The app was busy, so your words are also still on the clipboard." : Pasted;
        }, () => busy, cancel);
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
    /// The write went out and the field still reads exactly as before: nothing landed, so the take is not quiet.
    public const string NothingLanded = "The app did not take the text. Your words are in History.";
    /// A failed check means one of two things: the field changed in a way pFlow could not match
    /// (the words are most likely there, late or restyled) or it did not change at all. A field
    /// that was empty before, or reads back empty now, cannot be told apart from one that reads
    /// back late, so only a non-empty field that still holds its old text counts as nothing landed.
    internal static string Unmatched(string before, string read) => before.Length > 0 && read.Length > 0 && TextProcessing.SameText(read, before) ? NothingLanded : Unconfirmed;
    /// One rule: keystrokes are safe for a Win32 control, or for text with no line break anywhere else.
    internal static bool TypingSafe(bool win32, string text) => win32 || (!text.Contains('\n') && !text.Contains('\r'));
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
        return Unmatched(before, read);
    }
    async Task<string> TypeUnicode(string text, string expected, CancellationToken cancel)
    {
        Validate(); cancel.ThrowIfCancellationRequested();
        RequireNoShortcutKeys();
        Log("path=type field " + InsertionLog.Length(before) + " -> expected " + InsertionLog.Length(expected));
        // One SendInput batch cannot interleave another input event. Never retry a partially delivered batch.
        var inputs = Native.UnicodeText(text);
        Native.Send(inputs);
        // The app takes the typed characters at its own pace: longer text gets longer to arrive.
        return await Confirm(expected, 40 + text.Length / 25);
    }
}
