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
public sealed class LiveSession(uint session, LiveWindowPlanner? planner = null, int ringSeconds = 20)
{
    readonly object sync = new();
    readonly LiveWindowPlanner planner = planner ?? new();
    readonly LiveAudioRing ring = new(ringSeconds);
    readonly WhisperLiveMerger merger = new();
    long lastEndSample;
    uint nextSequence;
    LiveWindowRequest? inFlight;
    public uint Session { get; } = session;
    public bool Closed { get; private set; }
    public bool Failed { get; private set; }
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
            if (Closed || Failed || inFlight != null) return null;
            if (planner.Next(ring.Total, merger.CommittedEndMs, lastEndSample) is not var (start, end)) return null;
            var fresh = ring.Snapshot(lastEndSample, end);
            lastEndSample = end;
            var window = ring.Snapshot(start, end);
            if (!LiveAudioGate.HasSpeech(fresh) || window.Length == 0) { SilentWindows++; return null; }
            Inferences++;
            return inFlight = new LiveWindowRequest(Session, nextSequence++, end - window.Length, end, window);
        }
    }

    /// Applies a finished window. Returns the update to show, or null when the
    /// result is late, belongs elsewhere, or changes nothing.
    public TranscriptUpdate? Complete(LiveWindowRequest request, IReadOnlyList<WhisperWindowSegment> segments)
    {
        lock (sync) {
            if (!ReferenceEquals(request, inFlight) || request.Session != Session) return null;
            inFlight = null;
            if (Closed || Failed) return null;
            return merger.Apply(request.Window(segments)) ? new TranscriptUpdate(Session.ToString(), request.Sequence, merger.Text, false) : null;
        }
    }

    /// The window was abandoned (canceled); a later one may run.
    public void Abandon(LiveWindowRequest request) { lock (sync) if (ReferenceEquals(request, inFlight)) inFlight = null; }

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

    /// Words worth keeping after the final pass failed, or null.
    public static string? Recoverable(string? live) => string.IsNullOrWhiteSpace(live) ? null : live.Trim();
}
