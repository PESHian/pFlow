using System.Windows.Interop;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace PFlow.Windows;

internal sealed partial class Program : Application
{
    StateStore store = null!;
    Whisper whisper = null!;
    LocalTextModel textModel = null!;
    Capsule capsule = null!;
    LivePreview preview = null!;
    // The "couldn't type this" card and the start notice share one card.
    PromptCard prompt = null!;
    // Live text for the current take only; the setting is read once when a take starts.
    LiveRecognizer? live;
    readonly LiveTranscriptReconciler transcript = new();
    // "Type in the current app": at most one take types at a time, and only while it records.
    readonly LiveInlineSlot typing = new();
    string? typingSession;
    // This take shows the text card; Type mode keeps only the recording control while typing works.
    bool card;
    KeyboardHook keyboard = null!;
    Forms.NotifyIcon tray = null!;
    System.Drawing.Icon? trayIcon;
    SettingsWindow? settings;
    WaveRecorder? recorder;
    InsertionTarget? target;
    CancellationTokenSource? session, stopDelay;
    string? sessionDirectory;
    Phase phase = Phase.Idle;
    bool quitting;
    readonly OperationGate operations = new();
    long sessionId;
    readonly Mutex single = new(true, "Local\\pFlow-by-Pesh-Windows", out _);
    [STAThread] public static int Main(string[] args)
    {
        if (InstalledCopies.RunsFromPackage(Environment.ProcessPath ?? "")) { MessageBox.Show("Install pFlow first: double-click pFlow Setup.", "pFlow by Pesh"); return 0; }
        if (args.Contains(UninstallEntry.UninstallSwitch)) return Uninstaller.Run(args.Contains("--quiet"));
        var app = new Program();
        // An older copy left by an install elsewhere gives way; a copy of this version or newer stays,
        // and opening pFlow again (desktop or Start shortcut) opens that copy's Settings.
        if (!app.single.WaitOne(0) && !StaleCopies.TakeOverFromOlderCopy(app.single)) { StaleCopies.AskRunningCopyToOpenSettings(); return 0; }
        app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        app.DispatcherUnhandledException += (_, e) => { e.Handled = true; app.Failure(e.Exception); };
        app.Startup += (_, _) => app.Start(args);
        return app.Run();
    }
    void Start(string[] args)
    {
        try {
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "pFlow");
            StaleCopies.RepointRunKey(); StaleCopies.ListenForNewerCopy(() => Dispatcher.InvokeAsync(Quit));
            StaleCopies.ListenForOpenSettings(() => Dispatcher.InvokeAsync(OpenSettings)); StaleCopies.ListenForUninstall(() => Dispatcher.InvokeAsync(QuitForUninstall));
            _ = Task.Run(Uninstaller.Register);
            store = new StateStore(directory); whisper = new Whisper(directory) { ChosenId = () => store.Preferences.SpeechModel };
            InsertionLog.Path = Path.Combine(directory, "insertion.log");
            textModel = new LocalTextModel(directory);
            _ = Task.Run(async () => { try { await whisper.Prewarm(); } catch { /* Recording retries and reports a load error when needed. */ } });
            try { whisper.SweepPartials(); textModel.SweepPartials(); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            _ = Task.Run(async () => { try { await textModel.Prewarm(); } catch { /* The next take verifies the file and reports it. */ } });
            // Only our abandoned private recording folders are removed. History/settings remain.
            foreach (var stale in Directory.EnumerateDirectories(directory, "recording-*")) Directory.Delete(stale, true);
            capsule = new Capsule(store); capsule.OpenSettings += OpenSettings; capsule.Cancel += Cancel; capsule.ToggleRecording += ToggleRecording; capsule.OpenHistory += OpenHistory;
            capsule.AudioLevel = () => recorder?.Level ?? 0;
            preview = new LivePreview(store);
            prompt = new PromptCard(store); prompt.SecondaryPressed += OpenSettings;
            foreach (var floating in new Window[] { capsule, preview, prompt }) floating.SourceInitialized += (sender, _) => InsertionTarget.RefusedWindows.Add(new System.Windows.Interop.WindowInteropHelper((Window)sender!).Handle);
            _ = new DispatcherTimer(TimeSpan.FromMilliseconds(200), DispatcherPriority.Background, (_, _) => ClipboardLease.RestorePending(), Dispatcher);
            keyboard = new KeyboardHook(OnTrigger, store.Preferences.ActivationKey) { Enabled = store.Preferences.Enabled };
            var menu = new Forms.ContextMenuStrip();
            menu.Items.Add(TrayMenu.ShowControl, null, (_, _) => Dispatcher.Invoke(capsule.Reveal));
            menu.Items.Add(TrayMenu.Settings, null, (_, _) => Dispatcher.Invoke(OpenSettings));
            menu.Items.Add(TrayMenu.Updates, null, (_, _) => Dispatcher.Invoke(OpenUpdates));
            menu.Items.Add(TrayMenu.History, null, (_, _) => Dispatcher.Invoke(OpenHistory));
            var enabled = new Forms.ToolStripMenuItem(TrayMenu.Enabled) { Checked = store.Preferences.Enabled, CheckOnClick = true };
            enabled.CheckedChanged += (_, _) => { store.Preferences.Enabled = keyboard.Enabled = enabled.Checked; store.SavePreferences(); if (!enabled.Checked) Cancel(); };
            menu.Items.Add(enabled); menu.Items.Add(TrayMenu.Cancel, null, (_, _) => Dispatcher.Invoke(Cancel));
            menu.Items.Add(TrayMenu.Quit, null, (_, _) => Dispatcher.Invoke(Quit));
            trayIcon = TrayIcon.Current();
            tray = new Forms.NotifyIcon { Icon = trayIcon, Text = "pFlow by Pesh", Visible = true, ContextMenuStrip = menu };
            // The frame follows the taskbar: a DPI or theme change picks the icon again.
            Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.BeginInvoke(RefreshTrayIcon);
            Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.BeginInvoke(RefreshTrayIcon);
            tray.DoubleClick += (_, _) => Dispatcher.Invoke(OpenSettings);
            if (args.Contains("--settings")) OpenSettings();
            // Once per start: where pFlow is and how to dictate. Goes away on its own.
            prompt.ShowNotice(StartNotice.Body(KeyLabels.Name(ActivationKeys.Resolve(store.Preferences.ActivationKey))), StartNotice.Settings, TimeSpan.FromSeconds(12));
        } catch (Exception error) { MessageBox.Show(error.Message, "pFlow could not start"); Quit(); }
    }
    void RefreshTrayIcon()
    {
        if (tray == null || quitting) return;
        var fresh = TrayIcon.Current(); var old = trayIcon;
        tray.Icon = trayIcon = fresh; old?.Dispose();
    }
    void ToggleRecording()
    {
        if (!store.Preferences.Enabled) { Notify("Turn on Dictation enabled in the tray menu first."); return; }
        if (recorder != null) OnTrigger(TriggerAction.Stop);
        else if (!operations.Busy) OnTrigger(TriggerAction.Continuous);
    }
    void Set(Phase value, string? detail = null)
    {
        phase = value; capsule?.Set(value, detail);
        if (preview == null) return;
        if (live != null && card && value is Phase.Recording or Phase.Continuous or Phase.Processing or Phase.Inserting) {
            if (value == Phase.Processing) preview.Finishing();
            preview.Reveal(capsule!.Handle);
        } else preview.Clear();
    }
    void ShowLive(LiveRecognizer owner, TranscriptUpdate update)
    {
        // Updates from an earlier take, or after this one ended, are ignored.
        if (!ReferenceEquals(live, owner)) return;
        long? accepted = transcript.LastSequence;
        bool changed = transcript.Apply(update);
        if (transcript.LastSequence == accepted) return;
        if (changed) preview.ShowText(transcript.Text);
        // A repeat of the same words still goes to typing: it is how the last words settle.
        if (typingSession == owner.SessionName && recorder != null && typing.Reconcile(typingSession, transcript.Text) is LiveStop stop)
            ShowCard(LiveInlineText.StoppedNote(stop));
    }
    /// Typing in the app ended for this take. The note is kept for the take's
    /// status; the recording control stays, and the finished words go in at the end.
    void ShowCard(string note) => preview.SetNote(note);
    /// The words typed live for this take, as the pipeline finishes it.
    LiveTyping? TypingFor(string? session) => session == null ? null
        : new LiveTyping(text => typing.Finalize(session, text), () => typing.Typed(session), () => typing.Cancel(session));
    void LiveStopped(LiveRecognizer owner) { if (ReferenceEquals(live, owner)) ShowCard("Live words stopped"); }
    void LiveTooSlow(LiveRecognizer owner) { if (ReferenceEquals(live, owner)) ShowCard(LiveTake.TooSlowNote); }
    void EndLive()
    {
        var ending = live; live = null; transcript.Cancel(); preview.Clear();
        if (ending != null) _ = ending.Stop();
    }
    void Cue(bool start)
    {
        if (!store.Preferences.Sounds) return;
        // Quiet generated PCM cues; no system notification sound or network dependency.
        using var memory = new MemoryStream(); using (var writer = new BinaryWriter(memory, System.Text.Encoding.ASCII, true)) {
            const int rate = 16000, count = 1120;
            writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + count * 2); writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
            writer.Write(16); writer.Write((short)1); writer.Write((short)1); writer.Write(rate); writer.Write(rate * 2); writer.Write((short)2); writer.Write((short)16);
            writer.Write(System.Text.Encoding.ASCII.GetBytes("data")); writer.Write(count * 2);
            for (int i = 0; i < count; i++) writer.Write((short)(Math.Sin(2 * Math.PI * (start ? 660 : 440) * i / rate) * 1000 * Math.Sin(Math.PI * i / count)));
        }
        memory.Position = 0; using var player = new System.Media.SoundPlayer(memory); player.PlaySync();
    }
    void OnTrigger(TriggerAction action)
    {
        if (quitting || updateApplying || keyboard.Capturing) return;
        if (action == TriggerAction.Cancel) { Cancel(); return; }
        if (action is TriggerAction.Start or TriggerAction.Continuous) {
            stopDelay?.Cancel();
            if (recorder != null) { Set(action == TriggerAction.Continuous ? Phase.Continuous : Phase.Recording); return; }
            if (operations.Busy) { keyboard.Reset(); return; }
            try {
                if (!whisper.FilesPresent) throw new InvalidOperationException("Install the Whisper model in Settings first. The complete Windows package must include its engine.");
                // Captured first: hiding the card could activate another window, which must never become the target.
                target = InsertionTarget.Capture();
                prompt.Dismiss();
                InsertionLog.Record("take: app=" + target.ApplicationName + " field=" + target.Kind + (target.CanInsert ? " insertable" : " not insertable: " + target.Refusal) + " live=" + LiveTextModes.Resolve(store.Preferences.LiveTextMode) + " copy=" + store.Preferences.CopyDictationToClipboard);
                sessionId = operations.Start();
                session = new CancellationTokenSource(TimeSpan.FromHours(2));
                sessionDirectory = Path.Combine(store.DirectoryPath, "recording-" + Guid.NewGuid()); Directory.CreateDirectory(sessionDirectory);
                Cue(true);
                string mode = LiveTextModes.Resolve(store.Preferences.LiveTextMode);
                typing.Abandon(); typingSession = null; card = false;
                if (LiveTextModes.ShowsPreview(mode)) {
                    LiveRecognizer recognizer = null!;
                    recognizer = new LiveRecognizer(unchecked((uint)sessionId), whisper, store.Preferences.Language,
                        update => Dispatcher.InvokeAsync(() => ShowLive(recognizer, update)), () => Dispatcher.InvokeAsync(() => LiveStopped(recognizer)),
                        onTooSlow: () => Dispatcher.InvokeAsync(() => LiveTooSlow(recognizer)));
                    live = recognizer; transcript.Begin(recognizer.SessionName); preview.Begin();
                    if (mode == LiveTextModes.TypeInApp) {
                        // Checked against the field just captured, before any pFlow window shows.
                        var refused = typing.Begin(recognizer.SessionName, target.LiveField());
                        if (refused == null) typingSession = recognizer.SessionName;
                        preview.SetNote(refused is LiveStop stop ? LiveInlineText.PreviewNote(stop) : target.TypingNote);
                    }
                    card = LiveTextModes.ShowsCard(mode, typingSession != null);
                }
                recorder = new WaveRecorder(Path.Combine(sessionDirectory, "audio.wav"), live == null ? null : live.Append);
                live?.Start();
                if (target.Placeholder) _ = CaptureAgainSoon(sessionId);
                Set(action == TriggerAction.Continuous ? Phase.Continuous : Phase.Recording);
            } catch (Exception error) {
                Cancel();
                if (operations.Complete(sessionId)) {
                    session?.Dispose(); session = null; sessionId = 0;
                    if (sessionDirectory != null && Directory.Exists(sessionDirectory)) Directory.Delete(sessionDirectory, true);
                    sessionDirectory = null;
                }
                Failure(error);
            }
        } else if (action == TriggerAction.Stop && recorder != null) DelayedFinish();
    }
    async void DelayedFinish()
    {
        stopDelay?.Cancel(); var delay = stopDelay = new CancellationTokenSource();
        var elapsed = Stopwatch.StartNew();
        try { await Task.Delay(310, delay.Token); await Finish(elapsed); }
        catch (OperationCanceledException) { }
        catch (Exception error) { Failure(error); }
    }
    async Task Finish(Stopwatch elapsed)
    {
        if (recorder == null || target == null || session == null) return;
        var active = recorder; recorder = null; var originalTarget = target; var cancellation = session; string folder = sessionDirectory!; long owner = sessionId;
        var takeLive = live; string? liveWords = null; string? takeTyping = typingSession;
        double seconds = 0; bool processing = false;
        var timing = new Dictionary<string, double> { ["releaseDelayMs"] = elapsed.Elapsed.TotalMilliseconds };
        try {
            var stop = Stopwatch.StartNew(); string path = active.Path; seconds = active.Stop(); timing["microphoneStopMs"] = stop.Elapsed.TotalMilliseconds;
            if (takeLive != null) {
                // Live windows end before the final pass, so it never waits behind them.
                stop.Restart(); liveWords = await takeLive.Stop(); timing["liveStopMs"] = stop.Elapsed.TotalMilliseconds;
                timing["liveWindows"] = takeLive.Session.Inferences;
            }
            if (seconds < 0.3) { CancelTyping(takeTyping); Set(Phase.Canceled); return; }
            Cue(false);
            processing = true; var pipeline = new DictationPipeline(store, whisper, textModel) { Timing = (name, ms) => timing[name] = ms };
            var result = await pipeline.Run(path, seconds, originalTarget, folder, capsule.Handle, Set, cancellation.Token, liveWords, TypingFor(takeTyping));
            InsertionLog.Record("take done: " + seconds.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " s, status=" + result.Status);
            // Words that did not go in are shown in the card to copy; the card says why, so no balloon then.
            if (result.Prompt is { } offer) prompt.ShowWords(offer.Text, offer.Reason, capsule.Handle);
            else if (result.Notice != null) Notify(result.Notice);
        } catch (OperationCanceledException) { InsertionLog.Record("take canceled"); Set(Phase.Canceled); }
        catch (Exception error) { InsertionLog.Record("take failed: " + InsertionLog.Reason(error)); Failure(error); }
        finally {
            // Whatever happened, this take never writes again; typed words stay where they are.
            if (takeTyping != null && typingSession == takeTyping) { typing.Abandon(); typingSession = null; }
            if (ReferenceEquals(live, takeLive)) EndLive();
            active.Dispose(); cancellation.Dispose(); if (ReferenceEquals(session, cancellation)) session = null;
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
            if (operations.Complete(owner)) { sessionDirectory = null; sessionId = 0; keyboard.Reset(); }
            timing["totalAfterReleaseMs"] = elapsed.Elapsed.TotalMilliseconds; timing["recordingSeconds"] = seconds;
            if (processing) {
                var speech = whisper.LastMetrics;
                timing["warmModelReused"] = speech.Reused ? 1 : 0; timing["modelInitializationMs"] = speech.InitializationMs;
                timing["nativeRecognitionMs"] = speech.RecognitionMs; timing["audioContextFrames"] = speech.AudioContext;
                // The worker sends 0 for stages whisper.cpp does not report for its finished-text state.
                if (speech.EncodeMs > 0) timing["encoderMs"] = speech.EncodeMs;
                if (speech.DecodeMs > 0) timing["decoderMs"] = speech.DecodeMs;
            }
            // One private, overwritten timing record. No words, audio, paths, or application names.
            try { store.Write("last-processing-times.json", timing); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
    /// Chromium answered the take's first capture with its placeholder pane and was
    /// knocked for its tree. A moment later, during the take and still in the same
    /// window, the field may be readable: then it is this take's target and the
    /// finished text goes in the normal checked way. Otherwise the pane stays and the
    /// insert looks once more, then types without a check. Never a different window.
    async Task CaptureAgainSoon(long owner)
    {
        foreach (int wait in new[] { 300, 700, 1500, 3000 }) {
            await Task.Delay(wait);
            if (sessionId != owner || recorder == null || target is not { Placeholder: true } first) return;
            InsertionTarget again;
            try { again = InsertionTarget.Capture(); }
            catch (InvalidOperationException error) { InsertionLog.Record("take: capture again refused: " + InsertionLog.Reason(error)); return; }
            if (!first.SameWindow(again)) { InsertionLog.Record("take: focus left the window; placeholder kept"); return; }
            if (again.CanInsert && !again.Placeholder) { target = again; InsertionLog.Record("take: field readable after " + wait + " ms: " + again.Kind); return; }
            InsertionLog.Record("take: still the placeholder after " + wait + " ms");
        }
    }
    /// Takes this take's typed words back out, only while the field is exactly
    /// as pFlow left it; otherwise they stay and the person is told.
    void CancelTyping(string? session)
    {
        if (session == null || typingSession != session) return;
        typingSession = null;
        if (typing.Cancel(session).Result == LiveCancel.Left) Notify(LiveInlineText.Left);
    }
    void Cancel()
    {
        stopDelay?.Cancel(); session?.Cancel(); CancelTyping(typingSession);
        if (recorder != null) {
            recorder.Dispose(); recorder = null;
            if (sessionDirectory != null && Directory.Exists(sessionDirectory)) Directory.Delete(sessionDirectory, true);
            sessionDirectory = null; session?.Dispose(); session = null;
            operations.Complete(sessionId); sessionId = 0;
        }
        EndLive(); keyboard?.Reset(); if (phase != Phase.Inserting) Set(Phase.Canceled);
    }
    void Failure(Exception error) { Set(Phase.Failed, error.Message); Notify(error.Message); }
    void Notify(string text) { if (tray != null) { tray.BalloonTipTitle = "pFlow by Pesh"; tray.BalloonTipText = text; tray.ShowBalloonTip(6000); } }
    void OpenSettings()
    {
        if (settings != null) { settings.Activate(); return; }
        settings = new SettingsWindow(store, whisper, textModel, keyboard, () => { capsule.ApplyTheme(); preview.ApplyTheme(); prompt.ApplyTheme(); }, () => operations.Busy || updateApplying, OpenUpdates);
        settings.Closed += (_, _) => settings = null; settings.Show();
    }
    void OpenHistory() { OpenSettings(); settings?.OpenHistoryPage(); }
    /// The uninstaller asked: quit as soon as no take (recording, recognizing, inserting) and no clipboard
    /// restore is under way, so a take in progress still reaches the app and History (the uninstaller waits
    /// up to 90 s and never ends pFlow by force).
    async void QuitForUninstall()
    {
        for (int i = 0; i < 170 && (recorder != null || operations.Busy || phase == Phase.Inserting || ClipboardLease.Pending.Count > 0); i++) await Task.Delay(500);
        Quit();
    }
    async void Quit()
    {
        if (phase == Phase.Inserting || ClipboardLease.Pending.Count > 0) { Notify("pFlow is restoring your clipboard. Quit when insertion ends."); return; }
        quitting = true; Cancel();
        while (operations.Busy) await Task.Delay(25);
        await whisper.DisposeAsync(); keyboard?.Dispose(); tray?.Dispose(); prompt?.Close(); capsule?.Close(); Shutdown();
    }
    protected override void OnExit(ExitEventArgs e) { whisper?.Abort(); keyboard?.Dispose(); tray?.Dispose(); trayIcon?.Dispose(); single.Dispose(); base.OnExit(e); }
}
