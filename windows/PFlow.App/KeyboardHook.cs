namespace PFlow.Windows;

internal sealed class KeyboardHook : IDisposable
{
    readonly Native.HookProc callback;
    readonly Action<TriggerAction> action;
    readonly ActivationRouter router;
    readonly Action<Native.Input[]> replay;
    readonly Func<uint, bool> held;
    IntPtr hook;
    public bool Enabled { get => router.Enabled; set => Post(router.SetEnabled(value)); }
    public string ActivationKey => router.Selected.Id;
    public bool CanRebind => router.CanRebind;
    public void SelectActivationKey(string id) => router.Select(id);
    public event Action<uint, uint>? PhysicalKey;
    public KeyboardHook(Action<TriggerAction> action, string? activationKey = ActivationKeys.DefaultId,
        Action<Native.Input[]>? replay = null, Func<uint, bool>? held = null)
    {
        this.action = action; callback = OnKey; router = new(activationKey);
        this.replay = replay ?? Native.Send; this.held = held ?? (key => Native.GetAsyncKeyState((int)key) < 0);
        hook = Native.SetWindowsHookEx(13, callback, Native.GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) throw new InvalidOperationException("Windows could not start the dictation key listener.");
    }
    void Post(TriggerAction value) { if (value != TriggerAction.None) Application.Current.Dispatcher.BeginInvoke(() => action(value)); }
    IntPtr OnKey(int code, IntPtr wp, IntPtr lp)
    {
        if (code < 0) return Native.CallNextHookEx(hook, code, wp, lp);
        var key = Marshal.PtrToStructure<Native.HookKey>(lp);
        bool down = wp.ToInt64() is 0x100 or 0x104;
        if (ProcessKey(key, down, Environment.TickCount64)) return (IntPtr)1;
        return Native.CallNextHookEx(hook, code, wp, lp);
    }
    internal bool ProcessKey(Native.HookKey key, bool down, long time)
    {
        bool injected = (key.Flags & 0x10) != 0;
        uint code = key.Vk == 0x11 ? ((key.Flags & 1) != 0 ? 0xA3u : 0xA2u) : key.Vk;
        if (!injected && down && (code == 0x5B || ActivationKeys.Choices.Any(choice => choice.VirtualKey == code)))
            Application.Current.Dispatcher.BeginInvoke(() => PhysicalKey?.Invoke(code, key.Scan));
        var route = router.Process(code, down, injected, time, held);
        if (route.Replay is { } selected) {
            // Deliver the suppressed down before Windows sees the real shortcut key.
            try { replay([Native.Key((ushort)selected.VirtualKey, extended: selected.Extended)]); }
            catch (InvalidOperationException) { router.ReplayFailed(); Post(TriggerAction.Cancel); return true; }
        }
        Post(route.Action); return route.Consume;
    }
    public void Reset() => router.Reset();
    public void Dispose() { if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
}
