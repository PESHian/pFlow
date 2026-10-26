namespace PFlow.Windows;

/// Live Whisper for one take. The recorder thread copies audio into a bounded
/// ring; a background loop sends at most one window at a time to the resident
/// worker. Nothing here runs on the audio callback or the UI thread, and after
/// `Stop` nothing more is delivered.
internal sealed class LiveRecognizer
{
    readonly LiveSession session;
    readonly Whisper whisper;
    readonly string language;
    readonly Action<TranscriptUpdate> onUpdate;
    readonly Action onFailure;
    readonly Action? onTooSlow;
    readonly TimeSpan windowLimit;
    readonly CancellationTokenSource stopping = new();
    readonly TimeSpan tick;
    Task? loop;
    internal LiveSession Session => session;
    internal string SessionName => session.Session.ToString();

    /// `onTooSlow` runs once when two windows in a row were slower than real time: live
    /// words end for the take, the words shown stay, the final pass runs as usual.
    /// `windowLimit` (default LiveSession.WindowLimitMs) cancels a window that runs too long; it then counts as slow.
    internal LiveRecognizer(uint take, Whisper whisper, string language, Action<TranscriptUpdate> onUpdate, Action onFailure, TimeSpan? tick = null,
        Action? onTooSlow = null, TimeSpan? windowLimit = null)
    {
        session = new LiveSession(take, clock: () => Environment.TickCount64); this.whisper = whisper; this.language = language;
        this.onUpdate = onUpdate; this.onFailure = onFailure; this.tick = tick ?? TimeSpan.FromMilliseconds(250);
        this.onTooSlow = onTooSlow; this.windowLimit = windowLimit ?? TimeSpan.FromMilliseconds(LiveSession.WindowLimitMs);
    }

    /// 16-bit PCM from the recorder's writer thread (never the audio callback).
    internal void Append(byte[] pcm) => session.Append(MemoryMarshal.Cast<byte, short>(pcm.AsSpan(0, pcm.Length & ~1)));

    internal void Start() => loop = Task.Run(Run);

    async Task Run()
    {
        try {
            while (!stopping.IsCancellationRequested) {
                await Task.Delay(tick, stopping.Token);
                if (session.Next() is not { } request) continue;
                IReadOnlyList<WhisperWindowSegment>? segments;
                // A window that outlives the limit is canceled (the worker keeps its warm model) and counts as slow.
                using var window = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token);
                long asked = Environment.TickCount64, began = -1; double cpu = WorkerCpuMs();
                try { segments = await whisper.RecognizeLive(request, language, window.Token, started: () => { began = Environment.TickCount64; session.Begin(request); window.CancelAfter(windowLimit); }); }
                catch (Exception error) when (!stopping.IsCancellationRequested) {
                    Diagnostics.Recorder.Event("live.failed", new DiagField("window", request.Sequence), new DiagField("reason", PrivateLog.Reason(error)));
                    session.Fail(); onFailure(); return;
                }
                TranscriptUpdate? update = null;
                if (segments == null) session.Abandon(request);
                else update = session.Complete(request, segments);
                double after = WorkerCpuMs();
                Record(request, segments, update, asked, began, cpu >= 0 && after >= 0 ? after - cpu : -1);
                if (update != null) onUpdate(update);
                if (session.TooSlow) {
                    Diagnostics.Recorder.Event("live.tooSlow", new DiagField("afterWindows", session.Inferences), new DiagField("slowInARow", LiveSession.SlowWindowsBeforeStop),
                        new DiagField("floorMs", LiveSession.SlowWindowFloorMs), new DiagField("windowLimitMs", (long)windowLimit.TotalMilliseconds));
                    onTooSlow?.Invoke(); return;
                }
            }
        } catch (OperationCanceledException) { }
        catch (Exception) { session.Fail(); }
    }

    /// One line per live window for the diagnostic report: how long it waited for the worker and took,
    /// the speed rule's verdict, and how many words it gave (never the words).
    void Record(LiveWindowRequest request, IReadOnlyList<WhisperWindowSegment>? segments, TranscriptUpdate? update, long asked, long began, double cpuMs)
    {
        var verdict = session.LastVerdict;
        long now = Environment.TickCount64;
        Diagnostics.Recorder.Detail("live.window", new DiagField("seq", request.Sequence), new DiagField("audioMs", (request.EndSample - request.StartSample) / LiveWindowPlanner.SamplesPerMs),
            new DiagField("waitMs", began < 0 ? now - asked : began - asked), new DiagField("tookMs", began < 0 ? -1 : now - began),
            new DiagField("limitMs", verdict?.LimitMs ?? -1), new DiagField("slow", verdict?.Slow ?? false), new DiagField("slowInARow", verdict?.SlowRun ?? 0),
            new DiagField("result", segments == null ? "canceled" : update == null ? "no change" : "update"), new DiagField("segments", segments?.Count ?? 0),
            new DiagField("words", DiagnosticRecorder.Words(update?.Text ?? "")), new DiagField("liveModel", whisper.LiveModelReady),
            // Processor time the worker used for the window: with tookMs it shows how many cores it really got.
            new DiagField("workerCpuMs", cpuMs >= 0 ? cpuMs : -1));
    }
    Process? worker;
    /// The speech worker's processor time so far, or -1 when it cannot be read.
    double WorkerCpuMs()
    {
        try {
            if (whisper.WorkerId is not int id) return -1;
            if (worker == null || worker.Id != id) { worker?.Dispose(); worker = Process.GetProcessById(id); }
            worker.Refresh(); return worker.TotalProcessorTime.TotalMilliseconds;
        } catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return -1; }
    }

    /// Ends live recognition and returns the words shown so far. A window still
    /// running is canceled and its reply drained before this returns, so the
    /// final whole-recording pass never waits behind live work. If the worker
    /// does not answer in time it is ended; the final pass then starts a new one.
    internal async Task<string> Stop(TimeSpan? limit = null)
    {
        string text = session.Close();
        stopping.Cancel();
        Diagnostics.Recorder.Event("live.stop", new DiagField("windows", session.Inferences), new DiagField("silentSkipped", session.SilentWindows),
            new DiagField("tooSlow", session.TooSlow), new DiagField("failed", session.Failed), new DiagField("words", DiagnosticRecorder.Words(text)));
        if (loop != null && await Task.WhenAny(loop, Task.Delay(limit ?? TimeSpan.FromSeconds(3))) != loop) {
            whisper.EndWorker();
            await loop;
        }
        worker?.Dispose(); worker = null;
        return text;
    }
}
