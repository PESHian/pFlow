using System.Text;
using System.Windows.Automation;
using Accessibility;

namespace PFlow.Windows;

/// The focused field of an app UI Automation cannot read (LibreOffice, Scintilla editors such as
/// Notepad++, older toolkits). Three kinds, best first:
/// - Accessible: the app answers IAccessible2 (LibreOffice's bridge). The caret paragraph's text and
///   caret come from IAccessibleText, and the result is read back from the paragraphs on screen.
/// - Scintilla: the editor control answers its own messages: whole text, selection.
/// - PasteOnly: an editable text or document the app names through MSAA or UI Automation, with no
///   way to read it. The words are pasted and the status says pFlow could not check them.
/// A password box (UI Automation IsPassword or MSAA protected) is reported as Protected and never
/// written to. Every call into the app goes behind a "still responding" check: COM calls into a hung
/// app would hang pFlow.
internal sealed class WeakField
{
    internal enum Kinds { Accessible, Scintilla, PasteOnly }
    const int OBJID_CLIENT = unchecked((int)0xFFFFFFFC), WM_NULL = 0, WM_GETTEXT = 0x000D, WM_GETTEXTLENGTH = 0x000E;
    const int SCI_GETSELECTIONSTART = 2143, SCI_GETSELECTIONEND = 2145, SCI_GETCODEPAGE = 2137, SCI_GETREADONLY = 2140;
    const int ROLE_TEXT = 42, ROLE_DOCUMENT = 15;
    const int STATE_UNAVAILABLE = 0x1, STATE_FOCUSED = 0x4, STATE_READONLY = 0x40, STATE_FOCUSABLE = 0x100000, STATE_PROTECTED = 0x20000000;
    const uint SMTO_ABORTIFHUNG = 0x2, SMTO_ERRORONEXIT = 0x20, WaitMs = 500;
    static readonly Guid IAccessibleId = new("618736E0-3C3D-11CF-810C-00AA00389B71"), IAccessibleTextId = new("24FD2FFB-3AAD-4a08-8335-A3AD89C0FB4B");

    internal Kinds Kind { get; }
    internal bool Protected { get; }
    readonly IntPtr control;
    readonly IAccessible? accessible;
    readonly IAccessibleText? text;
    readonly int role, state;

    WeakField(Kinds kind, IntPtr control, IAccessible? accessible, IAccessibleText? text, int role, int state, bool secret)
    {
        Kind = kind; this.control = control; this.accessible = accessible; this.text = text; this.role = role; this.state = state; Protected = secret;
    }

    /// Roles and states as numbers, for the log and the report. No text.
    internal string Describe() => Kind + " role=" + role + " state=0x" + state.ToString("x");

    /// The app still answers messages within half a second.
    internal static bool Responding(IntPtr window, uint wait = WaitMs) =>
        window != IntPtr.Zero && SendMessageTimeout(window, WM_NULL, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, wait, out _) != IntPtr.Zero;
    internal bool Responding(uint wait) => Responding(control, wait);

