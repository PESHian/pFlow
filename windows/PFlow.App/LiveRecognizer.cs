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
                using var window = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token); window.CancelAfter(windowLimit);
                try { segments = await whisper.RecognizeLive(request, language, window.Token); }
                catch (Exception) when (!stopping.IsCancellationRequested) { session.Fail(); onFailure(); return; }
                if (segments == null) session.Abandon(request);
                else if (session.Complete(request, segments) is { } update) onUpdate(update);
                if (session.TooSlow) { onTooSlow?.Invoke(); return; }
            }
        } catch (OperationCanceledException) { }
        catch (Exception) { session.Fail(); }
    }

    /// Ends live recognition and returns the words shown so far. A window still
    /// running is canceled and its reply drained before this returns, so the
    /// final whole-recording pass never waits behind live work. If the worker
    /// does not answer in time it is ended; the final pass then starts a new one.
    internal async Task<string> Stop(TimeSpan? limit = null)
    {
        string text = session.Close();
        stopping.Cancel();
        if (loop != null && await Task.WhenAny(loop, Task.Delay(limit ?? TimeSpan.FromSeconds(3))) != loop) {
            whisper.EndWorker();
            await loop;
        }
        return text;
    }
}
