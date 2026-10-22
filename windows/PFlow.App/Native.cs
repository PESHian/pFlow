namespace PFlow.Windows;

internal static class Native
{
    internal const uint KEYEVENTF_EXTENDEDKEY = 1, KEYEVENTF_KEYUP = 2, KEYEVENTF_UNICODE = 4;
    [StructLayout(LayoutKind.Sequential)] internal struct Input { public uint Type; public InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)] internal struct InputUnion {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardInput { public ushort Vk, Scan; public uint Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] internal struct MouseInput { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] internal struct HookKey { public uint Vk, Scan, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] internal struct PointerPoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] internal struct WindowBounds { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] internal static extern bool GetPhysicalCursorPos(out PointerPoint point);
    /// The x64 AVX2 worker needs AVX2, FMA, BMI2 and F16C, with Windows saving their registers (.NET checks the OS for the first three).
    internal static bool Avx2Ready => System.Runtime.Intrinsics.X86.Avx2.IsSupported && System.Runtime.Intrinsics.X86.Fma.IsSupported
        && System.Runtime.Intrinsics.X86.Bmi2.IsSupported && F16C;
    static bool F16C { get { if (!System.Runtime.Intrinsics.X86.X86Base.IsSupported) return false; var (_, _, ecx, _) = System.Runtime.Intrinsics.X86.X86Base.CpuId(1, 0); return (ecx & (1 << 29)) != 0; } }
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr window, out WindowBounds bounds);
    [DllImport("user32.dll")] internal static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    internal delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] internal static extern IntPtr SetWindowsHookEx(int id, HookProc callback, IntPtr module, uint thread);
    [DllImport("user32.dll")] internal static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] internal static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wp, IntPtr lp);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError = true)] internal static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] internal static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] internal static extern bool CloseClipboard();
    [DllImport("user32.dll")] internal static extern bool EmptyClipboard();
    [DllImport("user32.dll")] internal static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll", SetLastError = true)] internal static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetClipboardFormatName(uint format, System.Text.StringBuilder name, int length);
    [DllImport("user32.dll")] internal static extern IntPtr SetClipboardData(uint format, IntPtr data);
    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] internal static extern UIntPtr GlobalSize(IntPtr data);
    [DllImport("kernel32.dll")] internal static extern IntPtr GlobalAlloc(uint flags, UIntPtr size);
    [DllImport("kernel32.dll")] internal static extern IntPtr GlobalLock(IntPtr data);
    [DllImport("kernel32.dll")] internal static extern bool GlobalUnlock(IntPtr data);
    [DllImport("kernel32.dll")] internal static extern IntPtr GlobalFree(IntPtr data);
    [DllImport("kernel32.dll")] internal static extern uint GetSystemDefaultLCID();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern int WideCharToMultiByte(uint codePage, uint flags, string text, int characters, byte[]? bytes, int count, IntPtr defaultCharacter, IntPtr usedDefault);
    [DllImport("user32.dll")] internal static extern IntPtr CopyImage(IntPtr image, uint type, int x, int y, uint flags);
    [DllImport("gdi32.dll")] internal static extern bool DeleteObject(IntPtr data);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr CopyEnhMetaFile(IntPtr data, string? path);
    [DllImport("gdi32.dll")] internal static extern bool DeleteEnhMetaFile(IntPtr data);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLong64(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLong64(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong32(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] static extern int SetWindowLong32(IntPtr hwnd, int index, int value);
    internal static IntPtr GetWindowLongPtr(IntPtr hwnd, int index) => IntPtr.Size == 8 ? GetWindowLong64(hwnd, index) : new IntPtr(GetWindowLong32(hwnd, index));
    internal static IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value) => IntPtr.Size == 8 ? SetWindowLong64(hwnd, index, value) : new IntPtr(SetWindowLong32(hwnd, index, value.ToInt32()));
    internal static Input ScanKey(ushort scan, bool extended) => new() { Type = 1, Data = new() { Keyboard = new() { Scan = scan, Flags = 8u | (extended ? KEYEVENTF_EXTENDEDKEY : 0) } } };
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetKeyNameText(int lParam, System.Text.StringBuilder text, int size);
    [DllImport("user32.dll")] internal static extern uint MapVirtualKey(uint code, uint mode);
    internal static Input Key(ushort vk, bool up = false, bool extended = false) => new() { Type = 1, Data = new() { Keyboard = new() { Vk = vk, Flags = (up ? KEYEVENTF_KEYUP : 0) | (extended ? KEYEVENTF_EXTENDEDKEY : 0) } } };
    /// Keystrokes for `text` where every line break is Shift+Enter: a new line
    /// in a box, never the Enter that sends a chat message.
    internal static Input[] TypedText(string text)
    {
        var inputs = new List<Input>();
        string[] lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (int i = 0; i < lines.Length; i++) {
            if (lines[i].Length > 0) inputs.AddRange(UnicodeText(lines[i]));
            if (i < lines.Length - 1) inputs.AddRange([Key(0x10), Key(0x0D), Key(0x0D, true), Key(0x10, true)]);
        }
        return inputs.ToArray();
    }
    internal static Input[] UnicodeText(string text)
    {
        // VK_PACKET produces WM_CHAR: Windows multiline controls expect CR for a line break.
        string keys = text.Replace("\r\n", "\n").Replace('\r', '\n').Replace('\n', '\r');
        var inputs = new Input[checked(keys.Length * 2)];
        for (int i = 0; i < keys.Length; i++) {
            inputs[i * 2] = new Input { Type = 1, Data = new() { Keyboard = new() { Scan = keys[i], Flags = KEYEVENTF_UNICODE } } };
            inputs[i * 2 + 1] = new Input { Type = 1, Data = new() { Keyboard = new() { Scan = keys[i], Flags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP } } };
        }
        return inputs;
    }
    internal static void Send(params Input[] inputs)
    {
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) != inputs.Length)
            throw new InvalidOperationException("Windows blocked keyboard input. Your text is in History.");
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetClassName(IntPtr window, System.Text.StringBuilder name, int size);
}
