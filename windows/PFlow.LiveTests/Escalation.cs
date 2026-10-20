using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using PFlow.Core;
using PFlow.Windows;

// Owner live test follow-ups (2026-10-20): the finished text must go in once
// even when live windows are slower than the computer can manage or the
// worker goes quiet, and the Settings/History pages must scroll by touch.
internal static partial class Program
{
    /// Records what the pipeline asked it to insert; never touches another app.
    sealed class FakeTarget : IInsertionTarget
    {
        public List<string> Inserted = [];
        public bool CanInsert => true;
        public string ApplicationName => "Fictional target";
        public string ApplicationId => "fictional-target";
        public Task<string> Insert(string text, IntPtr clipboardOwner, bool keepClipboard, CancellationToken cancel, string? rtf = null) { Inserted.Add(text); return Task.FromResult("Inserted"); }
    }

    /// --final-priority: live windows that outlive their limit are canceled and
    /// live words stop, the warm worker survives, and the finished text is
    /// inserted exactly once with no "took too long" toast. A worker that goes
    /// quiet is reported plainly and the live words are kept in History.
    static async Task FinalPriority()
    {
        string directory = Path.Combine(root, "final-priority-fictional-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        var store = new StateStore(directory); store.Preferences.Language = "en"; store.Preferences.CopyDictationToClipboard = false;
        await using var whisper = new Whisper(directory, PackageAssets);
        var capsule = new Capsule(store); var preview = new LivePreview(store);
        try {
            await whisper.Prewarm(); int? worker = whisper.WorkerId;
            Check("the worker is warm before the take", worker != null);
            const string audio = "medium-1.wav";
            var pipeline = new DictationPipeline(store, whisper, new LocalTextModel(directory, PackageAssets));
            // 1. Every live window outlives a 1 ms limit: canceled, counted as slow, live words end with the plain note.
            var report = await FeedTake("final-priority", audio, LiveTextModes.Preview, false, whisper, store, preview, capsule, windowLimit: TimeSpan.FromMilliseconds(1));
            Check("two live windows slower than the limit end live words with the plain note", report.TooSlowAtMs > 0 && report.Windows == LiveSession.SlowWindowsBeforeStop && preview.Note == LiveTake.TooSlowNote);
            Check("canceled live windows leave the warm worker running", whisper.WorkerId == worker);
            Check("live stop returned at once after the slow windows", report.StopMs < 3000);
            var target = new FakeTarget();
            var result = await pipeline.Run(Path.Combine(root, audio), report.AudioMs / 1000, target, directory, capsule.Handle, (_, _) => { }, CancellationToken.None, report.LiveWords);
            Check("the finished text is inserted exactly once", result.Status == "Inserted" && target.Inserted.Count == 1 && target.Inserted[0].Split(' ').Length > 20);
            Check("no toast after a normal finished pass", result.Notice == null);
            Check("History holds the finished text once, marked inserted", store.History.Count == 1 && store.History[0].Text == target.Inserted[0] && store.History[0].InsertionStatus == "Inserted");
            Check("the final pass reported progress while it worked", whisper.WorkerHeartbeats >= 1);
            Check("the same warm worker made the finished text", whisper.WorkerId == worker);

            // 2. The worker goes quiet during the finished pass (stall limit 1 ms): plain message, no "took too long",
            //    nothing inserted, the live words kept once in History.
            var kept = new FakeTarget(); SpeechWorker.StallLimit = TimeSpan.FromMilliseconds(1);
            try {
                var stalled = await pipeline.Run(Path.Combine(root, audio), report.AudioMs / 1000, kept, directory, capsule.Handle, (_, _) => { }, CancellationToken.None, "Fictional live words so far");
                Check("a quiet worker is reported plainly and the live words are kept", stalled.Status == LiveTake.KeptStatus && stalled.Notice != null
                    && stalled.Notice.Contains(SpeechWorker.Stalled) && !stalled.Notice.Contains("took too long") && kept.Inserted.Count == 0);
                Check("History keeps the live words once with the kept status", store.History.Count == 2 && store.History[0].Text == "Fictional live words so far" && store.History[0].InsertionStatus == LiveTake.KeptStatus);
            } finally { SpeechWorker.StallLimit = TimeSpan.FromSeconds(60); }
            // 3. A fresh worker after that; the next take works again with the default limit.
            var again = new FakeTarget();
            var recovered = await pipeline.Run(Path.Combine(root, "short-1.wav"), 5, again, directory, capsule.Handle, (_, _) => { }, CancellationToken.None);
            Check("the next take starts a new worker and inserts normally", recovered.Status == "Inserted" && again.Inserted.Count == 1 && whisper.WorkerId != worker);

            // 4. A slow start (slow disk, virus scanner reading the model): hashing and loading report progress, so a
            //    stall limit far below the whole start time still lets the take finish. No retry is needed for that.
            int retries = whisper.Retries;
            SpeechWorker.StartThrottle = () => Task.Delay(8); SpeechWorker.StallLimit = TimeSpan.FromMilliseconds(1500);
            try {
                whisper.EndWorker(); var slow = new FakeTarget(); var watch = Stopwatch.StartNew();
                var slowStart = await pipeline.Run(Path.Combine(root, "short-1.wav"), 5, slow, directory, capsule.Handle, (_, _) => { }, CancellationToken.None, "Fictional live words so far");
                Console.WriteLine($"START slow start took {watch.Elapsed.TotalMilliseconds:F0} ms with a 1500 ms stall limit; model load {whisper.WorkerLoadMs:F0} ms, load frames {whisper.WorkerStartHeartbeats}");
                Check("a start several times longer than the stall limit still finishes because it keeps reporting progress", slowStart.Status == "Inserted" && slow.Inserted.Count == 1 && watch.Elapsed > TimeSpan.FromMilliseconds(3000) && whisper.Retries == retries);
                // The worker sends a frame as it starts reading the model and then every 250 ms of loading.
                Check("the worker reported progress while loading the model", whisper.WorkerStartHeartbeats >= 1);
            } finally { SpeechWorker.StartThrottle = null; SpeechWorker.StallLimit = TimeSpan.FromSeconds(60); }
            // 5. The worker fails to start once: one fresh try, the finished text goes in. Twice: an honest message that
            //    does not blame the recording's length, nothing inserted, the live words kept once.
            try {
                whisper.EndWorker(); SpeechWorker.FailNextStarts = 1; var once = new FakeTarget();
                var retried = await pipeline.Run(Path.Combine(root, "short-1.wav"), 5, once, directory, capsule.Handle, (_, _) => { }, CancellationToken.None, "Fictional live words so far");
                Check("a worker that fails to start is replaced once and the finished text is inserted", retried.Status == "Inserted" && once.Inserted.Count == 1 && retried.Notice == null && whisper.Retries == retries + 1);
                whisper.EndWorker(); SpeechWorker.FailNextStarts = 2; var twice = new FakeTarget(); int entries = store.History.Count;
                var gaveUp = await pipeline.Run(Path.Combine(root, "short-1.wav"), 5, twice, directory, capsule.Handle, (_, _) => { }, CancellationToken.None, "Fictional live words so far");
                Check("after the retry also fails the live words are kept with a message that does not say 'shorter recording'", gaveUp.Status == LiveTake.KeptStatus && gaveUp.Notice != null
                    && gaveUp.Notice.Contains("stopped answering") && !gaveUp.Notice.Contains("shorter recording") && twice.Inserted.Count == 0 && store.History.Count == entries + 1 && store.History[0].Text == "Fictional live words so far");
                Check("no third start was attempted", SpeechWorker.FailNextStarts == 0);
            } finally { SpeechWorker.FailNextStarts = 0; }
            Console.WriteLine($"{passed} final-priority checks passed.");
        } finally { preview.Close(); capsule.Close(); Directory.Delete(directory, true); }
    }

    [StructLayout(LayoutKind.Sequential)] struct PointerInfo
    {
        public uint PointerType, PointerId, FrameId, PointerFlags; public IntPtr SourceDevice, Target;
        public ScreenPoint PixelLocation, HimetricLocation, PixelLocationRaw, HimetricLocationRaw;
        public uint Time, HistoryCount; public int InputData; public uint KeyStates; public ulong PerformanceCount; public int ButtonChangeType;
    }
    [StructLayout(LayoutKind.Sequential)] struct ContactRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct PointerTouchInfo { public PointerInfo Pointer; public uint TouchFlags, TouchMask; public ContactRect Contact, ContactRaw; public uint Orientation, Pressure; }
    [DllImport("user32.dll", SetLastError = true)] static extern bool InitializeTouchInjection(uint maxCount, uint mode);
    [DllImport("user32.dll", SetLastError = true)] static extern bool InjectTouchInput(uint count, PointerTouchInfo[] contacts);
    // Windows 10 1809+: a synthetic touch device, the newer way to inject touch.
    [StructLayout(LayoutKind.Sequential)] struct PointerTypeInfo { public uint Type; uint pad; public PointerTouchInfo Touch; }
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr CreateSyntheticPointerDevice(uint pointerType, uint maxCount, uint mode);
    [DllImport("user32.dll", SetLastError = true)] static extern bool InjectSyntheticPointerInput(IntPtr device, PointerTypeInfo[] pointers, uint count);
    [DllImport("user32.dll")] static extern void DestroySyntheticPointerDevice(IntPtr device);
    static IntPtr syntheticTouch;
    const uint PT_TOUCH = 2, POINTER_FLAG_INRANGE = 0x2, POINTER_FLAG_INCONTACT = 0x4, POINTER_FLAG_DOWN = 0x10000, POINTER_FLAG_UPDATE = 0x20000, POINTER_FLAG_UP = 0x40000;

    static bool Touch(int x, int y, uint flags)
    {
        var contact = new PointerTouchInfo {
            Pointer = new PointerInfo { PointerType = PT_TOUCH, PointerId = 1, PointerFlags = flags, PixelLocation = new ScreenPoint { X = x, Y = y } },
            TouchFlags = 0, TouchMask = 7, Contact = new ContactRect { Left = x - 4, Top = y - 4, Right = x + 4, Bottom = y + 4 }, Orientation = 90, Pressure = 512 };
        if (syntheticTouch != IntPtr.Zero) {
            bool injected = InjectSyntheticPointerInput(syntheticTouch, [new PointerTypeInfo { Type = PT_TOUCH, Touch = contact }], 1);
            if (!injected) Console.WriteLine($"TOUCH InjectSyntheticPointerInput failed: error {Marshal.GetLastWin32Error()} flags 0x{flags:x} at {x},{y}");
            return injected;
        }
        bool sent = InjectTouchInput(1, [contact]);
        if (!sent) Console.WriteLine($"TOUCH InjectTouchInput failed: error {Marshal.GetLastWin32Error()} flags 0x{flags:x} at {x},{y}");
        return sent;
    }

    /// --touch-scroll: a test-owned window with a page made by SettingsWindow.Scroll
    /// (the same factory as every Settings page). A simulated finger drag must move
    /// the page; the mouse wheel must still move it too. Lists and text boxes made
    /// pannable carry the same mode. The test process uses WPF's pointer stack
    /// to see the synthetic finger; the app uses WPF's default touch stack, which
    /// gets real fingers from the digitizer. Real fingers: NOT RUN here.
    static async Task TouchScroll()
    {
        var content = new StackPanel();
        for (int i = 0; i < 80; i++) content.Children.Add(new TextBlock { Text = "Fictional setting line " + i, Height = 24 });
        var scroll = SettingsWindow.Scroll(content);
        var window = new Window { Title = "pFlow fictional touch scroll", Width = 320, Height = 320, Content = scroll, Topmost = true, WindowStartupLocation = WindowStartupLocation.CenterScreen, ShowActivated = true };
        window.Show(); window.Activate(); await Dispatcher.Yield(DispatcherPriority.Background); await Task.Delay(500);
        try {
            Check("Settings pages pan vertically by touch", ScrollViewer.GetPanningMode(scroll) == PanningMode.VerticalOnly);
            Check("lists and text boxes made pannable start with the same mode (then follow whether they can scroll)", ScrollViewer.GetPanningMode(SettingsWindow.Pannable(new ListBox())) == PanningMode.VerticalOnly
                && ScrollViewer.GetPanningMode(SettingsWindow.Pannable(new TextBox())) == PanningMode.VerticalOnly);
            Check("the page starts at the top and has room to scroll", scroll.VerticalOffset == 0 && scroll.ScrollableHeight > 500);
            var handle = new WindowInteropHelper(window).Handle; SetForegroundWindow(handle); await Task.Delay(200);
            var center = scroll.PointToScreen(new Point(scroll.ActualWidth / 2, scroll.ActualHeight * 0.75));
            int x = (int)center.X, y = (int)center.Y;
            Console.WriteLine($"TOUCH window active={window.IsActive} foreground={Native.GetForegroundWindow() == handle} finger at {x},{y} under {WindowFromPoint(new ScreenPoint { X = x, Y = y })} (window {handle})");
            Check("touch structures match the Windows ABI", Marshal.SizeOf<PointerInfo>() == (IntPtr.Size == 8 ? 96 : 80) && Marshal.SizeOf<PointerTouchInfo>() == (IntPtr.Size == 8 ? 144 : 128));
            bool ready = InitializeTouchInjection(1, 1); if (!ready) Console.WriteLine("TOUCH InitializeTouchInjection error " + Marshal.GetLastWin32Error());
            Check("touch injection is available on this desktop", ready);
            // The classic injector first (the touch stack WPF uses by default sees it); if it refuses, a synthetic touch device.
            Console.WriteLine("TOUCH WPF pointer stack: " + (AppContext.TryGetSwitch("Switch.System.Windows.Input.Stylus.EnablePointerSupport", out bool pointer) && pointer ? "on" : "off (WISP)"));
            if (!Touch(x, y, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT)) {
                syntheticTouch = CreateSyntheticPointerDevice(PT_TOUCH, 1, 1);
                Console.WriteLine($"TOUCH synthetic device {syntheticTouch} error {Marshal.GetLastWin32Error()}");
                Check("a synthetic touch device can be made", syntheticTouch != IntPtr.Zero);
                // WPF learns about the new digitizer from a device-change message; give it time, then a tap in place to settle.
                for (int wait = 0; wait < 10; wait++) { await Task.Delay(100); await Dispatcher.Yield(DispatcherPriority.Background); }
                Touch(x, y, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT); await Task.Delay(50); Touch(x, y, POINTER_FLAG_UP);
                for (int wait = 0; wait < 5; wait++) { await Task.Delay(100); await Dispatcher.Yield(DispatcherPriority.Background); }
                Check("finger down on the page", Touch(x, y, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT));
            } else Console.WriteLine("TOUCH classic InjectTouchInput accepted the finger");
            double afterTouch = 0;
            for (int attempt = 1; attempt <= 2; attempt++) {
                if (attempt == 2) { Console.WriteLine("TOUCH first drag did not move the page; one more drag"); Check("finger down again", Touch(x, y, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT)); }
                await Task.Delay(60); await Dispatcher.Yield(DispatcherPriority.Background);
                for (int step = 1; step <= 24; step++) {
                    await Task.Delay(25); Check($"finger moves up ({step})", Touch(x, y - step * 5, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT));
                    await Dispatcher.Yield(DispatcherPriority.Background);
                    if (step % 8 == 0) Console.WriteLine($"TOUCH after {step * 5} px: offset {scroll.VerticalOffset:F1}");
                }
                await Task.Delay(25); Check("finger up", Touch(x, y - 120, POINTER_FLAG_UP));
                await Task.Delay(500); await Dispatcher.Yield(DispatcherPriority.Background);
                afterTouch = scroll.VerticalOffset;
                Console.WriteLine($"TOUCH offset after a 120 px drag (attempt {attempt}): {afterTouch:F1}");
                if (afterTouch >= 60) break;
            }
            Check("a finger drag of 120 px scrolls the page", afterTouch >= 60);
            // Mouse wheel and keyboard scrolling are unchanged.
            scroll.RaiseEvent(new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, -120) { RoutedEvent = UIElement.MouseWheelEvent });
            await Dispatcher.Yield(DispatcherPriority.Background);
            Check("the mouse wheel still scrolls the page", scroll.VerticalOffset > afterTouch);
            double beforeKey = scroll.VerticalOffset; scroll.PageDown(); await Dispatcher.Yield(DispatcherPriority.Background);
            Check("keyboard paging still scrolls the page", scroll.VerticalOffset > beforeKey);
        } finally { window.Close(); }
        try { await NestedTouchScroll(); }
        finally { if (syntheticTouch != IntPtr.Zero) { DestroySyntheticPointerDevice(syntheticTouch); syntheticTouch = IntPtr.Zero; } }
        Console.WriteLine($"{passed} touch scroll checks passed.");
    }

