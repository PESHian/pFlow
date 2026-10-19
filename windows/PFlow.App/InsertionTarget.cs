using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace PFlow.Windows;

internal sealed class InsertionTarget
{
    readonly AutomationElement element;
    readonly int[] runtimeId;
    readonly string before;
    readonly int start, length;
    readonly bool readable;
    readonly IntPtr foreground;
    readonly uint processId;
    FieldState State => new(foreground.ToInt64(), processId, string.Join(".", runtimeId), before, start, length);
    public const string SavedToHistory = "Saved to History. Open History to copy your dictation.";
    public bool CanInsert => readable;
    public string ApplicationName { get; }
    public string ApplicationId { get; }
    InsertionTarget(AutomationElement e, string text, int start, int length, bool readable)
    {
        element = e; runtimeId = e.GetRuntimeId(); before = text; this.start = start; this.length = length; this.readable = readable;
        foreground = Native.GetForegroundWindow(); Native.GetWindowThreadProcessId(foreground, out processId);
        using var process = Process.GetProcessById((int)processId); ApplicationName = process.ProcessName; ApplicationId = process.ProcessName;
    }
    static void CheckSecure(AutomationElement e)
    {
        for (AutomationElement? node = e; node != null; node = TreeWalker.ControlViewWalker.GetParent(node))
            if (node.Current.IsPassword) throw new InvalidOperationException("Dictation is off in password fields.");
    }
    public static InsertionTarget Capture()
    {
        var e = AutomationElement.FocusedElement ?? throw new InvalidOperationException("Place the cursor in a text field first.");
        CheckSecure(e);
        if (!e.Current.IsEnabled || !e.Current.IsKeyboardFocusable) return new(e, "", 0, 0, false);
        if (e.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)) {
            var tp = (TextPattern)pattern; var selections = tp.GetSelection();
            if (selections.Length != 1) return new(e, "", 0, 0, false);
            var document = tp.DocumentRange;
            if (document.GetAttributeValue(TextPattern.IsReadOnlyAttribute) is true) return new(e, "", 0, 0, false);
            string text = document.GetText(-1);
            var prefix = document.Clone(); prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, selections[0], TextPatternRangeEndpoint.Start);
            var selected = selections[0].GetText(-1); int start = prefix.GetText(-1).Length;
            return new(e, text, start, selected.Length, true);
        }
        // Unsupported fields still permit dictation, but can never receive input or clipboard data.
        return new(e, "", 0, 0, false);
    }
    void Validate()
    {
        if (Native.GetForegroundWindow() != foreground) throw new InvalidOperationException("Focus changed. Your text is in History.");
        Native.GetWindowThreadProcessId(foreground, out var current);
        var focused = AutomationElement.FocusedElement;
        if (current != processId || focused == null || !focused.GetRuntimeId().SequenceEqual(runtimeId)) throw new InvalidOperationException("Focus changed. Your text is in History.");
        CheckSecure(focused);
        var now = Capture();
        if (!now.CanInsert) throw new InvalidOperationException("This field is no longer editable. Your text is in History.");
        FieldState.RequireUnchanged(State, now.State);
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
        if (!readable) return SavedToHistory;
        Validate();
        if (start > before.Length || start + length > before.Length) throw new InvalidOperationException("The text selection could not be checked. Your text is in History.");
        var payload = Prepare(State, text, rtf);
        text = payload.Text; rtf = payload.Rtf; string expected = payload.Expected;
        // ValuePattern avoids the clipboard for plain controls that expose it.
        if (rtf == null && !keepClipboard && element.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && !((ValuePattern)value).Current.IsReadOnly) {
            ((ValuePattern)value).SetValue(expected);
            return TextProcessing.SameText(Read(), expected) ? "Inserted" : "Insertion could not be confirmed; check the field before copying from History.";
        }
        if (rtf == null && !keepClipboard) return await TypeUnicode(text, expected, cancel);
        ClipboardLease lease;
        try { lease = new ClipboardLease(clipboardOwner, !keepClipboard); }
        catch (InvalidOperationException) when (!keepClipboard) {
            // Unsupported clipboard formats never block plain dictation or change the clipboard.
            string fallback = await TypeUnicode(text, expected, cancel);
            return fallback == "Inserted" && rtf != null ? "Inserted as plain text; bold headings could not be applied safely." : fallback;
        }
        using var clipboardLifetime = lease;
        Validate(); cancel.ThrowIfCancellationRequested();
        try {
            lease.Put(text, rtf);
            Validate(); cancel.ThrowIfCancellationRequested();
            if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(x => Native.GetAsyncKeyState(x) < 0)) throw new InvalidOperationException("Release the shortcut keys first. Your text is in History.");
            lease.DispatchPaste();
            // Do not retry an uncertain paste. Restoration does not shorten when cancellation arrives.
            for (int i = 0; i < 20; i++) { await Task.Delay(50); if (TextProcessing.SameText(Read(), expected)) return "Inserted"; }
            return "Insertion could not be confirmed; check the field before copying from History.";
        } finally {
            if (keepClipboard) lease.Keep();
            else {
                bool restored = lease.Restore();
                for (int i = 0; !restored && i < 10; i++) { await Task.Delay(50); restored = lease.Restore(); }
                if (!restored) throw new InvalidOperationException("Clipboard restore was blocked. Keep pFlow open and check your clipboard.");
            }
        }
    }
    string Read()
    {
        try { return element.TryGetCurrentPattern(TextPattern.Pattern, out var p) ? ((TextPattern)p).DocumentRange.GetText(-1) : ""; }
        catch (ElementNotAvailableException) { return ""; }
    }
    async Task<string> TypeUnicode(string text, string expected, CancellationToken cancel)
    {
        Validate(); cancel.ThrowIfCancellationRequested();
        if (new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(x => Native.GetAsyncKeyState(x) < 0)) throw new InvalidOperationException("Release the shortcut keys first. Your text is in History.");
        // One SendInput batch cannot interleave another input event. Never retry a partially delivered batch.
        var inputs = Native.UnicodeText(text);
        Native.Send(inputs);
        for (int i = 0; i < 40; i++) { await Task.Delay(50); if (PFlow.Core.TextProcessing.SameText(Read(), expected)) return "Inserted"; }
        return "Insertion could not be confirmed; check the field before copying from History.";
    }
}
