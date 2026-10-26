namespace PFlow.Windows;

/// The person's own key presses and mouse button presses (PersonInput) from the moment pFlow selects its live
/// words in a browser field until the first key of the finished text. Chrome's UI Automation can report the old
/// selection for about half a second after a click or Shift+click moved it, so a selection read back in that
/// time proves nothing; this watch does not depend on it. Low-level keyboard and mouse hooks on a thread of their
/// own see the input at once, even while pFlow's UI thread is busy with the checks (GetLastInputInfo cannot be
/// used: it counts the pointer moving and every program's injected keys, pFlow's own among them).
internal sealed class InputWatch
{
    /// Is this key event the activation key (set by Program from the keyboard hook)? Its repeats and its release
    /// never count.
    internal static Func<Native.HookKey, bool>? ActivationKey { get; set; }
    /// Test seam: input a program sends with this extra-info tag counts as the person's (the live checks cannot
    /// make input Windows does not mark as injected). 0, the default, counts no injected input at all.
    internal static nuint CountedTag { get; set; }
    /// The longest a watch lives: by then it has either answered or no longer vouches for anything.
    const int Lifetime = 5000;
    const int WM_QUIT = 0x0012, WM_TIMER = 0x0113, WM_APP_FLUSH = 0x8001;

    readonly Native.HookProc keyboardCallback, mouseCallback;
    readonly ManualResetEventSlim ready = new(), flushed = new();
    IntPtr keyboard, mouse;
    uint threadId;
    int seen;
    volatile bool broken, expired, ended;
    bool asked;

    InputWatch() { keyboardCallback = OnKey; mouseCallback = OnMouse; }

    /// Starts watching now. A watch that could not start answers "acted" (nothing is vouched for).
    internal static InputWatch Start()
    {
        var watch = new InputWatch();
        var thread = new Thread(watch.Run) { IsBackground = true, Name = "pFlow input watch" };
        thread.Start();
        if (!watch.ready.Wait(500)) watch.broken = true;
        return watch;
    }

    void Run()
    {
        threadId = GetCurrentThreadId();
        keyboard = Native.SetWindowsHookEx(13, keyboardCallback, Native.GetModuleHandle(null), 0);
        mouse = Native.SetWindowsHookEx(14, mouseCallback, Native.GetModuleHandle(null), 0);
        if (keyboard == IntPtr.Zero || mouse == IntPtr.Zero) broken = true;
        SetTimer(IntPtr.Zero, IntPtr.Zero, Lifetime, IntPtr.Zero);
        ready.Set();
        try {
            while (!broken && GetMessage(out var message, IntPtr.Zero, 0, 0) > 0) {
                if (message.Id == WM_APP_FLUSH) { flushed.Set(); continue; }
                if (message.Id == WM_TIMER) { expired = true; break; }
                DispatchMessage(ref message);
            }
        } finally {
            if (keyboard != IntPtr.Zero) Native.UnhookWindowsHookEx(keyboard);
            if (mouse != IntPtr.Zero) Native.UnhookWindowsHookEx(mouse);
            keyboard = mouse = IntPtr.Zero; ended = true; flushed.Set();
        }
    }

    IntPtr OnKey(int code, IntPtr wp, IntPtr lp)
    {
        if (code >= 0) {
            var key = Marshal.PtrToStructure<Native.HookKey>(lp);
            bool injected = (key.Flags & 0x10) != 0 && !(CountedTag != 0 && key.Extra == CountedTag);
            bool activation = ActivationKey?.Invoke(key) == true;
            if (PersonInput.Counts((int)wp.ToInt64(), injected, activation)) Interlocked.Increment(ref seen);
        }
        return Native.CallNextHookEx(keyboard, code, wp, lp);
    }

    IntPtr OnMouse(int code, IntPtr wp, IntPtr lp)
    {
        if (code >= 0) {
            var mouse = Marshal.PtrToStructure<HookMouse>(lp);
            bool injected = (mouse.Flags & 0x01) != 0 && !(CountedTag != 0 && mouse.Extra == CountedTag);
            if (PersonInput.Counts((int)wp.ToInt64(), injected, false)) Interlocked.Increment(ref seen);
        }
        return Native.CallNextHookEx(this.mouse, code, wp, lp);
    }

    /// Asked once, right before the first key: true when the person pressed a key or a mouse button since Start,
    /// or when that cannot be known (the watch did not start, outlived its time, or did not answer within 100 ms).
    /// The hooks' calls already on their way are taken in first (a marker posted behind them), then the watch ends.
    internal bool End()
    {
        if (asked || broken || expired || ended || threadId == 0) { asked = true; Stop(); return true; }
        asked = true;
        bool answered = PostThreadMessage(threadId, WM_APP_FLUSH, IntPtr.Zero, IntPtr.Zero) && flushed.Wait(100);
        bool acted = !answered || expired || broken || Volatile.Read(ref seen) > 0;
        Stop();
        return acted;
    }

    /// Ends the watch without asking.
    internal void Stop()
    {
        if (threadId != 0 && !ended) PostThreadMessage(threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
    }

    [StructLayout(LayoutKind.Sequential)] struct HookMouse { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] struct Msg { public IntPtr Window; public int Id; public IntPtr WParam, LParam; public uint Time; public int X, Y; }
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern int GetMessage(out Msg message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Msg message);
    [DllImport("user32.dll", SetLastError = true)] static extern bool PostThreadMessage(uint thread, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetTimer(IntPtr window, IntPtr id, uint milliseconds, IntPtr callback);
}
