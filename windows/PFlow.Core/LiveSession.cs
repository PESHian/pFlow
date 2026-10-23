namespace PFlow.Core;

/// Which audio the next live window covers, in 16 kHz samples. Windows start
/// where the kept words end and never exceed `MaximumMs`, so a long take is
/// never decoded again from the beginning. Same rules as the Mac planner.
public sealed record LiveWindowPlanner(int MaximumMs = 15_000, int StrideMs = 1_000, int MinimumMs = 1_000)
{
    public const int SamplesPerMs = 16;

    /// null until `StrideMs` of new audio arrived after `lastEndSample`.
    public (long Start, long End)? Next(long totalSamples, int committedEndMs, long lastEndSample)
    {
        if (totalSamples - lastEndSample < (long)StrideMs * SamplesPerMs) return null;
        long start = Math.Max(Math.Max((long)committedEndMs * SamplesPerMs, totalSamples - (long)MaximumMs * SamplesPerMs), 0);
        if (totalSamples - start < (long)MinimumMs * SamplesPerMs) return null;
        return (start, totalSamples);
    }
}

/// Skips inference on audio with no speech in it, which is also where Whisper
/// invents words: speech needs five 30 ms frames louder than RMS 0.01.
public static class LiveAudioGate
{
    public const int Frame = 480, FramesNeeded = 5;
    public const float Threshold = 0.01f;

    public static bool HasSpeech(ReadOnlySpan<float> samples)
    {
        int loud = 0;
        for (int start = 0; start < samples.Length; start += Frame) {
            var frame = samples.Slice(start, Math.Min(Frame, samples.Length - start));
            float sum = 0;
            foreach (float value in frame) sum += value * value;
            if (MathF.Sqrt(sum / frame.Length) > Threshold) loud++;
            if (loud >= FramesNeeded) return true;
        }
        return false;
    }
}

/// The last few seconds of a take, fixed size, so memory never grows with
/// the length of a recording.
public sealed class LiveAudioRing(int seconds)
{
    readonly float[] storage = new float[seconds * 16_000];
    public int Capacity => storage.Length;
    /// Samples written since the take began.
    public long Total { get; private set; }
    public long Oldest => Math.Max(0, Total - storage.Length);

    public void Append(ReadOnlySpan<short> pcm)
    {
        // Audio older than the ring holds is counted, never stored.
        int skip = Math.Max(0, pcm.Length - storage.Length);
        Total += skip;
        foreach (short sample in pcm[skip..]) { storage[Total % storage.Length] = sample / 32768f; Total++; }
    }

    /// A copy of the held part of [from, to).
    public float[] Snapshot(long from, long to)
    {
        long lower = Math.Max(from, Oldest), upper = Math.Min(to, Total);
        if (lower >= upper) return [];
        var copy = new float[upper - lower];
        for (long index = lower; index < upper; index++) copy[index - lower] = storage[index % storage.Length];
        return copy;
    }
}

/// One live window to recognize. `Samples` is an immutable copy taken from the
/// ring; the recorder never waits for it.
public sealed record LiveWindowRequest(uint Session, uint Sequence, long StartSample, long EndSample, float[] Samples)
{
    public WhisperWindow Window(IReadOnlyList<WhisperWindowSegment> segments) =>
        new((int)(StartSample / LiveWindowPlanner.SamplesPerMs), (int)(EndSample / LiveWindowPlanner.SamplesPerMs), segments);
}

/// Live Whisper bookkeeping for one take, without any engine or UI. Audio goes
/// into a bounded ring from the recorder thread; `Next` hands out at most one
/// window at a time, always over the newest audio, so pending work never queues.
/// Results for another take, an older window, or a closed take are dropped.
/// `clock` is milliseconds from any fixed start. Without one there is no rest
/// between windows, which replays of recorded windows rely on.
public sealed class LiveSession(uint session, LiveWindowPlanner? planner = null, int ringSeconds = 20, Func<long>? clock = null)
{
    /// After each window, live recognition rests as long as that window took,
    /// so it keeps the processor busy at most half the time. A window that
    /// finishes well inside the 1 s stride is never delayed by this. Measured on
    /// the 6-core ARM64 test VM with fixed recordings: back-to-back windows kept
    /// 3.0-3.5 cores busy; resting cut that to 2.0-2.2, first words unchanged
    /// at about 1.7 s, updates every 1.5-1.8 s instead of about 1.1 s.
    public const double RestRatio = 1.0;
    /// A window that takes longer than the audio it covers (and longer than
    /// `SlowWindowFloorMs`) means this computer cannot keep up with live words.
    /// Two such windows in a row end live recognition for the take (`TooSlow`):
    /// the words shown stay, and the finished text still comes from the final
    /// pass, which then has the processor to itself. A window still running
    /// after `WindowLimitMs` is canceled by the recognizer and counts as slow.
    public const int SlowWindowFloorMs = 3000, WindowLimitMs = 10_000, SlowWindowsBeforeStop = 2;

