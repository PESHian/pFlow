using System.Text;

namespace PFlow.Windows;

/// Whether the person is in the middle of writing something with an input method (Japanese, Chinese, Korean and
/// others): a paste then would mix with their unfinished text. The keyboard language alone says nothing: most
/// people with such a language keep it on all day, and 0.1.27 pasted for them. Typed keys keep their own, stricter
/// rule (LiveKeyField.Composing), since every typed key goes through the input method.
/// Seen three ways, none of which can read the composition text of another app directly (Windows allows that only
/// inside the app):
/// - the input method's own composition window, shown for apps that do not draw the text in place (Notepad++);
/// - UI Automation's TextEdit pattern, for fields that draw it in place and say so (Notepad, browsers, Word);
/// - Windows' candidate or prediction list, or another input panel (emoji, clipboard history) on screen.
/// Not seen: a composition drawn in place by an app without the TextEdit pattern (LibreOffice) while no list is
/// on screen (the input method's predictions turned off, or a Korean syllable).
internal static class InputComposition
{
    /// Why a paste must wait for the person now, or null.
    internal static string? InProgress(IntPtr control)
    {
        if (CompositionWindowShown(control)) return "the input method's composition window is open";
        if (TextEditComposing() == true) return "the field has text the input method is still composing";
        if (PanelOpen()) return "an input method list or input panel is open";
        return null;
    }

    /// The composition window Windows' input method framework shows for the control's thread ("MSCTFIME Composition").
    static bool CompositionWindowShown(IntPtr control)
    {
        if (control == IntPtr.Zero) return false;
        uint thread = Native.GetWindowThreadProcessId(control, out _);
        bool shown = false;
        EnumThreadWindows(thread, (window, _) => {
            if (IsWindowVisible(window) && LiveTextField.ClassName(window) == "MSCTFIME Composition") { shown = true; return false; }
            return true;
        }, IntPtr.Zero);
        return shown;
    }

    /// The focused field's active composition through UI Automation's TextEdit pattern: true when it holds text,
    /// false when the field says there is none, null when the field does not say.
    internal static bool? TextEditComposing()
    {
        object? focused = null, pattern = null, range = null;
        try {
            automation ??= (IAutomation)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("ff48dba4-60ef-4201-aa87-54103eef594e"))!)!;
            if (automation.GetFocusedElement(out var element) != 0 || element == null) return null;
            focused = element;
            if (element.GetCurrentPattern(TextEditPatternId, out pattern) != 0 || pattern is not ITextEditPattern edit) return null;
            if (edit.GetActiveComposition(out var active) != 0) return null;
            if (active == null) return false;
            range = active;
            return active.GetText(-1, out string text) == 0 && !string.IsNullOrEmpty(text);
        } catch (Exception error) when (error is COMException or InvalidCastException or InvalidComObjectException) { return null; }
        finally { foreach (var item in new[] { range, pattern, focused }) if (item != null && Marshal.IsComObject(item)) Marshal.ReleaseComObject(item); }
    }
    const int TextEditPatternId = 10032;
    [ThreadStatic] static IAutomation? automation;

    /// One of Windows' input panels is on screen (one rule: Core InputPanels.Counts): an input method's candidate or
    /// prediction list, the emoji panel, clipboard history. They live in Windows' text input host, alone or inside a
    /// frame window; FindWindowEx is used because EnumWindows does not list these windows.
    internal static bool PanelOpen()
    {
        var hosts = new HashSet<uint>();
        foreach (var p in Process.GetProcessesByName("TextInputHost")) { using (p) hosts.Add((uint)p.Id); }
        if (hosts.Count == 0) return false;
        for (IntPtr window = FindWindowEx(IntPtr.Zero, IntPtr.Zero, null, null); window != IntPtr.Zero; window = FindWindowEx(IntPtr.Zero, window, null, null)) {
            if (!IsWindowVisible(window)) continue;
            Native.GetWindowThreadProcessId(window, out uint process);
            bool host = hosts.Contains(process);
            if (!host) {
                IntPtr inner = FindWindowEx(window, IntPtr.Zero, "Windows.UI.Core.CoreWindow", null);
                if (inner != IntPtr.Zero) { Native.GetWindowThreadProcessId(inner, out uint innerProcess); host = hosts.Contains(innerProcess); }
            }
            if (!host) continue;
            bool cloaked = DwmGetWindowAttribute(window, 14, out int cloak, 4) == 0 && cloak != 0;
            if (!Native.GetWindowRect(window, out var bounds)) continue;
            if (InputPanels.Counts(true, true, cloaked, bounds.Right - bounds.Left, bounds.Bottom - bounds.Top, ScreenWidth(window))) return true;
        }
        return false;
    }

    static int ScreenWidth(IntPtr window)
    {
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        return GetMonitorInfo(MonitorFromWindow(window, 2), ref info) ? info.Monitor.Right - info.Monitor.Left : 0;
    }

    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint thread, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? className, string? title);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int Size; public Native.WindowBounds Monitor, Work; public uint Flags; }

    // UI Automation's COM interfaces, in vtable order up to the methods used (the ones before are never called).
    [ComImport, Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAutomation { void CompareElements(); void CompareRuntimeIds(); void GetRootElement(); void ElementFromHandle(); void ElementFromPoint(); [PreserveSig] int GetFocusedElement(out IElement? element); }
    [ComImport, Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IElement
    {
        void SetFocus(); void GetRuntimeId(); void FindFirst(); void FindAll(); void FindFirstBuildCache(); void FindAllBuildCache(); void BuildUpdatedCache();
        void GetCurrentPropertyValue(); void GetCurrentPropertyValueEx(); void GetCachedPropertyValue(); void GetCachedPropertyValueEx(); void GetCurrentPatternAs(); void GetCachedPatternAs();
        [PreserveSig] int GetCurrentPattern(int pattern, [MarshalAs(UnmanagedType.IUnknown)] out object? value);
    }
    [ComImport, Guid("17e21576-996c-4870-99d9-bff323380c06"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ITextEditPattern
    {
        void RangeFromPoint(); void RangeFromChild(); void GetSelection(); void GetVisibleRanges(); void DocumentRange(); void SupportedTextSelection();
        [PreserveSig] int GetActiveComposition(out ITextRange? range);
    }
    [ComImport, Guid("a543cc6a-f4ae-494b-8239-c814481187a8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ITextRange
    {
        void Clone(); void Compare(); void CompareEndpoints(); void ExpandToEnclosingUnit(); void FindAttribute(); void FindText(); void GetAttributeValue();
        void GetBoundingRectangles(); void GetEnclosingElement();
        [PreserveSig] int GetText(int maxLength, [MarshalAs(UnmanagedType.BStr)] out string text);
    }
}
