namespace PFlow.Core;

/// Microphone loudness as a 0..1 level for the waveform. Windows microphones
/// often sit around -35 dBFS for ordinary speech, so the floor is -55 dB with a
/// gentle curve: ordinary speech lands well above the capsule's 0.25 peak floor
/// and fills the bars, while room noise near -55 dB stays flat.
public static class AudioLevels
{
    public const double FloorDb = -55, Curve = 1.2;
    public static double FromRms(double rms) => rms <= 0 ? 0 : Math.Pow(Math.Clamp((20 * Math.Log10(rms) - FloorDb) / -FloorDb, 0, 1), Curve);
    public static double FromDecibels(double db) => FromRms(Math.Pow(10, db / 20));
}

public sealed class WaveMotion
{
    const double Interval = .04;
    readonly Queue<double> samples = new(Enumerable.Repeat(0.0, 25));
    double partial;
    public double Level { get; private set; }
    public void Reset() { samples.Clear(); foreach (double value in Enumerable.Repeat(0.0, 25)) samples.Enqueue(value); partial = Level = 0; }
    public void Advance(double target, double seconds)
    {
        target = double.IsFinite(target) ? Math.Clamp(target, 0, 1) : 0;
        seconds = double.IsFinite(seconds) ? Math.Clamp(seconds, 0, .25) : 0;
        while (seconds > 1e-9) {
            double step = Math.Min(seconds, Interval - partial);
            Level += (target - Level) * (1 - Math.Exp(-step / (target > Level ? .055 : .16)));
            partial += step; seconds -= step;
            if (partial >= Interval - 1e-9) { samples.Dequeue(); samples.Enqueue(Level); partial = 0; }
        }
    }
    public double[] Levels()
    {
        var values = samples.Append(Level).ToArray(); double fraction = partial / Interval;
        return Enumerable.Range(0, 25).Select(i => values[i] + (values[i + 1] - values[i]) * fraction).ToArray();
    }
}

public readonly record struct WorkArea(double X, double Y, double Width, double Height);
public static class CapsulePlacement
{
    public static (double X, double Y) Place(IReadOnlyList<WorkArea> areas, int preferred, double width, double height, double? x, double? y)
    {
        if (areas.Count == 0) throw new ArgumentException("A display work area is required.");
        var area = areas[Math.Clamp(preferred, 0, areas.Count - 1)];
        bool saved = x.HasValue && y.HasValue && double.IsFinite(x.Value) && double.IsFinite(y.Value);
        double overlap = 0;
        if (saved) foreach (var candidate in areas) {
            double intersection = Math.Max(0, Math.Min(x!.Value + width, candidate.X + candidate.Width) - Math.Max(x.Value, candidate.X))
                * Math.Max(0, Math.Min(y!.Value + height, candidate.Y + candidate.Height) - Math.Max(y.Value, candidate.Y));
            if (intersection > overlap) { overlap = intersection; area = candidate; }
        }
        bool restore = saved && overlap > 0;
        return (Math.Clamp(restore ? x!.Value : area.X + (area.Width - width) / 2, area.X, Math.Max(area.X, area.X + area.Width - width)),
            Math.Clamp(restore ? y!.Value : area.Y + area.Height - height - height * 1.25, area.Y, Math.Max(area.Y, area.Y + area.Height - height)));
    }
}
