using PFlow.Core;
using PFlow.Windows;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Interop;

// W028 fix round 1, in the private window station (its clipboard is the test's own): pFlow's clipboard
// writes are private to clipboard history and the cloud clipboard, the person's clipboard comes back
// without that marking, Ctrl+V never waits on a busy clipboard after the last check, a refused end-of-take
// replace ends in Collapse and the Copy card, and Collapse leaves a field that lost the focus alone.
internal static partial class Program
{
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();

    /// The registered privacy formats on the clipboard now, with their data ("" for an empty item); null when absent.
    static string?[] PrivacyFormats(IntPtr owner)
    {
        if (!Native.OpenClipboard(owner)) throw new Exception("Private clipboard was busy.");
        try {
            return ClipboardLease.Private.Select(p => {
                uint format = Native.RegisterClipboardFormat(p.Name);
                if (!IsClipboardFormatAvailable(format)) return null;
                IntPtr data = Native.GetClipboardData(format); long size = data == IntPtr.Zero ? -1 : (long)Native.GlobalSize(data).ToUInt64();
                if (size <= 0) return size == 0 ? "" : "?";
                var bytes = new byte[size]; var pointer = Native.GlobalLock(data); Marshal.Copy(pointer, bytes, 0, bytes.Length); Native.GlobalUnlock(data);
                return Convert.ToHexString(bytes);
            }).ToArray();
        } finally { Native.CloseClipboard(); }
    }

    static void NativeClipboardPrivacy(IntPtr owner)
    {
        Clipboard.SetText("Fictional person's own copy");
        Check("fixture: the person's own copy carries no privacy marking", PrivacyFormats(owner).All(x => x == null));
        using (var lease = new ClipboardLease(owner, true)) {
            lease.Put("Fictional dictated words.");
            var formats = PrivacyFormats(owner);
            Console.WriteLine("privacy formats during the paste: " + string.Join(", ", ClipboardLease.Private.Select((p, i) => p.Name + "=" + (formats[i] ?? "absent"))));
            Check("pFlow's words on the clipboard are kept out of clipboard history and the cloud clipboard (ExcludeClipboardContentFromMonitorProcessing, CanIncludeInClipboardHistory 0, CanUploadToCloudClipboard 0)",
                formats[0] == "00000000" && formats[1] == "00000000" && formats[2] == "00000000" && Clipboard.GetText() == "Fictional dictated words.");
            Check("the person's clipboard comes back exactly, without the marking", lease.Restore() && Clipboard.GetText() == "Fictional person's own copy" && PrivacyFormats(owner).All(x => x == null));
        }
        // The card's Copy and "Copy dictation to clipboard" go through the same write.
        ClipboardLease.KeepCopy(owner, "Fictional copied words.");
        Check("the Copy card's copy is private too", PrivacyFormats(owner) is [ "00000000", "00000000", "00000000" ] && Clipboard.GetText() == "Fictional copied words.");
        // A later take saves and restores that marked copy as it was, the marking included.
        using (var lease = new ClipboardLease(owner, true)) {
            lease.Put("Fictional next take.");
            Check("a later take puts pFlow's own marked copy back exactly", lease.Restore() && Clipboard.GetText() == "Fictional copied words." && PrivacyFormats(owner) is [ "00000000", "00000000", "00000000" ]);
        }

        // Fix round 2: Windows refuses one of the privacy formats. The words never go on the clipboard unmarked
        // (the marking is set first and the text is not set at all), and the person's clipboard comes back.
        {
            Clipboard.SetText("Fictional person's own copy");
            uint refusedFormat = Native.RegisterClipboardFormat(ClipboardLease.Private[1].Name); var set = ClipboardLease.SetData;
            ClipboardLease.SetData = (format, data) => format == refusedFormat ? IntPtr.Zero : set(format, data);
            using var lease = new ClipboardLease(owner, true); string? refused = null;
            try { lease.Put("Fictional words that must stay private."); } catch (InvalidOperationException error) { refused = error.Message; }
            finally { ClipboardLease.SetData = set; }
            bool textOn = Clipboard.ContainsText();
            Console.WriteLine($"privacy format refused: [{refused}] text on the clipboard={textOn}");
            Check("a refused privacy format: no text goes on the clipboard, the take is refused with the Copy card", refused != null && InsertionPrompt.Needed(refused, false) && !textOn);
            Check("a refused privacy format: the person's clipboard comes back", lease.Restore() && Clipboard.GetText() == "Fictional person's own copy");
        }

        // Another program holds the clipboard right after Put (clipboard history does): Ctrl+V goes out at once,
        // never after a wait that follows the last focus check.
        Clipboard.SetText("Fictional person's own copy");
        var sent = new List<Native.Input[]>(); var send = ClipboardLease.SendKeys;
        ClipboardLease.SendKeys = inputs => sent.Add(inputs);
        try {
            using var lease = new ClipboardLease(owner, true);
            lease.Put("Fictional dictated words.");
            using var held = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
            var holder = new Thread(() => { if (OpenClipboard(IntPtr.Zero)) { held.Set(); release.Wait(5000); CloseClipboard(); } else held.Set(); });
            holder.Start(); held.Wait(5000);
            var clock = Stopwatch.StartNew(); string? refused = null;
            try { lease.DispatchPaste(); } catch (InvalidOperationException error) { refused = error.Message; }
            long took = clock.ElapsedMilliseconds;
            Console.WriteLine($"paste with the clipboard held elsewhere: {took} ms, keys sent {sent.Count}, refused [{refused}]");
            Check("a clipboard held by another program does not delay Ctrl+V after the last check (no wait, keys sent once)", took < 20 && refused == null && sent.Count == 1 && sent[0].Length == 4);
            // Still held when pFlow wants to set its words: the paste is refused (Copy card), nothing sent.
            using var second = new ClipboardLease(owner, false); string? busy = null; var wait = Stopwatch.StartNew();
            try { second.Put("Fictional words that must not go."); } catch (InvalidOperationException error) { busy = error.Message; }
            Console.WriteLine($"put with the clipboard held elsewhere: {wait.ElapsedMilliseconds} ms, [{busy}]");
            Check("a clipboard still held after half a second refuses before any check or key (Copy card)", busy != null && busy.StartsWith("The clipboard is busy.", StringComparison.Ordinal)
                && InsertionPrompt.Needed(busy, false) && wait.ElapsedMilliseconds is >= 400 and < 2000 && sent.Count == 1);
            release.Set(); holder.Join(5000);
            Check("the person's clipboard comes back after the held clipboard is free", lease.Restore() && Clipboard.GetText() == "Fictional person's own copy");
        } finally { ClipboardLease.SendKeys = send; }
    }

