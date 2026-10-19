namespace PFlow.Windows;

internal sealed class KeyboardHook : IDisposable
{
    readonly Native.HookProc callback;
    readonly Action<TriggerAction> action;
    readonly Trigger trigger = new();
    IntPtr hook;
    public bool Enabled { get; set; } = true;
    public event Action<uint, uint>? PhysicalKey;
    public KeyboardHook(Action<TriggerAction> action)
    {
        this.action = action; callback = OnKey;
        hook = Native.SetWindowsHookEx(13, callback, Native.GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) throw new InvalidOperationException("Windows could not start the Right Windows key listener.");
    }
    void Post(TriggerAction value) { if (value != TriggerAction.None) Application.Current.Dispatcher.BeginInvoke(() => action(value)); }
    IntPtr OnKey(int code, IntPtr wp, IntPtr lp)
    {
        if (code < 0) return Native.CallNextHookEx(hook, code, wp, lp);
        var key = Marshal.PtrToStructure<Native.HookKey>(lp);
        if ((key.Flags & 0x10) != 0) return Native.CallNextHookEx(hook, code, wp, lp);
        bool down = wp.ToInt64() is 0x100 or 0x104;
        if (down && key.Vk is 0x5B or 0x5C) Application.Current.Dispatcher.BeginInvoke(() => PhysicalKey?.Invoke(key.Vk, key.Scan));
        if (!Enabled) return Native.CallNextHookEx(hook, code, wp, lp);
        if (key.Vk == 0x1B && down) Post(TriggerAction.Cancel);
        if (key.Vk == 0x5C) {
            if (down && !trigger.Down && new[] { 0x10, 0x11, 0x12, 0x5B }.Any(x => Native.GetAsyncKeyState(x) < 0))
                return Native.CallNextHookEx(hook, code, wp, lp);
            if (!down && !trigger.Down) return Native.CallNextHookEx(hook, code, wp, lp);
            bool chord = trigger.Chord;
            Post(down ? trigger.Press(Environment.TickCount64) : trigger.Release(Environment.TickCount64));
            if (chord) return Native.CallNextHookEx(hook, code, wp, lp);
            return (IntPtr)1;
        }
        if (down && trigger.Down && !trigger.Chord) {
            Post(trigger.OtherKey());
            // Replay the suppressed modifier before the real shortcut key reaches Windows.
            try { Native.Send(Native.Key(0x5C)); }
            catch (InvalidOperationException) { Post(TriggerAction.Cancel); }
        }
        return Native.CallNextHookEx(hook, code, wp, lp);
    }
    public void Reset() => trigger.Reset();
    public void Dispose() { if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
}
