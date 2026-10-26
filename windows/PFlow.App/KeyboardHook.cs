namespace PFlow.Windows;

internal sealed class KeyboardHook : IDisposable
{
    readonly Native.HookProc callback;
    readonly Action<TriggerAction> action;
    readonly ActivationRouter router;
    readonly Action<Native.Input[]> replay;
    readonly Func<uint, bool> held;
    IntPtr hook;
    KeyCapture? capture;
    long lastControlTime = long.MinValue;
    uint lastDown;
    public bool Enabled { get => router.Enabled; set { if (value != router.Enabled) CancelKeyCapture(); Post(router.SetEnabled(value)); } }
    public string ActivationKey => router.Selected.Id;
    public bool Capturing => capture != null && !capture.Drained;
    public bool CanRebind => router.CanRebind && (capture == null || capture.Drained);
    public void SelectActivationKey(string id) { if (!CanRebind) throw new InvalidOperationException("Release the keys and finish key selection first."); router.Select(id); }
    public event Action<uint, uint>? PhysicalKey;
    public event Action<KeyCapture, ActivationKey?, string?>? KeyCaptured;
    public KeyboardHook(Action<TriggerAction> action, string? activationKey = ActivationKeys.DefaultId,
        Action<Native.Input[]>? replay = null, Func<uint, bool>? held = null)
    {
        this.action = action; callback = OnKey; router = new(activationKey);
        this.replay = replay ?? Native.Send; this.held = held ?? (key => Native.GetAsyncKeyState((int)key) < 0);
        hook = Native.SetWindowsHookEx(13, callback, Native.GetModuleHandle(null), 0);
        if (hook == IntPtr.Zero) throw new InvalidOperationException("Windows could not start the dictation key listener.");
    }
    public KeyCapture BeginKeyCapture()
    {
        if (!CanRebind) throw new InvalidOperationException("Finish or cancel dictation and release its key first.");
        capture = new KeyCapture(Enumerable.Range(8,248).Select(x => (uint)x).Where(key => ActivationKeys.Usable(key) && held(key)));
        return capture;
    }
    public void CancelKeyCapture()
    {
        if (capture is { } current && current.Cancel()) Report(current,null,"Key selection canceled.");
        if (capture?.Drained == true) capture = null;
    }
    void Report(KeyCapture owner, ActivationKey? key, string? issue) => Application.Current.Dispatcher.BeginInvoke(() => KeyCaptured?.Invoke(owner,key,issue));
    void Post(TriggerAction value) { if (value != TriggerAction.None) Application.Current.Dispatcher.BeginInvoke(() => action(value)); }
    IntPtr OnKey(int code, IntPtr wp, IntPtr lp)
    {
        if (code < 0) return Native.CallNextHookEx(hook, code, wp, lp);
        var key = Marshal.PtrToStructure<Native.HookKey>(lp);
        bool down = wp.ToInt64() is 0x100 or 0x104;
        if (ProcessKey(key, down, Environment.TickCount64)) return (IntPtr)1;
        return Native.CallNextHookEx(hook, code, wp, lp);
    }
    internal static uint Normalize(Native.HookKey key) => key.Vk switch {
        0x11 => (key.Flags & 1) != 0 ? 0xA3u : 0xA2u,
        0x12 => (key.Flags & 1) != 0 ? 0xA5u : 0xA4u,
        0x10 => (key.Scan & 255) == 0x36 ? 0xA1u : 0xA0u,
        _ => key.Vk
    };
    internal bool ProcessKey(Native.HookKey key, bool down, long time)
    {
        bool injected = (key.Flags & 0x10) != 0, extended = (key.Flags & 1) != 0;
        uint code = Normalize(key), scan = key.Scan & 255;
        long stamp = key.Time == 0 ? time : key.Time;
        bool altGr = code == 0xA5 && down && lastDown == 0xA2 && lastControlTime == stamp;
        if (down && (!injected || code == 0xA2 && scan == 0x1D)) { lastDown = code; if (code == 0xA2) lastControlTime = stamp; }
        if (capture is { } learning) {
            var learned = learning.Process(code,scan,extended,down,injected,stamp);
            if (learning.Drained) capture = null;
            if (learned.Key != null || learned.Issue != null) Report(learning,learned.Key,learned.Issue);
            return learned.Consume;
        }
        if (!injected && down && (code == 0x5B || router.Selected.Matches(code,scan,extended) || ActivationKeys.Choices.Any(choice => choice.VirtualKey == code)))
            Application.Current.Dispatcher.BeginInvoke(() => PhysicalKey?.Invoke(code,scan));
        bool Held(uint modifier) => !(altGr && router.Selected.VirtualKey == 0xA5 && modifier == 0xA2) && held(modifier);
        var route = router.Process(code,down,injected,time,Held,scan,extended);
        if (route.Replay is { } selected) {
            // Replay the original physical scan for learned keys, retaining layout/numpad identity.
            try { replay([selected.ScanCode == 0 ? Native.Key((ushort)selected.VirtualKey,extended:selected.Extended) : Native.ScanKey((ushort)selected.ScanCode,selected.Extended)]); }
            catch (InvalidOperationException) { router.ReplayFailed(); Post(TriggerAction.Cancel); return true; }
        }
        Post(route.Action); return route.Consume;
    }
    /// The selected activation key, as a low-level hook sees it (InputWatch, on its own thread: reads the selection only).
    internal bool IsActivationKey(Native.HookKey key) => router.Selected.Matches(Normalize(key), key.Scan & 255, (key.Flags & 1) != 0);
    public void Reset() => router.Reset();
    public void Dispose() { if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook); hook = IntPtr.Zero; capture = null; }
}