    /// The focused field behind `window`'s focused control, or null with the reason.
    internal static WeakField? Find(IntPtr window, AutomationElement focused, out string why)
    {
        IntPtr control = LiveTextField.FocusedControl(window);
        if (control == IntPtr.Zero) { why = "no focused control"; return null; }
        if (!Responding(control)) { why = "the app is not responding"; return null; }
        bool uiaPassword = false;
        try { uiaPassword = focused.Current.IsPassword; } catch (Exception error) when (error is ElementNotAvailableException or COMException) { }
        // MSAA's focused object: down from the control's client object through accFocus.
        IAccessible? acc = null; int child = 0, role = 0, state = 0;
        try {
            var iid = IAccessibleId;
            if (AccessibleObjectFromWindow(control, OBJID_CLIENT, ref iid, out object root) == 0) acc = root as IAccessible;
            for (int depth = 0; acc != null && depth < 12; depth++) {
                object? next;
                try { next = acc.accFocus; } catch (COMException) { next = null; }
                if (next is IAccessible deeper && !ReferenceEquals(deeper, acc)) { acc = deeper; continue; }
                if (next is int id && id != 0) child = id;
                break;
            }
            // Some apps answer accFocus only after their focus events reached the bridge (LibreOffice's dialogs):
            // then the focused object is found by its FOCUSED state, a bounded walk down from the client.
            if (acc != null && child == 0 && ((acc.get_accState(0) is int own ? own : 0) & STATE_FOCUSED) == 0) {
                int budget = 400;
                if (FocusedBelow(acc, 0, ref budget) is { } below) acc = below;
            }
            if (acc != null) {
                role = acc.get_accRole(child) is int r ? r : 0;
                state = acc.get_accState(child) is int s ? s : 0;
            }
        } catch (Exception error) when (error is COMException or InvalidCastException or ArgumentException or UnauthorizedAccessException) { acc = null; }
        bool secret = uiaPassword || (state & STATE_PROTECTED) != 0;
        if (secret) { why = "password"; return new(Kinds.PasteOnly, control, acc, null, role, state, true); }
        bool usable = (state & (STATE_UNAVAILABLE | STATE_READONLY)) == 0;
        string kind = LiveTextField.BaseClass(control);
        if (kind.Equals("Scintilla", StringComparison.OrdinalIgnoreCase)) {
            if (Message(control, SCI_GETREADONLY) is not 0) { why = "Scintilla: read-only"; return null; }
            why = "ok"; return new(Kinds.Scintilla, control, acc, null, role, state, false);
        }
        if (acc != null && child == 0 && (state & STATE_FOCUSED) != 0 && usable && TextOf(acc) is { } readable) {
            why = "ok"; return new(Kinds.Accessible, control, acc, readable, role, state, false);
        }
        bool msaaEditable = acc != null && (role is ROLE_TEXT or ROLE_DOCUMENT) && (state & (STATE_FOCUSED | STATE_FOCUSABLE)) == (STATE_FOCUSED | STATE_FOCUSABLE) && usable;
        bool uiaEditable = false;
        try {
            var c = focused.Current;
            uiaEditable = (c.ControlType == ControlType.Edit || c.ControlType == ControlType.Document) && c.IsEnabled && c.IsKeyboardFocusable && c.HasKeyboardFocus
                && !(focused.TryGetCurrentPattern(ValuePattern.Pattern, out var value) && ((ValuePattern)value).Current.IsReadOnly);
        } catch (Exception error) when (error is ElementNotAvailableException or COMException or InvalidOperationException) { }
        if (msaaEditable || uiaEditable) { why = "ok"; return new(Kinds.PasteOnly, control, acc, null, role, state, false); }
        why = "not an editable field (MSAA role " + role + ", state 0x" + state.ToString("x") + ")";
        return null;
    }

    /// The deepest descendant whose state says FOCUSED, at most 8 levels and `budget` objects down.
    static IAccessible? FocusedBelow(IAccessible parent, int depth, ref int budget)
    {
        if (depth >= 8 || budget <= 0) return null;
        int count = parent.accChildCount;
        if (count <= 0 || count > 500) return null;
        var children = new object[count];
        if (AccessibleChildren(parent, 0, count, children, out int got) != 0) return null;
        foreach (var item in children.Take(got)) {
            if (item is not IAccessible child || --budget <= 0) continue;
            int state = child.get_accState(0) is int s ? s : 0;
            if ((state & STATE_FOCUSED) != 0) return FocusedBelow(child, depth + 1, ref budget) ?? child;
            if (FocusedBelow(child, depth + 1, ref budget) is { } deeper) return deeper;
        }
        return null;
    }

    /// The text around the caret and the selection in it: the caret paragraph (Accessible) or the
    /// whole document (Scintilla). Null when it cannot be read.
    internal (string Text, int Start, int Length)? State()
    {
        if (!Responding(control)) return null;
        try {
            if (Kind == Kinds.Accessible && text != null) {
                string? value = Read(text); if (value == null) return null;
                if (text.get_caretOffset(out int caret) != 0 || caret < 0 || caret > value.Length) return null;
                int start = caret, length = 0;
                if (text.get_nSelections(out int count) == 0 && count > 0 && text.get_selection(0, out int a, out int b) == 0) {
                    start = Math.Clamp(Math.Min(a, b), 0, value.Length); length = Math.Clamp(Math.Max(a, b), 0, value.Length) - start;
                }
                return (value, start, length);
            }
            if (Kind == Kinds.Scintilla) {
                string? value = WindowText(); if (value == null) return null;
                if (Message(control, SCI_GETSELECTIONSTART) is not int a || Message(control, SCI_GETSELECTIONEND) is not int b || Message(control, SCI_GETCODEPAGE) is not int page) return null;
                byte[] bytes = Encoding.UTF8.GetBytes(value);
                // Scintilla counts bytes of its own encoding: UTF-8, or one byte per character for plain ASCII text.
                if (page != 65001 && bytes.Length != value.Length) return null;
                if (a < 0 || b < a || b > bytes.Length) return null;
                int start = Encoding.UTF8.GetCharCount(bytes, 0, a);
                return (value, start, Encoding.UTF8.GetCharCount(bytes, 0, b) - start);
            }
        } catch (Exception error) when (error is COMException or InvalidCastException or ArgumentException) { }
        return null;
    }

