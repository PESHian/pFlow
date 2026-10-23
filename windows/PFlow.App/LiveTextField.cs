using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace PFlow.Windows;

/// The captured field in another app, for live typing. Only Win32 edit and
/// rich edit controls qualify: their text is read through UI Automation and
/// written with EM_SETSEL and EM_REPLACESEL, which are window messages, so they
/// work while the activation key is held and never use keys or the clipboard.
/// Every other field (browsers, Electron, WPF, UWP) has no safe range write,
/// so the take uses the preview instead.
internal sealed class LiveTextField : ILiveTextField
{
    const int WM_GETTEXTLENGTH = 0x000E, EM_GETSEL = 0x00B0, EM_SETSEL = 0x00B1, EM_REPLACESEL = 0x00C2;
    const long ES_PASSWORD = 0x0020, ES_READONLY = 0x0800;
    const uint SMTO_ABORTIFHUNG = 0x2, SMTO_ERRORONEXIT = 0x20, WaitMs = 1000;
    static readonly string[] Plain = ["Edit"], Rich = ["RichEdit20W", "RICHEDIT50W", "RichEditD2DPT"];

    readonly AutomationElement element;
    readonly int[] runtimeId;
    readonly IntPtr window, control;
    readonly bool rich, elevated;
    public string LineBreak => rich ? "\r" : "\r\n";

    LiveTextField(AutomationElement element, IntPtr window, IntPtr control, bool rich, bool elevated)
    {
        this.element = element; runtimeId = element.GetRuntimeId(); this.window = window; this.control = control; this.rich = rich; this.elevated = elevated;
    }

    /// The focused control of `window`, if it is an edit or rich edit control
    /// and the same one UI Automation reports as focused. Otherwise null: Preview.
    internal static LiveTextField? Create(AutomationElement element, IntPtr window, uint process, out string why)
    {
        try {
            IntPtr control = FocusedControl(window);
            why = control == IntPtr.Zero ? "no focused window control" : element.Current.NativeWindowHandle != control.ToInt32() ? "the focused element is not the focused control (" + BaseClass(control) + ")" : "ok";
            if (why != "ok") return null;
            string kind = BaseClass(control);
            bool rich = Rich.Contains(kind, StringComparer.OrdinalIgnoreCase);
            if (!rich && !Plain.Contains(kind, StringComparer.OrdinalIgnoreCase)) { why = "control class " + kind + " is not an edit or rich edit"; return null; }
            return new LiveTextField(element, window, control, rich, TargetAboveUs(process));
        } catch (ElementNotAvailableException) { why = "field went away"; return null; }
        catch (COMException) { why = "field went away"; return null; }
    }

    /// What the live-typing check sees in a field, for the provider matrix in the tests. No text.
    internal static string Describe(AutomationElement element, IntPtr window)
    {
        IntPtr control = FocusedControl(window);
        return $"focus={BaseClass(control)}/{ClassName(control)} element={element.Current.ClassName} sameWindow={element.Current.NativeWindowHandle == control.ToInt32()}";
    }
    internal static string ClassName(IntPtr control)
    {
        var name = new System.Text.StringBuilder(256);
        return GetClassName(control, name, name.Capacity) > 0 ? name.ToString() : "";
    }

    public LiveFieldState State()
    {
        IntPtr front = GetForegroundWindow(); GetWindowThreadProcessId(front, out uint app);
        bool same = front == window && FocusedControl(front) == control && SameElement();
        bool secure = (Style() & ES_PASSWORD) != 0;
        try { secure |= element.Current.IsPassword; } catch (ElementNotAvailableException) { same = false; } catch (COMException) { same = false; }
        string? value = same ? Value() : null;
        return new LiveFieldState(app, same ? LiveFieldState.Target : "other", secure, !elevated && IsWindow(control), value, same && value != null ? Selection() : null);
    }

    public bool CanWriteRanges() => !elevated && IsWindowEnabled(control) && (Style() & ES_READONLY) == 0;

    public bool Replace(TextSpan range, string text)
    {
        // The selection must land exactly on the range, in the control's own
        // units and in UI Automation's, before any text changes.
        if (!Select(range) || Selection() != range || !SameElement()) return false;
        return SendMessageTimeout(control, EM_REPLACESEL, new IntPtr(1), text, SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, WaitMs, out _) != IntPtr.Zero;
    }

    public bool Select(TextSpan range)
    {
        if (SendMessageTimeout(control, EM_SETSEL, new IntPtr(range.Start), new IntPtr(range.End), SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, WaitMs, out _) == IntPtr.Zero) return false;
        return ControlSelection() == range;
    }

