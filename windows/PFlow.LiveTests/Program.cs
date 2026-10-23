using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using System.Windows.Interop;
using System.Windows.Threading;
using PFlow.Windows;
using Condition = System.Windows.Automation.Condition;

internal static partial class Program
{
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr handle);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(ScreenPoint point);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
    static string root = "";
    static string PackageAssets => Path.Combine(root, "source", "windows", "dist", "win-" + RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant());
    static int passed;
    static bool edgeOnly;
    static bool micOnly;
    static bool secureOnly;
    static bool appearanceOnly;
    static bool appearanceRenderOnly;
    static bool appearanceColorsOnly;
    static bool fallbackOnly;
    static bool notepadOnly;
    static bool processingOnly;
    static bool settingsOnly;
    static bool capsuleOnly;
    static bool compactOnly;
    static bool compactFixOnly;
    static bool waveformsOnly, waveCaptureOnly, payloadOnly, payloadSpacingOnly;
    static bool speechOnly, warmLatencyOnly, extendedLatencyOnly, insertionLatencyOnly, workerSafetyOnly, templateCatalogOnly;
    static bool statisticsOnly, finalPriorityOnly, touchScrollOnly, touchCapsuleOnly, chromiumOnly, chromiumColdOnly;
    static void Check(string name, bool condition) { if (!condition) throw new Exception("FAIL: " + name); Console.WriteLine("PASS: " + name); passed++; }
    static string Normalize(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');
    [STAThread] static int Main(string[] args)
    {
        if (args.Length == 3 && args[1] == "--inline-host") return InlineHost(args[2]);
        // --touch-scroll: the VM has no touch digitizer, so the finger is a synthetic pointer device, which only WPF's
        // WM_POINTER stack receives (set before any WPF type loads). The app itself keeps WPF's default touch stack.
        if (args.Contains("--touch-scroll")) AppContext.SetSwitch("Switch.System.Windows.Input.Stylus.EnablePointerSupport", true);
        root = args[0]; using var report = new StreamWriter(Path.Combine(root, "live-results.log")) { AutoFlush = true }; Console.SetOut(report); Console.SetError(report);
        InsertionLog.Written += line => Console.WriteLine("LOG " + line);
        statisticsOnly = args.Contains("--statistics-only");
        templateCatalogOnly = args.Contains("--template-catalog-only");
        edgeOnly = args.Contains("--edge-only");
        micOnly = args.Contains("--microphone");
        secureOnly = args.Contains("--secure-only");
        appearanceOnly = args.Contains("--appearance-only");
        appearanceRenderOnly = args.Contains("--appearance-render-only");
        appearanceColorsOnly = args.Contains("--appearance-colors-only");
        fallbackOnly = args.Contains("--fallback-only");
        notepadOnly = args.Contains("--notepad-only");
        processingOnly = args.Contains("--processing-only");
        settingsOnly = args.Contains("--settings-only");
        capsuleOnly = args.Contains("--capsule-only");
        compactOnly = args.Contains("--compact-only");
        compactFixOnly = args.Contains("--compact-fix-only");
        waveCaptureOnly = args.Contains("--wave-capture-only"); waveformsOnly = args.Contains("--waveforms-only") || waveCaptureOnly; payloadSpacingOnly = args.Contains("--payload-spacing-only"); payloadOnly = args.Contains("--payload-only") || payloadSpacingOnly;
        finalPriorityOnly = args.Contains("--final-priority"); touchScrollOnly = args.Contains("--touch-scroll"); touchCapsuleOnly = args.Contains("--touch-capsule"); chromiumOnly = args.Contains("--chromium-fields"); chromiumColdOnly = args.Contains("--chromium-cold");
        SpeedArguments(args);
        scrollFramesOnly = args.Contains("--scroll-frames"); ownerStateOnly = args.Contains("--owner-state");
        diagTakesOnly = args.Contains("--diag-takes"); writerOnly = args.Contains("--writer"); chromeReplaceOnly = args.Contains("--chrome-replace"); reportButtonOnly = args.Contains("--report-button"); chromeGuardOnly = args.Contains("--chrome-live-guard"); chromeLiveOnly = args.Contains("--chrome-live"); slowLiveOnly = args.Contains("--slow-live");
        liveTextOnly = args.Contains("--live-text-only"); liveFocusOnly = args.Contains("--live-focus-only"); inlineOnly = args.Contains("--inline-only"); inlineElevatedOnly = args.Contains("--inline-elevated");
        workerSafetyOnly = args.Contains("--worker-safety-only"); extendedLatencyOnly = args.Contains("--extended-latency-only"); insertionLatencyOnly = args.Contains("--insertion-latency-only"); warmLatencyOnly = args.Contains("--warm-latency-only"); speechOnly = args.Contains("--speech-only");
        if (writerOnly || chromeReplaceOnly || chromeGuardOnly || reportButtonOnly || diagTakesOnly || chromeLiveOnly || slowLiveOnly || scrollFramesOnly || ownerStateOnly || statisticsOnly || templateCatalogOnly || appearanceOnly || appearanceRenderOnly || appearanceColorsOnly || fallbackOnly || settingsOnly || capsuleOnly || compactOnly || compactFixOnly || waveformsOnly || payloadOnly || liveTextOnly || liveFocusOnly || inlineOnly || inlineElevatedOnly || speedOnly || speedInsertOnly || werOnly || finalPriorityOnly || touchScrollOnly || touchCapsuleOnly || chromiumOnly || chromiumColdOnly) _ = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        if (waveformsOnly) {
            var application = Application.Current;
            application.Startup += async (_, _) => {
                try { await Run(); Console.WriteLine($"{passed} live target checks passed."); application.Shutdown(0); }
                catch (Exception error) { Console.Error.WriteLine(error); application.Shutdown(1); }
            };
            return application.Run();
        }
        var frame = new DispatcherFrame(); var task = Run();
        var timer = new DispatcherTimer(TimeSpan.FromMilliseconds(50), DispatcherPriority.Background, (_, _) => { if (task.IsCompleted) frame.Continue = false; }, Dispatcher.CurrentDispatcher);
        Dispatcher.PushFrame(frame); timer.Stop();
        try { task.GetAwaiter().GetResult(); Console.WriteLine($"{passed} live target checks passed."); return 0; }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
    static async Task<AutomationElement> WindowWith(string name)
    {
        for (int i = 0; i < 100; i++) {
            var windows = AutomationElement.RootElement.FindAll(TreeScope.Children, Condition.TrueCondition);
            foreach (AutomationElement window in windows) if (window.Current.Name.Contains(name, StringComparison.OrdinalIgnoreCase)) return window;
            await Task.Delay(100);
        }
        throw new Exception("Fixture window did not open: " + name);
    }
    static async Task<AutomationElement> Editor(AutomationElement window)
    {
        await Activate(window);
        window = AutomationElement.FromHandle((IntPtr)window.Current.NativeWindowHandle);
        for (int i = 0; i < 50; i++) {
            var controls = window.FindAll(TreeScope.Descendants, new OrCondition(new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit), new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document)));
            foreach (AutomationElement control in controls) if (control.Current.Name == "Fictional dictation" && !control.Current.IsPassword && control.TryGetCurrentPattern(TextPattern.Pattern, out _)) return control;
            if (!edgeOnly) foreach (AutomationElement control in controls) if (!control.Current.IsPassword && control.Current.IsEnabled && !control.Current.IsOffscreen && control.Current.IsKeyboardFocusable && control.TryGetCurrentPattern(TextPattern.Pattern, out _)) return control;
            await Task.Delay(100);
        }
        var diagnostic = window.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        foreach (AutomationElement c in diagnostic) if (c.Current.ControlType is var type && (type == ControlType.Edit || type == ControlType.Document))
            Console.WriteLine($"Fixture editor: {c.Current.Name}; type={type.ProgrammaticName}; focusable={c.Current.IsKeyboardFocusable}; offscreen={c.Current.IsOffscreen}; text={c.TryGetCurrentPattern(TextPattern.Pattern, out _)}; value={c.TryGetCurrentPattern(ValuePattern.Pattern, out _)}");
        throw new Exception("Fixture editor does not expose TextPattern.");
    }
    static async Task Activate(AutomationElement window, AutomationElement? clickTarget = null)
    {
        IntPtr handle = (IntPtr)window.Current.NativeWindowHandle;
        uint foreground = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out _), current = GetCurrentThreadId();
        bool attached = foreground != current && AttachThreadInput(current, foreground, true);
        try { SetForegroundWindow(handle); }
        finally { if (attached) AttachThreadInput(current, foreground, false); }
        await Task.Delay(200);
        if (Native.GetForegroundWindow() != handle) {
            string title = window.Current.Name;
            Check("physical activation is limited to our fixture", window.Current.ProcessId == Environment.ProcessId || title.Contains("pflow-processing-") || title.Contains("pflow-fictional-"));
            var rectangle = clickTarget?.Current.BoundingRectangle ?? window.Current.BoundingRectangle;
            double scale = GetDpiForWindow(handle) / 96.0;
            var point = clickTarget != null ? new ScreenPoint { X = (int)(rectangle.X + rectangle.Width / 2), Y = (int)(rectangle.Y + rectangle.Height / 2) }
                : new ScreenPoint { X = (int)(rectangle.X + 12 * scale), Y = (int)(rectangle.Y + rectangle.Height / 2) };
            ScreenPoint previous; bool cursor = GetPhysicalCursorPos(out previous);
            bool wasTopmost = (Native.GetWindowLongPtr(handle, -20).ToInt64() & 8) != 0;
            Native.SetWindowPos(handle, new IntPtr(-1), 0, 0, 0, 0, 0x13);
            try {
                Check("physical activation point belongs to fixture", GetAncestor(WindowFromPoint(point), 2) == handle);
                Check("position fixture activation cursor", SetPhysicalCursorPos(point.X, point.Y));
                Native.Send(new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 2 } } }, new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 4 } } });
                await Task.Delay(200);
            } finally {
                Native.SetWindowPos(handle, new IntPtr(wasTopmost ? -1 : -2), 0, 0, 0, 0, 0x13);
                if (cursor) SetPhysicalCursorPos(previous.X, previous.Y);
            }
        }
        Check("fixture window activated", Native.GetForegroundWindow() == handle);
    }
    static async Task Focus(AutomationElement window, AutomationElement field)
    {
        await Activate(window, field);
        var handle = (IntPtr)window.Current.NativeWindowHandle;
        uint thread = Native.GetWindowThreadProcessId(handle, out _), current = GetCurrentThreadId();
        AttachThreadInput(current, thread, true);
        try { SetForegroundWindow(handle); field.SetFocus(); }
        finally { AttachThreadInput(current, thread, false); }
        await Task.Delay(150);
        Check("fictional field focused", AutomationElement.FocusedElement.GetRuntimeId().SequenceEqual(field.GetRuntimeId()));
        Check("field confirms keyboard focus", field.Current.HasKeyboardFocus && field.Current.IsKeyboardFocusable);
    }
    static string Read(AutomationElement field) => ((TextPattern)field.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.GetText(-1);
    static void End(AutomationElement field)
    {
        var range = ((TextPattern)field.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.Clone();
        range.MoveEndpointByRange(TextPatternRangeEndpoint.Start, range, TextPatternRangeEndpoint.End); range.Select();
    }
    static async Task Run()
    {
        if (speedOnly) { await Speed(); return; }
        if (werOnly) { await Wer(); return; }
        if (speedInsertOnly) { await SpeedInsert(); return; }
        if (finalPriorityOnly) { await FinalPriority(); return; }
        if (touchScrollOnly) { await TouchScroll(); return; }
        if (touchCapsuleOnly) { await TouchCapsule(); return; }
        if (chromiumOnly) { await ChromiumFields(); return; }
        if (chromiumColdOnly) { await ChromiumCold(); return; }
        if (liveTextOnly) { await LiveText(); return; }
        if (liveFocusOnly) { await LiveFocus(); return; }
        if (inlineOnly) { await Inline(); return; }
        if (scrollFramesOnly) { await ScrollFramesRun(); return; }
        if (ownerStateOnly) { await OwnerState(); return; }
        if (diagTakesOnly) { await DiagTakes(); return; }
        if (writerOnly) { await Writer(); return; }
        if (chromeReplaceOnly) { await ChromeReplace(); return; }
        if (reportButtonOnly) { await ReportButton(); return; }
        if (chromeGuardOnly) { await ChromeGuard(); return; }
        if (chromeLiveOnly) { await ChromeLive(); return; }
        if (slowLiveOnly) { await SlowLive(); return; }
        if (inlineElevatedOnly) { await InlineElevated(); return; }
        if (statisticsOnly) { await StatisticsPage(); return; }
        if (templateCatalogOnly) { await CustomTemplates(); return; }
        if (workerSafetyOnly) { await WorkerSafety(); return; }
        if (extendedLatencyOnly) { await ExtendedLatency(); return; }
        if (insertionLatencyOnly) { await Processing(); return; }
        if (warmLatencyOnly) { await WarmLatency(); return; }
        if (speechOnly) { await SpeechLatency(); return; }
        if (waveformsOnly) { await WaveformFrames(); return; }
        if (payloadSpacingOnly) { SpacingProviderChecks(); return; }
        if (payloadOnly) { PayloadSpacing(); return; }
        if (compactFixOnly) { await CompactFixChecks(); return; }
        if (compactOnly) { await CompactAndSpacing(); return; }
        if (capsuleOnly) { await CapsuleVisuals(); return; }
        if (settingsOnly) { await LatencySettings(); return; }
        if (processingOnly) { await Processing(); return; }
        if (fallbackOnly) { await CaptureFallback(); return; }
        if (appearanceOnly) { await Appearance(); return; }
        if (appearanceRenderOnly) { await AppearanceRenders(); return; }
        if (appearanceColorsOnly) { await AppearanceColorContrast(); return; }
        if (micOnly) { await Microphone(); return; }
        if (secureOnly) { await SecureField(); return; }
        using var owner = new HwndSource(new HwndSourceParameters("pFlow live fixture clipboard owner") { Width = 10, Height = 10 });
        InsertionTarget? priorTarget = null;
        string name = "pflow-fictional-" + Guid.NewGuid().ToString("N"); string file = Path.Combine(root, name + ".txt");
        if (!edgeOnly) {
        File.WriteAllText(file, "Fictional training prefix. ");
        var start = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; start.ArgumentList.Add(file); Process.Start(start);
        var notepad = await WindowWith(name); var edit = await Editor(notepad); await Focus(notepad, edit); End(edit);
        var target = InsertionTarget.Capture(); string before = Read(edit);
        // Which Notepad and which Windows this run drives, and the path the app took for it.
        var notepadLog = new List<string>(); InsertionLog.Written += line => notepadLog.Add(line);
        string notepadVersion = "unknown"; try { notepadVersion = Process.GetProcessById(notepad.Current.ProcessId).MainModule?.FileVersionInfo.ProductVersion ?? "unknown"; } catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        Console.WriteLine($"NOTEPAD Windows {Environment.OSVersion.Version} ({RuntimeInformation.OSArchitecture}, test process {RuntimeInformation.ProcessArchitecture}); Notepad {notepadVersion}; field {target.Kind}");
        string transcript = File.ReadAllText(Path.Combine(root, "fictional-output.txt")).Trim();
        string result = await target.Insert(transcript, owner.Handle, false, CancellationToken.None);
        Check("Notepad offline speech fixture inserted", Normalize(Read(edit)) == Normalize(before + transcript));
        Check("Notepad insertion acknowledged", result == "Inserted");
        Check("Windows 11 Notepad (RichEditD2DPT, a Win32 rich edit inside XAML) takes the whole-value path and confirms it; classic Notepad (Edit) the same",
            (target.Kind.Contains("RichEditD2DPT") || target.Kind.Contains("/Edit/")) && target.Kind.EndsWith("/Win32") && notepadLog.Any(l => l.Contains("path=value")) && notepadLog.Any(l => l.Contains(": confirmed")));
        End(edit); target = InsertionTarget.Capture(); before = Read(edit);
        string narration = string.Concat(Enumerable.Repeat("Fictional 李 👮🏽‍♀️ 123.\n\nRelated sentence. ", 1000));
        result = await target.Insert(narration, owner.Handle, false, CancellationToken.None);
        // The caret sat after a full stop, so insertion spacing adds one space before the narration.
        Check("Notepad long multiline Unicode inserted", Normalize(Read(edit)) == Normalize(before + " " + narration));
        Check("Notepad long insertion acknowledged", result == "Inserted");
        End(edit); target = InsertionTarget.Capture();
        ((TextPattern)edit.GetCurrentPattern(TextPattern.Pattern)).DocumentRange.Select();
        bool selectionRefused = false; try { await target.Insert("Must not insert", owner.Handle, false, CancellationToken.None); } catch (InvalidOperationException) { selectionRefused = true; }
        Check("changed selection refused in real Notepad", selectionRefused);
        End(edit); target = InsertionTarget.Capture();
        priorTarget = target;
        }
        if (notepadOnly) return;
        string html = Path.Combine(root, name + ".html");
        File.WriteAllText(html, "<!doctype html><meta charset=utf-8><title>" + name + " form</title><label>Fictional dictation<textarea id=fixture aria-label='Fictional dictation' autofocus></textarea></label><label>Private fixture password<input type=password aria-label='Private fixture password'></label>");
        string edgePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Microsoft", "Edge", "Application", "msedge.exe");
        var edge = new ProcessStartInfo(edgePath) { UseShellExecute = false };
        foreach (var arg in new[] { "--user-data-dir=" + Path.Combine(root, "edge-fictional-profile"), "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--force-renderer-accessibility", "--app=" + new Uri(html).AbsoluteUri }) edge.ArgumentList.Add(arg);
        Process.Start(edge); var edgeWindow = await WindowWith(name + " form"); var edgeField = await Editor(edgeWindow); await Focus(edgeWindow, edgeField);
        if (priorTarget != null) { bool focusRefused = false; try { await priorTarget.Insert("Must not insert", owner.Handle, false, CancellationToken.None); } catch (InvalidOperationException) { focusRefused = true; } Check("focus change to Edge refused", focusRefused); }
        End(edgeField); var edgeTarget = InsertionTarget.Capture(); string edgeBefore = Read(edgeField);
        string edgeResult = await edgeTarget.Insert("Fictional Edge 李 123.\n\nSecond paragraph.", owner.Handle, false, CancellationToken.None);
        Check("Edge Unicode paragraphs inserted", Normalize(Read(edgeField)) == Normalize(edgeBefore + "Fictional Edge 李 123.\n\nSecond paragraph."));
        Check("Edge insertion acknowledged", edgeResult == "Inserted");
        var secure = edgeWindow.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.IsPasswordProperty, true));
        if (secure == null) throw new Exception("Secure fixture field was not exposed.");
        await Focus(edgeWindow, secure); bool secureRefused = false;
        try { InsertionTarget.Capture(); } catch (InvalidOperationException error) { secureRefused = error.Message == "Dictation is off in password fields."; }
        Check("real Edge password field refused", secureRefused);
        Console.WriteLine("Electron editor NOT RUN: no installed Electron editor was found.");
    }
    static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(root); i++) {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
            if (child is T value) yield return value;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }
    static double Contrast(System.Windows.Media.Color text, System.Windows.Media.Color background)
    {
        double L(System.Windows.Media.Color c) { double Linear(byte b) { double v = b / 255.0; return v <= .04045 ? v / 12.92 : Math.Pow((v + .055) / 1.055, 2.4); } return .2126 * Linear(c.R) + .7152 * Linear(c.G) + .0722 * Linear(c.B); }
        double a = L(text), b = L(background); return (Math.Max(a, b) + .05) / (Math.Min(a, b) + .05);
    }
    static async Task CustomTemplates()
    {
        string directory = Path.Combine(root, "custom-templates-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        using var keyboard = new KeyboardHook(_ => {}) { Enabled = false };
        var store = new PFlow.Core.StateStore(directory);
        SettingsWindow Make() => new(store, new Whisper(directory), new LocalTextModel(directory), keyboard, () => {}, () => false) { Title = "pFlow fictional custom templates", ShowActivated = false };
        var window = Make();
        async Task Invoke(string caption) {
            var button = Descendants<System.Windows.Controls.Button>(window).Single(x => AutomationProperties.GetName(x) == caption || x.Content as string == caption);
            var peer = System.Windows.Automation.Peers.UIElementAutomationPeer.CreatePeerForElement(button);
            ((System.Windows.Automation.Provider.IInvokeProvider)peer.GetPattern(System.Windows.Automation.Peers.PatternInterface.Invoke)).Invoke();
            await Task.Delay(80); window.UpdateLayout();
        }
        try {
            window.Show(); await Task.Delay(150); await Invoke("Templates");
            var picker = Descendants<System.Windows.Controls.ComboBox>(window).Single(x => AutomationProperties.GetName(x) == "Your templates");
            Check("templates page starts empty without sample names", picker.Items.Count == 0 && Descendants<System.Windows.Controls.TextBlock>(window).Any(x => x.Text.StartsWith("No templates yet.")));
            var create = Descendants<System.Windows.Controls.Button>(window).Single(x => x.Content as string == "New template");
            Check("creating a template requires a user name", !create.IsEnabled);
            var name = Descendants<System.Windows.Controls.TextBox>(window).Single(x => AutomationProperties.GetName(x) == "Template name");
            name.Text = "  Bicycle visit  "; Check("a supplied name enables creation", create.IsEnabled);
            await Invoke("New template");
            var editor = Descendants<System.Windows.Controls.TextBox>(window).Single(x => x.AcceptsReturn);
            var draft = System.Text.Json.JsonSerializer.Deserialize<PFlow.Core.DictationTemplate>(editor.Text, PFlow.Core.StateStore.Json)!;
            Check("draft uses the user supplied name without automatic examples", draft.Name == "Bicycle visit" && store.Preferences.Templates.Count == 0);
            draft.Sections = [new() { Title = "Visit notes", IncludeFullDictation = true }]; editor.Text = System.Text.Json.JsonSerializer.Serialize(draft, PFlow.Core.StateStore.Json);
            await Invoke("Save template JSON");
            Check("user template saves and becomes selected", picker.Items.Count == 1 && store.Preferences.ActiveTemplateId == draft.Id && store.Preferences.Templates.Single().Sections.Single().Title == "Visit notes");
            Check("empty hint hides after saving a template", Descendants<System.Windows.Controls.TextBlock>(window).Single(x => x.Text.StartsWith("No templates yet.")).Visibility == Visibility.Collapsed);
            await Invoke("Use plain dictation"); Check("plain dictation keeps the user's template", store.Preferences.ActiveTemplateId == null && store.Preferences.Templates.Count == 1);
            window.Close(); store = new PFlow.Core.StateStore(directory); window = Make(); window.Show(); await Task.Delay(150); await Invoke("Templates");
            picker = Descendants<System.Windows.Controls.ComboBox>(window).Single(x => AutomationProperties.GetName(x) == "Your templates");
            Check("reopening keeps only the user-created template", picker.Items.Count == 1 && ((PFlow.Core.DictationTemplate)picker.Items[0]).Name == "Bicycle visit");
        } finally { window.Close(); Directory.Delete(directory, true); }
    }
    static async Task LatencySettings()
    {
        string directory = Path.Combine(root, "settings-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        using var keyboard = new KeyboardHook(_ => { }) { Enabled = false };
        var store = new PFlow.Core.StateStore(directory);
        var window = new SettingsWindow(store, new Whisper(directory), new LocalTextModel(directory), keyboard, () => { }, () => false);
        window.Title = "pFlow fictional latency settings";
        try {
            window.Show(); await Task.Delay(200);
            await Activate(AutomationElement.FromHandle(new WindowInteropHelper(window).Handle));
            async Task Key(FrameworkElement control, ushort key) {
                control.BringIntoView(); control.Focus(); await Task.Delay(100);
                Check("new option accepts keyboard focus", control.IsKeyboardFocusWithin);
                Native.Send(new Native.Input { Type = 1, Data = new() { Keyboard = new() { Vk = key } } }, new Native.Input { Type = 1, Data = new() { Keyboard = new() { Vk = key, Flags = Native.KEYEVENTF_KEYUP } } });
                await Task.Delay(150);
            }
            Check("no AI cleanup switch is offered", !Descendants<System.Windows.Controls.CheckBox>(window).Any(x => (x.Content as string ?? "").Contains("AI cleanup")));
            var paragraphs = Descendants<System.Windows.Controls.CheckBox>(window).Single(x => x.Content as string == "Group long narrations into paragraphs");
            Check("paragraphs start on", paragraphs.IsChecked == true);
            await Key(paragraphs, 0x20); Check("paragraph choice persists", !new PFlow.Core.StateStore(directory).Preferences.Paragraphs);
            await Key(paragraphs, 0x20); Check("paragraph choice persists again", new PFlow.Core.StateStore(directory).Preferences.Paragraphs);
            var language = Descendants<System.Windows.Controls.ComboBox>(window).Single(x => AutomationProperties.GetName(x) == "Speech language");
            Check("English starts selected", language.SelectedValue as string == "en");
            Check("automatic guessing is absent", !language.Items.Cast<KeyValuePair<string, string>>().Any(x => x.Key == "auto"));
            await Key(language, 0x28); Check("Spanish preset persists", new PFlow.Core.StateStore(directory).Preferences.Language == "es");
            await Key(language, 0x26); Check("English choice persists", new PFlow.Core.StateStore(directory).Preferences.Language == "en");
        } finally { window.Close(); Directory.Delete(directory, true); }
    }
    static async Task AppearanceColorContrast()
    {
        string directory = Path.Combine(root, "appearance-colors-fictional-" + Guid.NewGuid());
        using var keyboard = new KeyboardHook(_ => { }) { Enabled = false };
        var store = new PFlow.Core.StateStore(directory);
        var window = new SettingsWindow(store, new Whisper(directory), new LocalTextModel(directory), keyboard, () => { }, () => false) { ShowActivated = false };
        try {
            window.Show(); await Task.Delay(100);
            foreach (string value in new[] { "000000", "FFFFFF", "777777", "FF9DC4" }) {
                store.Preferences.Palette = "custom"; store.Preferences.CustomAccent = value; store.Preferences.Accent = value;
                PeshTheme.Apply(window, store.Preferences); window.UpdateLayout();
                var selected = Descendants<System.Windows.Controls.RadioButton>(window).Single(x => x.GroupName == "Appearance" && x.IsChecked == true);
                Check(value + " selected segment label is readable", Contrast(((System.Windows.Media.SolidColorBrush)selected.Foreground).Color, ((System.Windows.Media.SolidColorBrush)window.Resources["PeshAccent"]).Color) >= 4.5);
            }
        } finally { window.Close(); Directory.Delete(directory, true); }
    }
    static async Task AppearanceRenders()
    {
        string directory = Path.Combine(root, "appearance-render-fictional-" + Guid.NewGuid());
        using var keyboard = new KeyboardHook(_ => { }) { Enabled = false };
        var store = new PFlow.Core.StateStore(directory);
        try {
            foreach (string theme in new[] { "dark", "light" }) {
                store.Preferences.Theme = theme;
                var window = new SettingsWindow(store, new Whisper(directory), new LocalTextModel(directory), keyboard, () => { }, () => false) { ShowActivated = false };
                try {
                    window.Show(); await Task.Delay(150); window.UpdateLayout();
                    var scroller = Descendants<System.Windows.Controls.ScrollViewer>(window).First();
                    var bar = Descendants<System.Windows.Controls.Primitives.ScrollBar>(window).First(x => x.Orientation == System.Windows.Controls.Orientation.Vertical && x.IsVisible);
                    var track = (System.Windows.Controls.Primitives.Track)bar.Template.FindName("PART_Track", bar);
                    var down = track.IncreaseRepeatButton;
                    ((System.Windows.Input.RoutedCommand)down.Command).Execute(null, down.CommandTarget);
                    await Task.Delay(100); window.UpdateLayout();
                    Check(theme + " thin scrollbar pages down", scroller.VerticalOffset > 0);
                    var up = track.DecreaseRepeatButton;
                    ((System.Windows.Input.RoutedCommand)up.Command).Execute(null, up.CommandTarget);
                    await Task.Delay(100); window.UpdateLayout();
                    Check(theme + " thin scrollbar pages up", scroller.VerticalOffset == 0);
                    var content = (FrameworkElement)window.Content;
                    var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * 2), (int)Math.Ceiling(content.ActualHeight * 2), 192, 192, System.Windows.Media.PixelFormats.Pbgra32); bitmap.Render(content);
                    var pixels = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4]; bitmap.CopyPixels(pixels, bitmap.PixelWidth * 4, 0);
                    Check(theme + " client image is opaque", Enumerable.Range(0, pixels.Length / 4).All(i => pixels[i * 4 + 3] == 255));
                    Check(theme + " backdrop matches appearance", theme == "dark" ? pixels[0] < 70 && pixels[1] < 60 && pixels[2] < 60 : pixels[0] > 200 && pixels[1] > 200 && pixels[2] > 200);
                    var png = new System.Windows.Media.Imaging.PngBitmapEncoder(); png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap)); using var output = File.Create(Path.Combine(root, "appearance-mac-" + theme + ".png")); png.Save(output);
                } finally { window.Close(); }
            }
        } finally { Directory.Delete(directory, true); }
    }
    static async Task Appearance()
    {
        string directory = Path.Combine(root, "appearance-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        using var keyboard = new KeyboardHook(_ => { }) { Enabled = false };
        var store = new PFlow.Core.StateStore(directory);
        store.Preferences.CustomAccent = "F587B5"; store.Preferences.WaveBlend = "4EE5B3"; store.SavePreferences();
        SettingsWindow Make() => new(store, new Whisper(directory), new LocalTextModel(directory), keyboard, () => { }, () => false) { Title = "pFlow fictional appearance fixture", ShowActivated = false };
        var window = Make();
        try {
            window.Show(); await Task.Delay(200); window.UpdateLayout();
            async Task Select(string label) {
                var option = Descendants<System.Windows.Controls.RadioButton>(window).Single(x => AutomationProperties.GetName(x) == label);
                var peer = System.Windows.Automation.Peers.UIElementAutomationPeer.CreatePeerForElement(option);
                var provider = (System.Windows.Automation.Provider.ISelectionItemProvider)peer.GetPattern(System.Windows.Automation.Peers.PatternInterface.SelectionItem);
                Check(label + " exposes native selection", provider != null);
                provider!.Select(); await Task.Delay(100); window.UpdateLayout();
                Check(label + " becomes selected", option.IsChecked == true && provider.IsSelected);
            }
            async Task Invoke(System.Windows.Controls.Button button) {
                button.BringIntoView();
                var peer = System.Windows.Automation.Peers.UIElementAutomationPeer.CreatePeerForElement(button);
                ((System.Windows.Automation.Provider.IInvokeProvider)peer.GetPattern(System.Windows.Automation.Peers.PatternInterface.Invoke)).Invoke();
                await Task.Delay(100); window.UpdateLayout();
            }
            void Render(string name) {
                var content = (FrameworkElement)window.Content;
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * 2), (int)Math.Ceiling(content.ActualHeight * 2), 192, 192, System.Windows.Media.PixelFormats.Pbgra32); bitmap.Render(content);
                var png = new System.Windows.Media.Imaging.PngBitmapEncoder(); png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap)); using var output = File.Create(Path.Combine(root, "appearance-mac-" + name + ".png")); png.Save(output);
            }
            Check("original Pesh artwork loaded", Descendants<System.Windows.Controls.Image>(window).Any(x => x.Source is System.Windows.Media.Imaging.BitmapSource image && image.PixelWidth == 264 && image.PixelHeight == 240));
            Check("Mac appearance choices replace generic pickers", Descendants<System.Windows.Controls.RadioButton>(window).Count() == 9);
            foreach (string theme in new[] { "Dark", "Light", "System" }) {
                await Select(theme);
                Check(theme + " saved on disk", new PFlow.Core.StateStore(directory).Preferences.Theme == theme.ToLowerInvariant());
                var field = Descendants<System.Windows.Controls.ComboBox>(window).Single(x => AutomationProperties.GetName(x) == "Speech language");
                Check(theme + " actual input contrast", Contrast(((System.Windows.Media.SolidColorBrush)field.Foreground).Color, ((System.Windows.Media.SolidColorBrush)field.Background).Color) >= 4.5);
                var selected = Descendants<System.Windows.Controls.RadioButton>(window).Single(x => AutomationProperties.GetName(x) == theme);
                Check(theme + " selected label contrast", Contrast(((System.Windows.Media.SolidColorBrush)selected.Foreground).Color, ((System.Windows.Media.SolidColorBrush)window.Resources["PeshAccent"]).Color) >= 4.5);
                if (theme != "System") Render(theme.ToLowerInvariant());
            }
            bool systemLight = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 0) is int mode && mode == 1;
            Check("System matches Windows appearance", ((System.Windows.Media.SolidColorBrush)window.Background).Color.ToString() == (systemLight ? "#FFF6F2F9" : "#FF08070D"));
            foreach (string palette in new[] { "Aurora", "Solar", "Custom", "Pesh" }) {
                await Select(palette + " colors");
                var saved = new PFlow.Core.StateStore(directory).Preferences;
                Check(palette + " colors saved on disk", saved.Palette == palette.ToLowerInvariant());
                Check(palette + " retains custom colors", saved.CustomAccent == "F587B5" && saved.WaveBlend == "4EE5B3");
                var custom = Descendants<System.Windows.Controls.Button>(window).Single(x => AutomationProperties.GetName(x) == "Accent color");
                Check("custom controls visibility follows " + palette, custom.IsVisible == (palette == "Custom"));
                var colors = (System.Windows.Media.LinearGradientBrush)window.Resources["PeshGradient"];
                Check(palette + " gradient has distinct ends", colors.GradientStops.First().Color != colors.GradientStops.Last().Color);
                if (palette == "Custom") Check("custom gradient uses saved ends", colors.GradientStops.First().Color.ToString() == "#FFF587B5" && colors.GradientStops.Last().Color.ToString() == "#FF4EE5B3");
            }
            await Select("Lines waveform"); Check("Lines persists", new PFlow.Core.StateStore(directory).Preferences.Waveform == "lines");
            await Select("Wave waveform"); Check("Wave persists", new PFlow.Core.StateStore(directory).Preferences.Waveform == "wave");
            foreach (var item in new[] { ("Templates", "Save template JSON"), ("Usage statistics", "Back"), ("View history", "Refresh History"), ("Dictionary", "Save learned terms") }) {
                await Invoke(Descendants<System.Windows.Controls.Button>(window).Single(x => AutomationProperties.GetName(x) == item.Item1));
                Check(item.Item1 + " opens controls", Descendants<System.Windows.Controls.Button>(window).Any(x => x.Content as string == item.Item2));
                string? draft = null;
                if (item.Item1 is "Templates" or "Dictionary") { draft = "Fictional unsaved " + item.Item1 + " draft."; Descendants<System.Windows.Controls.TextBox>(window).First(x => x.AcceptsReturn).Text = draft; }
                await Invoke(Descendants<System.Windows.Controls.Button>(window).Single(x => x.Content as string == "Back"));
                Check(item.Item1 + " returns home", Descendants<System.Windows.Controls.RadioButton>(window).Count() == 9);
                if (draft != null) {
                    await Invoke(Descendants<System.Windows.Controls.Button>(window).Single(x => AutomationProperties.GetName(x) == item.Item1));
                    Check(item.Item1 + " retains draft", Descendants<System.Windows.Controls.TextBox>(window).First(x => x.AcceptsReturn).Text == draft);
                    await Invoke(Descendants<System.Windows.Controls.Button>(window).Single(x => x.Content as string == "Back"));
                }
            }
            window.Width = window.MinWidth; window.Height = window.MinHeight; window.UpdateLayout();
            Check("small window scrolls", Descendants<System.Windows.Controls.ScrollViewer>(window).Any(x => x.ScrollableHeight > 0 && x.ViewportWidth > 0));
            var choices = Descendants<System.Windows.Controls.RadioButton>(window).Where(x => x.GroupName == "Colors").ToList();
            Check("small window fits swatch captions", choices.All(x => x.ActualWidth >= 55));
            Descendants<System.Windows.Controls.CheckBox>(window).Last().BringIntoView(); await Task.Delay(100);
            var scroller = Descendants<System.Windows.Controls.ScrollViewer>(window).First();
            var bottom = Descendants<System.Windows.Controls.CheckBox>(window).Last();
            var bounds = bottom.TransformToAncestor(scroller).TransformBounds(new Rect(bottom.RenderSize));
            Check("small window reaches bottom settings", scroller.VerticalOffset > 0 && bounds.Top >= 0 && bounds.Bottom <= scroller.ViewportHeight + 1);
            window.Close(); store = new PFlow.Core.StateStore(directory); window = Make(); window.Show(); await Task.Delay(100);
            Check("reopen retains theme", Descendants<System.Windows.Controls.RadioButton>(window).Single(x => (string)x.Tag == "system").IsChecked == true);
            Check("reopen retains palette", Descendants<System.Windows.Controls.RadioButton>(window).Single(x => (string)x.Tag == "pesh").IsChecked == true);
            Check("reopen retains waveform", Descendants<System.Windows.Controls.RadioButton>(window).Single(x => x.GroupName == "Waveform" && (string)x.Tag == "wave").IsChecked == true);
            Console.WriteLine("Provider-driven native UI checks; physical keyboard/mouse and native color dialog NOT RUN.");
        } finally { window.Close(); Directory.Delete(directory, true); }
    }
    [StructLayout(LayoutKind.Sequential)] struct ScreenPoint { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetPhysicalCursorPos(out ScreenPoint point);
    [DllImport("user32.dll")] static extern bool SetPhysicalCursorPos(int x, int y);
    static async Task CaptureFallback()
    {
        var button = new System.Windows.Controls.Button { Content = "Fictional nonediting area", Margin = new Thickness(16) };
        var text = new System.Windows.Controls.TextBox { Margin = new Thickness(16), AcceptsReturn = true, Height = 80 };
        var stack = new System.Windows.Controls.StackPanel(); stack.Children.Add(button); stack.Children.Add(text);
        var window = new Window { Title = "pFlow fictional capture fixture", Content = stack, Width = 460, Height = 260 };
        string directory = Path.Combine(root, "capture-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        Capsule? capsule = null;
        try {
            window.Show(); await Task.Delay(200);
            var owner = AutomationElement.FromHandle(new WindowInteropHelper(window).Handle);
            await Activate(owner); button.Focus(); await Task.Delay(100);
            var target = InsertionTarget.Capture();
            Check("noneditable field permits History-only capture", !target.CanInsert);
            var metadata = target.ApplicationId;
            text.Focus(); await Task.Delay(100); uint sequence = Native.GetClipboardSequenceNumber();
            foreach (bool copy in new[] { false, true }) {
                string result = await target.Insert("Fictional must stay in History.", IntPtr.Zero, copy, CancellationToken.None);
                Check("History-only target reports saved, clipboard preference " + copy, result == InsertionTarget.SavedToHistory);
                Check("History-only target never inserts into new focus " + copy, text.Text.Length == 0);
                Check("History-only target never changes clipboard " + copy, Native.GetClipboardSequenceNumber() == sequence);
            }
            Check("History-only application identity retained", target.ApplicationId == metadata && metadata.Length > 0);
            var store = new PFlow.Core.StateStore(directory); capsule = new Capsule(store); int clicks = 0;
            Check("capsule starts hidden", !capsule.IsVisible);
            capsule.ToggleRecording += () => { clicks++; capsule.Set(clicks == 1 ? PFlow.Core.Phase.Continuous : PFlow.Core.Phase.Idle); };
            var focused = AutomationElement.FocusedElement.GetRuntimeId(); var foreground = Native.GetForegroundWindow();
            capsule.Reveal(); await Task.Delay(150);
            Check("showing capsule preserves original field", Native.GetForegroundWindow() == foreground && AutomationElement.FocusedElement.GetRuntimeId().SequenceEqual(focused));
            ScreenPoint cursor; Check("read fixture cursor position", GetPhysicalCursorPos(out cursor));
            try {
                double oldLeft = capsule.Left, oldTop = capsule.Top;
                var dragButton = AutomationElement.FromHandle(capsule.Handle).FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, "Start recording"));
                var dragRect = dragButton.Current.BoundingRectangle;
                int dragX = (int)(dragRect.X + dragRect.Width / 2), dragY = (int)(dragRect.Y + dragRect.Height / 2);
                SetPhysicalCursorPos(dragX, dragY);
                Native.Send(new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 2 } } });
                await Task.Run(async () => {
                    await Task.Delay(120);
                    for (int step = 1; step <= 5; step++) { SetPhysicalCursorPos(dragX - step * 6, dragY - step * 3); await Task.Delay(60); }
                    Native.Send(new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 4 } } });
                });
                await Task.Delay(150);
                Console.WriteLine($"Drag diagnostic before={oldLeft:F1},{oldTop:F1} after={capsule.Left:F1},{capsule.Top:F1} clicks={clicks}");
                Check("drag moves capsule without recording", Math.Abs(capsule.Left - oldLeft) > 4 && clicks == 0);
                Check("drag position persisted", new PFlow.Core.StateStore(directory).Preferences.CapsuleX == capsule.Left);
                Check("drag preserves original foreground", Native.GetForegroundWindow() == foreground);
                Check("drag preserves original field", AutomationElement.FocusedElement.GetRuntimeId().SequenceEqual(focused));
                capsule.Left = oldLeft; capsule.Top = oldTop;

                for (int i = 0; i < 2; i++) {
                    string label = i == 0 ? "Start recording" : "Stop recording";
                    var record = AutomationElement.FromHandle(capsule.Handle).FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, label));
                    Check("capsule exposes " + label, record != null);
                    var rectangle = record!.Current.BoundingRectangle;
                    Check("point to physical capsule control", SetPhysicalCursorPos((int)(rectangle.X + rectangle.Width / 2), (int)(rectangle.Y + rectangle.Height / 2)));
                    Native.Send(new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 2 } } }, new Native.Input { Type = 0, Data = new() { Mouse = new() { Flags = 4 } } });
                    await Task.Delay(150);
                    Check("real capsule mouse click routes start or stop", clicks == i + 1);
                    Check("capsule click keeps original foreground", Native.GetForegroundWindow() == foreground);
                    Check("capsule click keeps original text field", AutomationElement.FocusedElement.GetRuntimeId().SequenceEqual(focused));
                }
            } finally { SetPhysicalCursorPos(cursor.X, cursor.Y); }
            Check("idle capsule hides after stop", !capsule.IsVisible);
            await CheckCapsuleVisuals(capsule);
        } finally { capsule?.Close(); window.Close(); Directory.Delete(directory, true); }
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[]? small, uint count);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    static async Task CompactAndSpacing()
    {
        string directory = Path.Combine(root, "compact-fictional-" + Guid.NewGuid());
        var store = new PFlow.Core.StateStore(directory);
        Capsule? capsule = new(store);
        try {
            var screen = System.Windows.Forms.Screen.FromHandle(Native.GetForegroundWindow()).WorkingArea;
            capsule.Set(PFlow.Core.Phase.Processing); await Task.Delay(180); capsule.UpdateLayout();
            Native.GetWindowRect(capsule.Handle, out var bounds);
            Check("capsule matches Mac logical dimensions", capsule.Width == 120 && capsule.Height == 32);
            Check("capsule defaults to focused display bottom center", Math.Abs((bounds.Left + bounds.Right) / 2.0 - (screen.Left + screen.Width / 2.0)) <= 2 && Math.Abs(screen.Bottom - bounds.Bottom - (bounds.Bottom - bounds.Top) * 1.25) <= 2);
            Check("visible processing uses render frames", capsule.Animating);
            await CheckCapsuleVisuals(capsule);
            Check("hidden capsule detaches frame callback", !capsule.Animating);
            store.Preferences.CapsulePositionVersion = 1; store.Preferences.CapsuleX = screen.Left + 60; store.Preferences.CapsuleY = screen.Top + 60; store.SavePreferences();
            capsule.Close(); capsule = new Capsule(new PFlow.Core.StateStore(directory)); capsule.Set(PFlow.Core.Phase.Processing); await Task.Delay(120);
            Native.GetWindowRect(capsule.Handle, out bounds);
            Check("saved physical position survives relaunch", bounds.Left == screen.Left + 60 && bounds.Top == screen.Top + 60);
            capsule.ResetPosition(); await Task.Delay(100); Native.GetWindowRect(capsule.Handle, out bounds);
            Check("reset returns to bottom center", Math.Abs((bounds.Left + bounds.Right) / 2.0 - (screen.Left + screen.Width / 2.0)) <= 2);
            var saved = new PFlow.Core.StateStore(directory).Preferences; Check("reset clears custom position on disk", saved.CapsuleX == -1 && saved.CapsuleY == -1 && saved.CapsulePositionVersion == 0);
            RichSpacingChecks(); IconChecks();
        } finally { capsule?.Close(); Directory.Delete(directory, true); }
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint exStyle, string className, string text, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
    static void PayloadSpacing()
    {
        using var owner = new HwndSource(new HwndSourceParameters("pFlow private paragraph fixture") { Width = 300, Height = 200, WindowStyle = 0 });
        IntPtr field = CreateWindowEx(0, "EDIT", "", 0x40000000 | 0x4 | 0x40 | 0x1000, 0, 0, 280, 180, owner.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        Check("private Windows multiline field created", field != IntPtr.Zero);
        try {
            const string text = "First sentence.\n\nSecond paragraph. 👮🏽‍♀️\r\nThird line.";
            var packets = Native.UnicodeText(text);
            Check("text input never sends Return key shortcuts", packets.All(x => x.Data.Keyboard.Vk == 0 && (x.Data.Keyboard.Flags & Native.KEYEVENTF_UNICODE) != 0));
            foreach (var packet in packets) if ((packet.Data.Keyboard.Flags & Native.KEYEVENTF_KEYUP) == 0) SendMessage(field, 0x102, (IntPtr)packet.Data.Keyboard.Scan, IntPtr.Zero);
            var actual = new System.Text.StringBuilder(1000); GetWindowText(field, actual, actual.Capacity);
            Check("production Unicode packets preserve paragraphs in Windows field", PFlow.Core.TextProcessing.SameText(actual.ToString(), text));
        } finally { if (field != IntPtr.Zero) DestroyWindow(field); }
        SpacingProviderChecks();
    }
    static void SpacingProviderChecks()
    {
        var editor = new System.Windows.Controls.TextBox { Text = "First sentence." };
        var peer = new System.Windows.Automation.Peers.TextBoxAutomationPeer(editor);
        var provider = (System.Windows.Automation.Provider.IValueProvider)peer.GetPattern(System.Windows.Automation.Peers.PatternInterface.Value);
        var prepared = InsertionTarget.Prepare(new PFlow.Core.FieldState(1, 1, "fictional", editor.Text, editor.Text.Length, 0), "Next sentence.");
        provider.SetValue(prepared.Expected);
        Check("production payload inserts a space through native provider", editor.Text == "First sentence. Next sentence." && prepared.Text == " Next sentence.");
        prepared = InsertionTarget.Prepare(new PFlow.Core.FieldState(1, 1, "fictional", "staff", 0, 5), "Sinton");
        provider.SetValue(prepared.Expected); Check("production payload keeps selected replacement exact", editor.Text == "Sinton" && prepared.Text == "Sinton");
    }
    static async Task WaveformFrames()
    {
        string directory = Path.Combine(root, "waveform-fictional-" + Guid.NewGuid()); var store = new PFlow.Core.StateStore(directory);
        var clock = Stopwatch.StartNew(); var capsule = new Capsule(store) { AudioLevel = () => .4 + Math.Sin(clock.Elapsed.TotalSeconds * 11) * .3 };
        try {
            capsule.Set(PFlow.Core.Phase.Recording); await Task.Delay(150);
            var wave = Descendants<WaveView>(capsule).Single(); long before = wave.Frames; double start = clock.Elapsed.TotalSeconds;
            if (!waveCaptureOnly) {
            int ticks = 0;
            var pulse = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => ticks++, Dispatcher.CurrentDispatcher);
            await Task.Delay(3000); pulse.Stop(); double elapsed = clock.Elapsed.TotalSeconds - start;
            double fps = (wave.Frames - before) / elapsed;
            var type = typeof(System.Windows.Media.Visual).Assembly.GetType("System.Windows.Media.MediaContext");
            var media = type?.GetProperty("CurrentMediaContext", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic)?.GetValue(null);
            Console.WriteLine($"Diagnostic dispatcher ticks/second: {ticks / elapsed:F1}");
            foreach (string field in new[] { "_displayRefreshRate", "_animationRenderRate", "_interlockState" }) Console.WriteLine(field + "=" + type?.GetField(field, System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)?.GetValue(media));
            Console.WriteLine($"Observed render cadence: {fps:F1} frames/second"); Check("wave follows display rendering cadence", fps >= 25);
            }
            foreach (string style in new[] { "wave", "lines" }) {
                store.Preferences.Waveform = style; await Task.Delay(160);
                byte[] Frame(string? name) {
                    var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(240, 64, 192, 192, System.Windows.Media.PixelFormats.Pbgra32); bitmap.Render(capsule);
                    if (name != null) { var png = new System.Windows.Media.Imaging.PngBitmapEncoder(); png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap)); using var file = File.Create(Path.Combine(root, "capsule-" + name + ".png")); png.Save(file); }
                    var bytes = new byte[240 * 64 * 4]; bitmap.CopyPixels(bytes, 240 * 4, 0); return bytes;
                }
                var first = Frame(style); await Task.Delay(600); Check(style + " animation changes actual rendered frames", !first.SequenceEqual(Frame(null)));
            }
        } finally { capsule.Close(); Directory.Delete(directory, true); }
    }
    static async Task CompactFixChecks()
    {
        string directory = Path.Combine(root, "compact-hitbox-fictional-" + Guid.NewGuid());
        var capsule = new Capsule(new PFlow.Core.StateStore(directory));
        try {
            capsule.Set(PFlow.Core.Phase.Processing); await Task.Delay(100); capsule.UpdateLayout();
            var button = Descendants<System.Windows.Controls.Button>(capsule).Single();
            Check("whole capsule interior accepts dragging", Math.Abs(button.ActualWidth - 118) < .1 && Math.Abs(button.ActualHeight - 30) < .1);
            var wave = Descendants<WaveView>(capsule).Single(); Check("compact waveform remains 100 by 20", Math.Abs(wave.ActualWidth - 100) < .1 && Math.Abs(wave.ActualHeight - 20) < .1);
            RichSpacingChecks(false); IconChecks();
        } finally { capsule.Close(); Directory.Delete(directory, true); }
    }
    static void RichSpacingChecks(bool verifyPlain = true)
    {
            var template = new PFlow.Core.DictationTemplate { BoldHeadings = true, Sections = [new() { Title = "Narrative", IncludeFullDictation = true }] };
            var formatted = PFlow.Core.RichText.Render("Morgan checked the blue bicycle.", template);
            var pad = PFlow.Core.InsertionSpacing.AtCaret(formatted.Text, "First sentence.", 15, 0);
            var editor = new System.Windows.Controls.RichTextBox();
            using (var data = new MemoryStream(System.Text.Encoding.ASCII.GetBytes(PFlow.Core.RichText.Pad(formatted.Rtf!, pad.Before, pad.After)!)))
                new System.Windows.Documents.TextRange(editor.Document.ContentStart, editor.Document.ContentEnd).Load(data, DataFormats.Rtf);
            string plain = new System.Windows.Documents.TextRange(editor.Document.ContentStart, editor.Document.ContentEnd).Text;
            if (verifyPlain) Check("rich text padding parses to exact spaced text", Normalize(plain).TrimEnd('\n') == pad.Apply(formatted.Text));
            IEnumerable<System.Windows.Documents.Run> Runs(System.Windows.Documents.InlineCollection inlines) {
                foreach (var inline in inlines) {
                    if (inline is System.Windows.Documents.Run run) yield return run;
                    else if (inline is System.Windows.Documents.Span span) foreach (var nested in Runs(span.Inlines)) yield return nested;
                }
            }
            var runs = editor.Document.Blocks.OfType<System.Windows.Documents.Paragraph>().SelectMany(x => Runs(x.Inlines)).ToArray();
            Check("rich heading stays bold after leading space", runs.Any(x => x.Text.Contains("Narrative") && x.FontWeight == FontWeights.Bold));
            Check("leading gap is outside bold heading", runs.First().Text.StartsWith(" ") && runs.First().FontWeight != FontWeights.Bold);
    }
    static void IconChecks()
    {
            string executable = Path.Combine(PackageAssets, "pFlow.exe");
            var icons = new IntPtr[1];
            Check("published EXE embeds an app icon", ExtractIconEx(executable, 0, icons, null, 1) == 1 && icons[0] != IntPtr.Zero);
            try {
                using var actualIcon = System.Drawing.Icon.FromHandle(icons[0]); using var actual = actualIcon.ToBitmap();
                using var stream = Application.GetResourceStream(new Uri("pack://application:,,,/pFlow;component/Assets/Pesh.ico")).Stream;
                using var expectedIcon = new System.Drawing.Icon(stream, actual.Width, actual.Height); using var expected = expectedIcon.ToBitmap();
                Check("published EXE icon is the speaking pig", Enumerable.Range(0, actual.Width).All(x => Enumerable.Range(0, actual.Height).All(y => actual.GetPixel(x, y).ToArgb() == expected.GetPixel(x, y).ToArgb())));
            } finally { DestroyIcon(icons[0]); }    }
    static async Task CapsuleVisuals()
    {
        string directory = Path.Combine(root, "capsule-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        var capsule = new Capsule(new PFlow.Core.StateStore(directory));
        try { await CheckCapsuleVisuals(capsule); }
        finally { capsule.Close(); Directory.Delete(directory, true); }
    }
    static async Task CheckCapsuleVisuals(Capsule capsule)
    {
            capsule.Set(PFlow.Core.Phase.Processing, "Transcribing"); capsule.UpdateLayout();
            Check("processing capsule visible", capsule.IsVisible);
            Check("capsule contains no visible text or icon", !Descendants<System.Windows.Controls.TextBlock>(capsule).Any() && !Descendants<System.Windows.Controls.Image>(capsule).Any());
            Check("processing state remains accessible", AutomationElement.FromHandle(capsule.Handle).FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.NameProperty, "Processing")) != null);
            byte[] Frame(string? filename = null) {
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)capsule.ActualWidth, (int)capsule.ActualHeight, 96, 96, System.Windows.Media.PixelFormats.Pbgra32); bitmap.Render(capsule);
                if (filename != null) { var png = new System.Windows.Media.Imaging.PngBitmapEncoder(); png.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap)); using var file = File.Create(Path.Combine(root, filename)); png.Save(file); }
                byte[] bytes = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4]; bitmap.CopyPixels(bytes, bitmap.PixelWidth * 4, 0); return bytes;
            }
            var first = Frame("capsule-processing.png"); await Task.Delay(220); var next = Frame();
            Check("processing line moves in actual render", !first.SequenceEqual(next));
            capsule.Set(PFlow.Core.Phase.Canceled); Check("canceled capsule hidden", !capsule.IsVisible);
            capsule.Set(PFlow.Core.Phase.Saved, InsertionTarget.SavedToHistory); Check("saved capsule hidden", !capsule.IsVisible);
            capsule.Set(PFlow.Core.Phase.Failed, "Fictional failure"); Check("failure capsule hidden", !capsule.IsVisible);
            capsule.Set(PFlow.Core.Phase.Inserted); Check("inserted capsule hidden", !capsule.IsVisible);
    }
    static async Task WarmLatency()
    {
        string directory = Path.Combine(root, "warm-latency-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        string assets = PackageAssets;
        await using var whisper = new Whisper(directory, assets);
        try {
            var watch = Stopwatch.StartNew(); await whisper.Prewarm(); int? id = whisper.WorkerId;
            Console.WriteLine($"Verified model warm-up: {watch.Elapsed.TotalMilliseconds:F0}ms");
            bool locked = false;
            try { using var change = new FileStream(whisper.ModelPath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite); }
            catch (IOException) { locked = true; }
            Check("verified model remains protected against replacement or writes", locked);
            var ratios = new List<double>();
            foreach (string name in new[] { "short-fictional", "latency-medium", "latency-long", "latency-numbers" }) {
                string audio = Path.Combine(root, name + ".wav"), output = Path.Combine(directory, "baseline");
                var info = new ProcessStartInfo(Path.Combine(assets, "engine", "whisper-cli.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                foreach (string argument in new[] { "-m", whisper.ModelPath, "-f", audio, "-l", "en", "-otxt", "-of", output, "-np", "-bs", "1", "-bo", "1", "-t", "5" }) info.ArgumentList.Add(argument);
                watch.Restart();
                using var process = Process.Start(info)!;
                var stdout = process.StandardOutput.BaseStream.CopyToAsync(Stream.Null); var stderr = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(90));
                using var kill = deadline.Token.Register(() => { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } });
                await process.WaitForExitAsync(deadline.Token); await Task.WhenAll(stdout, stderr);
                Check(name + " original CPU engine completed", process.ExitCode == 0);
                double baseline = watch.Elapsed.TotalMilliseconds;
                string expected = PFlow.Core.TextProcessing.JoinRecognitionLines((await File.ReadAllTextAsync(output + ".txt")).Trim());
                watch.Restart(); string text = await whisper.Transcribe(audio, "en", [], deadline.Token); double elapsed = watch.Elapsed.TotalMilliseconds;
                var metrics = whisper.LastMetrics;
                Check(name + " keeps original recognition words", Words(text) == Words(expected));
                if (name == "short-fictional") Check("warm short sentence stays exact", text == "Morgan checked the blue bicycle.");
                Check(name + " reuses the verified worker", metrics.Reused && whisper.WorkerId == id && metrics.InitializationMs < 100);
                Check(name + " recognition completes faster", elapsed < baseline);
                ratios.Add(baseline / elapsed);
                Console.WriteLine($"{name}: original={baseline:F0}ms warm={elapsed:F0}ms speedup={baseline/elapsed:F1}x context={metrics.AudioContext}");
            }
            Check("short and medium speech gain at least twofold", ratios.Take(2).All(ratio => ratio >= 2));
            using (var cancel = new CancellationTokenSource()) {
                var task = whisper.Transcribe(Path.Combine(root, "latency-long.wav"), "en", [], cancel.Token);
                await Task.Delay(40); cancel.Cancel(); bool canceled = false;
                try { await task; } catch (OperationCanceledException) { canceled = true; }
                Check("cancel aborts the owned inference promptly", canceled);
            }
            string recovered = await whisper.Transcribe(Path.Combine(root, "short-fictional.wav"), "en", [], CancellationToken.None);
            Check("recording recovers after worker cancellation", recovered == "Morgan checked the blue bicycle." && whisper.WorkerId != id);
            int? recoveredId = whisper.WorkerId;
            string again = await whisper.Transcribe(Path.Combine(root, "short-fictional.wav"), "en", [], CancellationToken.None);
            Check("recovered worker stays warm without transcript carryover", again == recovered && whisper.WorkerId == recoveredId && whisper.LastMetrics.Reused);
        } finally { Directory.Delete(directory, true); }
    }
    static string Words(string text) => string.Join(" ", System.Text.RegularExpressions.Regex.Matches(text.ToLowerInvariant(), @"[\p{L}\p{N}]+").Select(match => match.Value));
    static async Task WorkerSafety()
    {
        string directory = Path.Combine(root, "worker-fictional-测-🟣-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        string assets = PackageAssets;
        string model = Path.Combine(directory, "ggml-small.bin"), audio = Path.Combine(directory, "narración-🟣.wav");
        try {
            File.Copy(Path.Combine(assets, "models", "ggml-small.bin"), model); File.Copy(Path.Combine(root, "short-fictional.wav"), audio);
            await using (var whisper = new Whisper(directory, assets)) {
                await whisper.Prewarm();
                string result = await whisper.Transcribe(audio, "en", [], CancellationToken.None);
                Check("native worker reads Unicode model and audio paths", result == "Morgan checked the blue bicycle.");
                Check("Unicode path inference keeps short audio context", whisper.LastMetrics.AudioContext == 512);
            }
            using (var file = new FileStream(model, FileMode.Open, FileAccess.ReadWrite)) { file.Position = 2048; int value = file.ReadByte(); file.Position = 2048; file.WriteByte((byte)(value ^ 1)); }
            await using var rejected = new Whisper(directory, assets); bool blocked = false;
            try { await rejected.Prewarm(); } catch (InvalidDataException) { blocked = true; }
            Check("same-sized corrupt model cannot launch the resident worker", blocked && rejected.WorkerId == null);
        } finally { Directory.Delete(directory, true); }
    }
    static async Task ExtendedLatency()
    {
        string directory = Path.Combine(root, "extended-latency-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        string assets = PackageAssets;
        await using var whisper = new Whisper(directory, assets);
        try {
            await whisper.Prewarm();
            string audio = Path.Combine(root, "latency-extended.wav"), output = Path.Combine(directory, "baseline");
            var info = new ProcessStartInfo(Path.Combine(assets, "engine", "whisper-cli.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (string argument in new[] { "-m", whisper.ModelPath, "-f", audio, "-l", "en", "-otxt", "-of", output, "-np", "-bs", "1", "-bo", "1", "-t", "5" }) info.ArgumentList.Add(argument);
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(70));
            var clock = Stopwatch.StartNew(); using var process = Process.Start(info)!;
            using var kill = limit.Token.Register(() => { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } });
            var stdout = process.StandardOutput.BaseStream.CopyToAsync(Stream.Null); var stderr = process.StandardError.BaseStream.CopyToAsync(Stream.Null);
            await process.WaitForExitAsync(limit.Token); await Task.WhenAll(stdout, stderr); double baseline = clock.Elapsed.TotalMilliseconds;
            Check("extended baseline completes", process.ExitCode == 0);
            string expected = PFlow.Core.TextProcessing.JoinRecognitionLines((await File.ReadAllTextAsync(output + ".txt")).Trim());
            clock.Restart(); string result = await whisper.Transcribe(audio, "en", [], limit.Token); double elapsed = clock.Elapsed.TotalMilliseconds;
            Check("long narration retains full recognition window", whisper.LastMetrics.AudioContext == 0);
            Check("long narration keeps all original recognized words", Words(result) == Words(expected));
            Check("long narration retains its final sentence", result.Contains("went home", StringComparison.OrdinalIgnoreCase));
            Console.WriteLine($"Extended narration original={baseline:F0}ms warm={elapsed:F0}ms context=full");
            var store = new PFlow.Core.StateStore(directory); var timing = new Dictionary<string, double>();
            var pipeline = new DictationPipeline(store, whisper, new LocalTextModel(directory, assets)) { Timing = (name, ms) => timing[name] = ms };
            var prepared = await pipeline.Prepare(Path.Combine(root, "short-fictional.wav"), 2.6, directory, (_, _) => {}, CancellationToken.None);
            Check("production Prepare uses warm engine with exact text", prepared.Text == "Morgan checked the blue bicycle." && whisper.LastMetrics.Reused);
            Check("private stage timings measure recognition without transcript data", timing.Count == 1 && timing.TryGetValue("recognitionMs", out double ms) && ms > 0 && ms < 2000);
        } finally { Directory.Delete(directory, true); }
    }
    static async Task SpeechLatency()
    {
        string directory = Path.Combine(root, "speech-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        File.Copy(Path.Combine(root, "short-fictional.wav"), Path.Combine(directory, "speech.wav"));
        var store = new PFlow.Core.StateStore(directory);
        string assets = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "pFlow");
        var whisper = new Whisper(directory, assets); var model = new LocalTextModel(directory, assets);
        try {
            {
                var stages = new List<string?>(); var watch = Stopwatch.StartNew();
                var pipeline = new DictationPipeline(store, whisper, model);
                var prepared = await pipeline.Prepare(Path.Combine(directory, "speech.wav"), 2.6, directory, (_, detail) => stages.Add(detail), CancellationToken.None);
                Check("production processing keeps exact fictional sentence", prepared.Text == "Morgan checked the blue bicycle." && prepared.SpokenWords == 5);
                Check("ordinary processing stays below six seconds", watch.Elapsed < TimeSpan.FromSeconds(6));
                Check("the only processing stage is transcription", stages.All(x => x == "Transcribing"));
                Console.WriteLine($"Production speech processing elapsed {watch.Elapsed.TotalSeconds:F2}s");
            }
        } finally { Directory.Delete(directory, true); }
    }
    static async Task Processing()
    {
        string directory = Path.Combine(root, "processing-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        string name = "pflow-processing-" + Guid.NewGuid().ToString("N"), file = Path.Combine(directory, name + ".txt");
        File.WriteAllText(file, "Fictional prefix. ");
        var start = new ProcessStartInfo("notepad.exe") { UseShellExecute = true }; start.ArgumentList.Add(file); Process.Start(start);
        var notepad = await WindowWith(name); var edit = await Editor(notepad); await Focus(notepad, edit); End(edit);
        using var owner = new HwndSource(new HwndSourceParameters("pFlow fictional processing owner") { Width = 10, Height = 10 });
        var store = new PFlow.Core.StateStore(directory); store.Preferences.Language = "en"; store.Preferences.CopyDictationToClipboard = false;
        string assets = insertionLatencyOnly ? PackageAssets : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "pFlow");
        await using var whisper = new Whisper(directory, assets); var model = new LocalTextModel(directory, assets);
        File.Copy(Path.Combine(root, "short-fictional.wav"), Path.Combine(directory, "speech.wav"));
        try {
            if (insertionLatencyOnly) await whisper.Prewarm();
            {
                await Focus(notepad, edit); End(edit); var target = InsertionTarget.Capture(); string before = Read(edit);
                uint clipboard = Native.GetClipboardSequenceNumber(); var stages = new List<PFlow.Core.Phase>(); var details = new List<string?>();
                var timing = new Dictionary<string, double>();
                var pipeline = new DictationPipeline(store, whisper, model) { Timing = (name, ms) => timing[name] = ms };
                var watch = Stopwatch.StartNew();
                var result = await pipeline.Run(Path.Combine(directory, "speech.wav"), 2.6, target, directory, owner.Handle, (phase, detail) => { stages.Add(phase); details.Add(detail); }, CancellationToken.None);
                if (insertionLatencyOnly) { Console.WriteLine($"TOTAL_PIPELINE_MS={watch.Elapsed.TotalMilliseconds:F0}"); foreach (var stage in timing) Console.WriteLine($"STAGE {stage.Key}={stage.Value:F0}"); }
                Check("production pipeline inserts in Notepad", result.Status == "Inserted" && Normalize(Read(edit)) == Normalize(before + "Morgan checked the blue bicycle."));
                Check("pipeline persists fictional History", new PFlow.Core.StateStore(directory).History.Count == 1 && new PFlow.Core.StateStore(directory).History[0].InsertionStatus == "Inserted");
                Check("pipeline preserves clipboard", Native.GetClipboardSequenceNumber() == clipboard);
                Check("pipeline reaches insertion state", stages.Contains(PFlow.Core.Phase.Processing) && stages.Contains(PFlow.Core.Phase.Inserting) && stages.Last() == PFlow.Core.Phase.Inserted);
                Check("short pipeline has bounded completion", watch.Elapsed < TimeSpan.FromSeconds(6));
                Check("the only processing detail is transcription", details.Where(x => x != null).All(x => x == "Transcribing"));
                Console.WriteLine($"Fictional pipeline elapsed {watch.Elapsed.TotalSeconds:F1}s");
            }
        } finally { Directory.Delete(directory, true); }
    }
    static async Task SecureField()
    {
        var password = new System.Windows.Controls.PasswordBox { Name = "FictionalPassword", Width = 200, Margin = new Thickness(20) };
        var window = new Window { Title = "pFlow fictional password fixture", Content = password, Width = 320, Height = 150 };
        try {
            window.Show(); await Task.Delay(300);
            var rootElement = AutomationElement.FromHandle(new WindowInteropHelper(window).Handle);
            var secure = rootElement.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.IsPasswordProperty, true));
            Check("native password fixture exposes IsPassword", secure != null);
            await Focus(rootElement, secure!);
            bool refused = false;
            try { InsertionTarget.Capture(); }
            catch (InvalidOperationException error) { refused = error.Message == "Dictation is off in password fields."; }
            Check("production capture refuses specifically because field is password", refused);
            Check("password fixture was not altered", password.Password.Length == 0);
        } finally { window.Close(); }
    }
    static async Task Microphone()
    {
        string directory = Path.Combine(root, "microphone-fictional-" + Guid.NewGuid()); Directory.CreateDirectory(directory);
        try {
            Check("Windows microphone device exists", WaveRecorder.waveInGetNumDevs() > 0);
            string path = Path.Combine(directory, "capture.wav");
            using var capture = new WaveRecorder(path); double maximum = 0;
            for (int i = 0; i < 30; i++) { await Task.Delay(100); maximum = Math.Max(maximum, capture.Level); }
            double seconds = capture.Stop();
            Check("microphone captured PCM frames", seconds >= 2.5 && new FileInfo(path).Length > 80000);
            using (var stream = File.OpenRead(path)) using (var reader = new BinaryReader(stream)) {
                Check("capture produced a WAV file", new string(reader.ReadChars(4)) == "RIFF");
            }
            Console.WriteLine($"Microphone seconds={seconds:F2}; waveform peak={maximum:F4}. Physical speech accuracy remains a user test.");
            using (var canceled = new WaveRecorder(Path.Combine(directory, "canceled.wav"))) { await Task.Delay(200); }
            Check("microphone reopened and canceled", true);
        } finally { Directory.Delete(directory, true); }
    }
}