    /// What the app shows now, to look for the inserted words in: the paragraphs on screen around the
    /// caret (Accessible; one per line) or the whole text (Scintilla). Null for a field pFlow cannot read.
    internal string? Shown()
    {
        if (!Responding(control)) return null;
        try {
            if (Kind == Kinds.Scintilla) return WindowText();
            if (Kind != Kinds.Accessible || accessible == null || text == null) return null;
            if (accessible.accParent is IAccessible parent && parent.accChildCount is int count && count > 0 && count < 5000) {
                var children = new object[count];
                if (AccessibleChildren(parent, 0, count, children, out int got) == 0) {
                    var parts = new List<string>();
                    foreach (var item in children.Take(got)) if (item is IAccessible paragraph && TextOf(paragraph) is { } t && Read(t) is { } s) parts.Add(s);
                    if (parts.Count > 0) return string.Join("\n", parts);
                }
            }
            return Read(text);
        } catch (Exception error) when (error is COMException or InvalidCastException or ArgumentException) { return null; }
    }

    static string? Read(IAccessibleText t) =>
        t.get_nCharacters(out int n) == 0 && n >= 0 && n < 4_000_000 ? n == 0 ? "" : t.get_text(0, n, out string value) == 0 ? value ?? "" : null : null;

    static IAccessibleText? TextOf(object accessible)
    {
        if (accessible is not IServiceProviderCom provider) return null;
        Guid service = IAccessibleId, interfaceId = IAccessibleTextId;
        if (provider.QueryService(ref service, ref interfaceId, out IntPtr pointer) != 0 || pointer == IntPtr.Zero) return null;
        try { return Marshal.GetObjectForIUnknown(pointer) as IAccessibleText; } finally { Marshal.Release(pointer); }
    }

    string? WindowText()
    {
        if (SendMessageTimeout(control, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, WaitMs, out IntPtr length) == IntPtr.Zero) return null;
        long size = length.ToInt64(); if (size < 0 || size > 16_000_000) return null;
        var buffer = new StringBuilder((int)size + 2);
        if (SendMessageTimeout(control, WM_GETTEXT, new IntPtr(buffer.Capacity), buffer, SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, WaitMs * 4, out _) == IntPtr.Zero) return null;
        return buffer.ToString();
    }

    static int? Message(IntPtr control, int message) =>
        SendMessageTimeout(control, message, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, WaitMs, out IntPtr result) == IntPtr.Zero ? null : (int)result.ToInt64();

    [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr window, int objectId, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object accessible);
    [DllImport("oleacc.dll")] static extern int AccessibleChildren(IAccessible container, int start, int count, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.Struct, SizeParamIndex = 2)] object[] children, out int obtained);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeout(IntPtr window, int message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr window, int message, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out IntPtr result);

    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IServiceProviderCom { [PreserveSig] int QueryService(ref Guid service, ref Guid riid, out IntPtr result); }

    /// IAccessible2's IAccessibleText, in vtable order up to get_nCharacters (the methods after it are never called).
    [ComImport, Guid("24FD2FFB-3AAD-4a08-8335-A3AD89C0FB4B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAccessibleText
    {
        [PreserveSig] int addSelection(int start, int end);
        [PreserveSig] int get_attributes(int offset, out int start, out int end, [MarshalAs(UnmanagedType.BStr)] out string attributes);
        [PreserveSig] int get_caretOffset(out int offset);
        [PreserveSig] int get_characterExtents(int offset, int coordinates, out int x, out int y, out int width, out int height);
        [PreserveSig] int get_nSelections(out int count);
        [PreserveSig] int get_offsetAtPoint(int x, int y, int coordinates, out int offset);
        [PreserveSig] int get_selection(int index, out int start, out int end);
        [PreserveSig] int get_text(int start, int end, [MarshalAs(UnmanagedType.BStr)] out string text);
        [PreserveSig] int get_textBeforeOffset(int offset, int boundary, out int start, out int end, [MarshalAs(UnmanagedType.BStr)] out string text);
        [PreserveSig] int get_textAfterOffset(int offset, int boundary, out int start, out int end, [MarshalAs(UnmanagedType.BStr)] out string text);
        [PreserveSig] int get_textAtOffset(int offset, int boundary, out int start, out int end, [MarshalAs(UnmanagedType.BStr)] out string text);
        [PreserveSig] int removeSelection(int index);
        [PreserveSig] int setCaretOffset(int offset);
        [PreserveSig] int setSelection(int index, int start, int end);
        [PreserveSig] int get_nCharacters(out int count);
    }
}