    bool SameElement()
    {
        try { return AutomationElement.FocusedElement?.GetRuntimeId().SequenceEqual(runtimeId) == true; }
        catch (ElementNotAvailableException) { return false; }
        catch (COMException) { return false; }
    }

    long Style() => Native.GetWindowLongPtr(control, -16).ToInt64();

    /// The whole text, unless it is too long to read on every update.
    string? Value()
    {
        if (SendMessageTimeout(control, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, WaitMs, out var length) == IntPtr.Zero
            || length.ToInt64() > LiveInlineOwnership.MaxFieldLength) return null;
        try {
            if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)) return null;
            string text = ((TextPattern)pattern).DocumentRange.GetText(-1);
            return text.Length > LiveInlineOwnership.MaxFieldLength ? null : text;
        } catch (ElementNotAvailableException) { return null; }
        catch (COMException) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    /// The one selection in UI Automation's units, only when the control
    /// reports the very same range in its own units. Several selections, or
    /// units that disagree (line breaks counted differently), mean null.
    TextSpan? Selection()
    {
        try {
            if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var raw)) return null;
            var pattern = (TextPattern)raw; var selections = pattern.GetSelection();
            if (selections.Length != 1) return null;
            var prefix = pattern.DocumentRange.Clone();
            prefix.MoveEndpointByRange(TextPatternRangeEndpoint.End, selections[0], TextPatternRangeEndpoint.Start);
            var span = new TextSpan(prefix.GetText(-1).Length, selections[0].GetText(-1).Length);
            return ControlSelection() == span ? span : null;
        } catch (ElementNotAvailableException) { return null; }
        catch (COMException) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    TextSpan? ControlSelection()
    {
        if (SendMessageTimeout(control, EM_GETSEL, out int start, out int end, SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, WaitMs, out _) == IntPtr.Zero) return null;
        return start >= 0 && end >= start ? new TextSpan(start, end - start) : null;
    }

    internal static IntPtr FocusedControl(IntPtr window)
    {
        uint thread = GetWindowThreadProcessId(window, out _);
        var info = new GuiThreadInfo { Size = Marshal.SizeOf<GuiThreadInfo>() };
        return thread != 0 && GetGUIThreadInfo(thread, ref info) ? info.Focus : IntPtr.Zero;
    }

    /// The control's own class even when an app subclasses it. WinForms
    /// registers its own copies, named WindowsForms10.Edit.app.0.… and
    /// WindowsForms10.RichEdit50W.app.0.…, around the system controls.
    internal static string BaseClass(IntPtr control)
    {
        var name = new System.Text.StringBuilder(256);
        string kind = RealGetWindowClass(control, name, (uint)name.Capacity) > 0 ? name.ToString() : "";
        var parts = kind.Split('.');
        return parts.Length > 3 && parts[0].StartsWith("WindowsForms", StringComparison.Ordinal) && parts[2] == "app" ? parts[1] : kind;
    }

    /// An app running as administrator is above pFlow: Windows blocks writes
    /// into it (UIPI), so it is never typed into. Unknown counts as above.
    internal static bool TargetAboveUs(uint process) => Integrity(0) is not int ours || Integrity(process) is not int theirs || theirs > ours;

    /// A process's integrity level (0x2000 medium, 0x3000 high), or null when
    /// it cannot be read. 0 means pFlow itself.
    internal static int? Integrity(uint process)
    {
        IntPtr handle = process == 0 ? GetCurrentProcess() : OpenProcess(0x1000, false, process);
        if (handle == IntPtr.Zero) return null;
        try {
            if (!OpenProcessToken(handle, 0x0008, out var token)) return null;
            try {
                GetTokenInformation(token, 25, IntPtr.Zero, 0, out int size);
                if (size <= 0) return null;
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try {
                    if (!GetTokenInformation(token, 25, buffer, size, out _)) return null;
                    IntPtr sid = Marshal.ReadIntPtr(buffer);
                    int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                    return Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
                } finally { Marshal.FreeHGlobal(buffer); }
            } finally { CloseHandle(token); }
        } finally { if (process != 0) CloseHandle(handle); }
    }

    [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo { public int Size; public uint Flags; public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret; public Native.WindowBounds CaretBounds; }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RealGetWindowClass(IntPtr window, System.Text.StringBuilder name, uint size);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int size);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeout(IntPtr window, int message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeout(IntPtr window, int message, out int wParam, out int lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr window, int message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr buffer, int length, out int needed);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
}