    /// A key-typed field (Chrome's kind) the test owns: append only, Select and Collapse counted.
    sealed class KeyField(string value) : ILiveTextField
    {
        public string Value = value; public TextSpan Caret = new(value.Length, 0); public int Collapses;
        public string LineBreak => " ";
        public string Method => "keys";
        public bool AppendOnly => true;
        public LiveFieldState State() => new(7, LiveFieldState.Target, false, true, Value, Caret);
        public bool CanWriteRanges() => true;
        public bool Replace(TextSpan range, string text) { Value = Value[..range.Start] + text + Value[range.End..]; Caret = new(range.Start + text.Length, 0); return true; }
        public bool Select(TextSpan range) { Caret = range; return true; }
        public bool Collapse() { Collapses++; Caret = new(Caret.End, 0); return true; }
    }

    sealed class ReplaceTarget : IInsertionTarget
    {
        public string? Outcome; public OwnedWords? Own; public int Calls;
        public bool CanInsert => true;
        public string ApplicationName => "FictionalBrowser";
        public string ApplicationId => "FictionalBrowser";
        public Task<string> Insert(string text, IntPtr owner, bool keepClipboard, CancellationToken cancel, string? rtf = null) => Task.FromResult("Inserted");
        public Task<string> InsertOverSelection(string text, OwnedWords own, IntPtr owner, bool keepClipboard, CancellationToken cancel, string? rtf = null)
        { Calls++; Own = own; return Outcome == null ? Task.FromException<string>(new InvalidOperationException("The field changed. Your text is in History.")) : Task.FromResult(Outcome); }
    }