    readonly object sync = new();
    readonly Func<long>? clock = clock;
    long inFlightSince, restUntil;
    bool began;
    readonly LiveWindowPlanner planner = planner ?? new();
    readonly LiveAudioRing ring = new(ringSeconds);
    readonly WhisperLiveMerger merger = new();
    long lastEndSample;
    uint nextSequence;
    LiveWindowRequest? inFlight;
    public uint Session { get; } = session;
    public bool Closed { get; private set; }
    public bool Failed { get; private set; }
    /// Live words ended for this take because two windows in a row were slower than real time.
    public bool TooSlow { get; private set; }
    int slowRun;
    public int Inferences { get; private set; }
    public int SilentWindows { get; private set; }
    public int RingCapacity => ring.Capacity;
    public bool Busy { get { lock (sync) return inFlight != null; } }
    public long TotalSamples { get { lock (sync) return ring.Total; } }
    public string Text { get { lock (sync) return merger.Text; } }

    /// 16 kHz mono PCM from the recorder thread. Ignored after Close.
    public void Append(ReadOnlySpan<short> pcm) { lock (sync) if (!Closed) ring.Append(pcm); }

    /// The next window to recognize, or null when one is already running, the
    /// take is over, there is not enough new audio, or the new audio is silent.
    public LiveWindowRequest? Next()
    {
        lock (sync) {
            if (Closed || Failed || TooSlow || inFlight != null) return null;
            long now = clock?.Invoke() ?? 0;
            if (now < restUntil) return null;
            if (planner.Next(ring.Total, merger.CommittedEndMs, lastEndSample) is not var (start, end)) return null;
            var fresh = ring.Snapshot(lastEndSample, end);
            lastEndSample = end;
            var window = ring.Snapshot(start, end);
            if (!LiveAudioGate.HasSpeech(fresh) || window.Length == 0) { SilentWindows++; return null; }
            Inferences++;
            inFlightSince = now; began = false;
            return inFlight = new LiveWindowRequest(Session, nextSequence++, end - window.Length, end, window);
        }
    }

    /// The window has the worker and recognition starts now. Time spent waiting
    /// for the worker (a launch prewarm, a model load) is never held against it.
    public void Begin(LiveWindowRequest request)
    {
        lock (sync) { if (ReferenceEquals(request, inFlight)) { began = true; inFlightSince = clock?.Invoke() ?? 0; } }
    }

    /// Applies a finished window. Returns the update to show, or null when the
    /// result is late, belongs elsewhere, or changes nothing.
    public TranscriptUpdate? Complete(LiveWindowRequest request, IReadOnlyList<WhisperWindowSegment> segments)
    {
        lock (sync) {
            if (!ReferenceEquals(request, inFlight) || request.Session != Session) return null;
            inFlight = null;
            Rest(request, canceled: false);
            if (Closed || Failed) return null;
            return merger.Apply(request.Window(segments)) ? new TranscriptUpdate(Session.ToString(), request.Sequence, merger.Text, false) : null;
        }
    }

    /// Called under `sync` when the window in flight ends, however it ended. A
    /// window the recognizer canceled while the take was still going was at
    /// its time limit, so it counts as slow whatever the clock says. A window
    /// that never began (canceled while waiting for the worker) says nothing.
    void Rest(LiveWindowRequest ended, bool canceled)
    {
        long now = clock?.Invoke() ?? 0;
        // A window that never ran has nothing to rest from and says nothing about speed.
        if (!began) { restUntil = now; return; }
        long took = Math.Max(0, now - inFlightSince);
        restUntil = now + (long)(took * RestRatio);
        // Replays have no clock; a window canceled because the take stopped says nothing about speed.
        if (clock == null || Closed) return;
        long audioMs = (ended.EndSample - ended.StartSample) / LiveWindowPlanner.SamplesPerMs;
        if (canceled || took > Math.Max(audioMs, SlowWindowFloorMs)) { if (++slowRun >= SlowWindowsBeforeStop) TooSlow = true; }
        else slowRun = 0;
    }

    /// The window was canceled (the take stopped, or it reached the time limit); a later one may run, after the same rest.
    public void Abandon(LiveWindowRequest request)
    {
        lock (sync) {
            if (!ReferenceEquals(request, inFlight)) return;
            inFlight = null;
            Rest(request, canceled: true);
        }
    }

    /// Live recognition stopped working for this take. The words shown stay.
    public void Fail() { lock (sync) { Failed = true; inFlight = null; } }

    /// Ends the take for live recognition and returns the words shown so far.
    public string Close() { lock (sync) { Closed = true; return merger.Text; } }
}

/// Which words a finished take keeps. The finished text always comes from the
/// whole-recording pass, so it includes the last words even if no live window
/// heard them. Only when that pass fails are the live words kept, in History,
/// with an honest status, and never typed.
public static class LiveTake
{
    public const string KeptStatus = "Kept in History. Recognition stopped before it finished, so nothing was typed.";
    /// Preview note when live words end because the computer cannot keep up.
    public const string TooSlowNote = "Live words stopped: too slow here. Words go in when you stop";

    /// Words worth keeping after the final pass failed, or null.
    public static string? Recoverable(string? live) => string.IsNullOrWhiteSpace(live) ? null : live.Trim();
}