    /// A 120 px finger drag that starts at the center of `element`.
    static async Task Drag(FrameworkElement element)
    {
        var at = element.PointToScreen(new Point(element.ActualWidth / 2, element.ActualHeight / 2)); int x = (int)at.X, y = (int)at.Y;
        Check("finger down on " + element.GetType().Name, Touch(x, y, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT));
        await Task.Delay(60); await Dispatcher.Yield(DispatcherPriority.Background);
        for (int step = 1; step <= 24; step++) { await Task.Delay(25); Touch(x, y - step * 5, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT); await Dispatcher.Yield(DispatcherPriority.Background); }
        await Task.Delay(25); Touch(x, y - 120, POINTER_FLAG_UP);
        await Task.Delay(600); await Dispatcher.Yield(DispatcherPriority.Background);
    }

    /// History-like page: a drag that starts on a list or text box with nothing more to show
    /// moves the page; a list with more to show scrolls itself first.
    static async Task NestedTouchScroll()
    {
        var content = new StackPanel();
        var shortList = SettingsWindow.Pannable(new ListBox { Height = 120, ItemsSource = new[] { "Fictional one", "Fictional two", "Fictional three" } });
        var text = SettingsWindow.Pannable(new TextBox { Height = 100, IsReadOnly = true, Text = "Fictional short note", VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        var longList = SettingsWindow.Pannable(new ListBox { Height = 120, ItemsSource = Enumerable.Range(0, 60).Select(i => "Fictional entry " + i).ToList() });
        content.Children.Add(shortList); content.Children.Add(text); content.Children.Add(longList);
        for (int i = 0; i < 60; i++) content.Children.Add(new TextBlock { Text = "Fictional line " + i, Height = 24 });
        var page = SettingsWindow.Scroll(content);
        var window = new Window { Title = "pFlow fictional nested touch scroll", Width = 320, Height = 420, Content = page, Topmost = true, WindowStartupLocation = WindowStartupLocation.CenterScreen, ShowActivated = true };
        window.Show(); window.Activate(); await Dispatcher.Yield(DispatcherPriority.Background); await Task.Delay(500);
        try {
            SetForegroundWindow(new WindowInteropHelper(window).Handle); await Task.Delay(200);
            Check("the nested page starts at the top", page.VerticalOffset == 0 && page.ScrollableHeight > 500);
            Check("after layout a list with nothing to scroll leaves panning to the page, a long one pans itself",
                ScrollViewer.GetPanningMode(shortList) == PanningMode.None && ScrollViewer.GetPanningMode(text) == PanningMode.None && ScrollViewer.GetPanningMode(longList) == PanningMode.VerticalOnly);
            await Drag(shortList);
            Console.WriteLine($"TOUCH nested: drag on a 3-item list moved the page {page.VerticalOffset:F1}");
            Check("a drag that starts on a list with nothing more to show scrolls the page", page.VerticalOffset >= 60);
            page.ScrollToTop(); await Dispatcher.Yield(DispatcherPriority.Background); await Task.Delay(200);
            await Drag(text);
            Console.WriteLine($"TOUCH nested: drag on a short text box moved the page {page.VerticalOffset:F1}");
            Check("a drag that starts on a short text box scrolls the page", page.VerticalOffset >= 60);
            page.ScrollToTop(); await Dispatcher.Yield(DispatcherPriority.Background); await Task.Delay(200);
            var inner = (ScrollViewer)VisualTreeHelperFind(longList);
            await Drag(longList);
            Console.WriteLine($"TOUCH nested: drag on a 60-item list moved the list {inner.VerticalOffset:F1} and the page {page.VerticalOffset:F1}");
            Check("a drag that starts on a list with more to show scrolls the list, not the page", inner.VerticalOffset > 0 && page.VerticalOffset == 0);
        } finally { window.Close(); }
    }

    static DependencyObject VisualTreeHelperFind(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is ScrollViewer viewer) return viewer;
            if (VisualTreeHelperFind(child) is ScrollViewer found) return found;
        }
        return null!;
    }
}
