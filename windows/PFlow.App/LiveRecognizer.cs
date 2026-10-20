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
    readonly CancellationTokenSource stopping = new();
    readonly TimeSpan tick;
    Task? loop;
    internal LiveSession Session => session;
    internal string SessionName => session.Session.ToString();

    internal LiveRecognizer(uint take, Whisper whisper, string language, Action<TranscriptUpdate> onUpdate, Action onFailure, TimeSpan? tick = null)
    {
        session = new LiveSession(take, clock: () => Environment.TickCount64); this.whisper = whisper; this.language = language;
        this.onUpdate = onUpdate; this.onFailure = onFailure; this.tick = tick ?? TimeSpan.FromMilliseconds(250);
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
                try { segments = await whisper.RecognizeLive(request, language, stopping.Token); }
                catch (Exception) when (!stopping.IsCancellationRequested) { session.Fail(); onFailure(); return; }
                if (segments == null) { session.Abandon(request); continue; }
                if (session.Complete(request, segments) is { } update) onUpdate(update);
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