    static void NativeReplaceEnd()
    {
        string root = Path.Combine(Path.GetTempPath(), "pflow-replace-fictional-" + Guid.NewGuid().ToString("N"));
        try {
            var store = new StateStore(root); store.Preferences.UseLocalAI = false;
            var pipeline = new DictationPipeline(store, new Whisper(root), new LocalTextModel(root));
            T Wait<T>(Task<T> task) { while (!task.IsCompleted) { Drain(); Thread.Sleep(1); } return task.GetAwaiter().GetResult(); }
            var prepared = new DictationPipeline.Prepared("Harbor lights glow tonight.", null, 4, false);
            (KeyField Field, LiveInlineSlot Slot) Typed(string take)
            {
                var field = new KeyField("Note: "); var slot = new LiveInlineSlot(); slot.Begin(take, field);
                slot.Reconcile(take, "harbor lights"); slot.Reconcile(take, "harbor lights glow");
                return (field, slot);
            }
            {
                // The selection check refuses (the selection moved): Collapse, the live words stay, the Copy card.
                var (field, slot) = Typed("r1"); var target = new ReplaceTarget();
                var result = Wait(pipeline.Deliver(prepared, 3, target, IntPtr.Zero, (_, _) => { }, CancellationToken.None,
                    new LiveTyping(t => slot.Finalize("r1", t), () => slot.Typed("r1"), () => slot.Cancel("r1"), () => slot.Collapse("r1"), () => slot.Selection("r1"))));
                Check("a refused replace ends the selection (Collapse), leaves the live words and offers the finished text in the Copy card",
                    target.Calls == 1 && target.Own is { Start: 6, Text: "harbor lights" } && field.Collapses == 1 && field.Caret.Length == 0 && field.Value == "Note: harbor lights"
                    && result.Status == LiveInlineText.LiveLeft && result.Prompt is { Text: "Harbor lights glow tonight." } && store.History[0].InsertionStatus == LiveInlineText.LiveLeft);
            }
            {
                // Without pFlow's own words to check the selection against, nothing goes over it.
                var (field, slot) = Typed("r2"); var target = new ReplaceTarget { Outcome = "Inserted" };
                var result = Wait(pipeline.Deliver(prepared, 3, target, IntPtr.Zero, (_, _) => { }, CancellationToken.None,
                    new LiveTyping(t => slot.Finalize("r2", t), () => slot.Typed("r2"), () => slot.Cancel("r2"), () => slot.Collapse("r2"))));
                Check("a replace with no owned words to check is refused: no write, Collapse, Copy card", target.Calls == 0 && field.Collapses == 1 && result.Status == LiveInlineText.LiveLeft && result.Prompt != null);
            }
            {
                var (field, slot) = Typed("r3"); var target = new ReplaceTarget { Outcome = "Inserted" };
                var result = Wait(pipeline.Deliver(prepared, 3, target, IntPtr.Zero, (_, _) => { }, CancellationToken.None,
                    new LiveTyping(t => slot.Finalize("r3", t), () => slot.Typed("r3"), () => slot.Cancel("r3"), () => slot.Collapse("r3"), () => slot.Selection("r3"))));
                Check("a replace that went in: no Collapse, no card", target.Calls == 1 && field.Collapses == 0 && result.Status == "Inserted" && result.Prompt == null);
            }
        } finally { if (Directory.Exists(root)) Directory.Delete(root, true); }

        // LiveKeyField.Collapse on a real UI Automation text field: never in a field that is not the focus in the window in front.
        _ = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var editor = new TextBox { Text = "Fictional prefix. harbor lights" };
        AutomationProperties.SetAutomationId(editor, "FictionalCollapseField");
        var window = new Window { Title = "pFlow fictional collapse fixture", Width = 480, Height = 160, Content = editor };
        try {
            window.Show(); window.Activate(); editor.Focus(); window.UpdateLayout(); Drain();
            _ = UIElementAutomationPeer.CreatePeerForElement(editor);
            var handle = new WindowInteropHelper(window).Handle;
            editor.Select(18, 13); Drain();
            T OffThread<T>(Func<T> work) { var task = Task.Run(work); var clock = Stopwatch.StartNew(); while (!task.IsCompleted && clock.Elapsed < TimeSpan.FromSeconds(10)) { Drain(); Thread.Sleep(1); } return task.GetAwaiter().GetResult(); }
            var element = OffThread(() => AutomationElement.FromHandle(handle).FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, "FictionalCollapseField")))
                ?? throw new Exception("Native collapse field automation unavailable.");
            bool away = OffThread(() => new LiveKeyField(element, new IntPtr(0x7FFF0010), IntPtr.Zero, false).Collapse()); Drain();
            Check("Collapse leaves the selection alone in a field whose window is not in front", !away && editor.SelectionStart == 18 && editor.SelectionLength == 13);
            bool front = Native.GetForegroundWindow() == handle;
            bool here = OffThread(() => new LiveKeyField(element, front ? handle : new IntPtr(0x7FFF0010), IntPtr.Zero, false).Collapse()); Drain();
            if (front) Check("positive control: Collapse ends the selection in the focused field in front", here && editor.SelectionLength == 0);
            else Console.WriteLine("Collapse positive control NOT RUN: the private desktop has no foreground window (the live guard set checks it in Edge)");
        } finally { window.Close(); }
    }

    /// Fix round 2: a window message into an app pFlow cannot read waits only for what is left of the 300 ms limit
    /// (Scintilla's WM_GETTEXT used to wait 2 s); and the person-input watch answers.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr window, int message, IntPtr wParam, System.Text.StringBuilder lParam, uint flags, uint timeout, out IntPtr result);
    static bool SlowText(IntPtr window, uint timeout) { var buffer = new System.Text.StringBuilder(22); return SendMessageTimeout(window, 0x000D, (IntPtr)22, buffer, 0x3, timeout, out _) != IntPtr.Zero; }
    static void NativeRoundTwo()
    {
        using var made = new ManualResetEventSlim(); IntPtr slow = IntPtr.Zero; System.Windows.Threading.Dispatcher? owner = null;
        var thread = new Thread(() => {
            var source = new HwndSource(new HwndSourceParameters("pFlow fictional slow editor") { Width = 40, Height = 20, WindowStyle = 0 });
            source.AddHook((IntPtr hwnd, int message, IntPtr wp, IntPtr lp, ref bool handled) => {
                // The length comes back at once (20); a request for the text in a buffer of that length + 2 (pFlow's) and the
                // Scintilla message take 2 s. Windows' own requests for the window's text (other buffer sizes) are answered at once.
                if (message == 0x000E) { handled = true; return (IntPtr)20; }
                if (message == 0x000D && wp == 22 || message == 2143) { Thread.Sleep(2000); handled = true; return IntPtr.Zero; }
                return IntPtr.Zero;
            });
            slow = source.Handle; owner = System.Windows.Threading.Dispatcher.CurrentDispatcher; made.Set();
            System.Windows.Threading.Dispatcher.Run();
        });
        thread.SetApartmentState(ApartmentState.STA); thread.IsBackground = true; thread.Start(); made.Wait(5000);
        try {
            // Windows itself may ask a new window for its text: wait until the fixture answers its length at once.
            bool idle = false;
            for (int i = 0; i < 40 && !idle; i++) { idle = WeakField.Message(slow, 0x000E, new CallDeadline(100).Start()) == 20; if (!idle) Thread.Sleep(250); }
            Check("fixture: the slow editor answers its text length at once", idle);
            // Positive control: asked without pFlow's limit, the fixture really keeps the caller waiting 2 s.
            var control = Stopwatch.StartNew();
            bool answered = SlowText(slow, 2500);
            long controlMs = control.ElapsedMilliseconds;
            Console.WriteLine($"slow editor positive control: WM_GETTEXT with a 2.5 s timeout answered={answered} after {controlMs} ms");
            Check("positive control: the slow editor keeps an unbounded WM_GETTEXT waiting about 2 s", controlMs >= 1800);
            for (int i = 0; i < 40 && WeakField.Message(slow, 0x000E, new CallDeadline(100).Start()) != 20; i++) Thread.Sleep(100);
            var clock = Stopwatch.StartNew();
            string? text = WeakField.WindowText(slow, new CallDeadline(CallDeadline.Default).Start());
            long textMs = clock.ElapsedMilliseconds; clock.Restart();
            int? selection = WeakField.Message(slow, 2143, new CallDeadline(CallDeadline.Default).Start());
            long messageMs = clock.ElapsedMilliseconds;
            Console.WriteLine($"slow editor: WM_GETTEXT gave up after {textMs} ms, SCI_GETSELECTIONSTART after {messageMs} ms");
            Check("an editor that takes 2 s to answer WM_GETTEXT or a Scintilla message: pFlow stops waiting at the 300 ms limit and claims nothing",
                text == null && selection == null && textMs is >= 250 and < 400 && messageMs is >= 250 and < 400);
        } finally { owner?.InvokeShutdown(); }

        var watch = InputWatch.Start(); Thread.Sleep(50);
        bool quiet = watch.End();
        Check("the person-input watch with nothing pressed answers 'did not act'", !quiet);
        Check("asked again after it ended, the watch no longer vouches ('acted')", watch.End());
    }
}
