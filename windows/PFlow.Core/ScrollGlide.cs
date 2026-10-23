namespace PFlow.Core;

/// The arithmetic of a smooth wheel scroll, apart from WPF so it can be checked anywhere. A wheel
/// notch does not jump: the page glides to its new place with an ease-out over `DurationMs`. A notch
/// that arrives during a glide adds to where the page was heading (a fast flick of five notches goes
/// five notches) and the glide restarts from where the page is now. A precision touchpad's small,
/// frequent deltas are already smooth and are applied as they come, without a glide; one that arrives
/// during a glide moves the page at once and the rest of the notch still glides (`Shift`).
public sealed class ScrollGlide
{
    public const double DurationMs = 150;
    public double From { get; private set; }
    public double To { get; private set; }
    public bool Active { get; private set; }
    double startMs;

    /// A wheel notch is a whole multiple of 120 (WHEEL_DELTA); anything else is a high-resolution
    /// device (a precision touchpad or a free-spinning wheel).
    public static bool IsNotch(int delta) => delta != 0 && delta % 120 == 0;

    /// Ease-out (cubic): quick at first, settling gently, never past the end.
    public static double Ease(double t) { t = Math.Clamp(t, 0, 1); return 1 - (1 - t) * (1 - t) * (1 - t); }

    /// One notch of `pixels` (positive is down) on a page now at `current` that can go from 0 to `maximum`.
    public void Add(double current, double pixels, double maximum, double nowMs)
    {
        double heading = Active ? To : current;
        To = Math.Clamp(heading + pixels, 0, Math.Max(0, maximum)); From = current; startMs = nowMs; Active = true;
    }

    /// The page's offset for a frame at `nowMs`; the glide ends on the frame that reaches its target.
    public double At(double nowMs)
    {
        double t = (nowMs - startMs) / DurationMs;
        if (t >= 1) { Active = false; return To; }
        return From + (To - From) * Ease(t);
    }

    /// A touchpad moved the page `pixels` during a glide: the page moves that much at once and the
    /// rest of the notch still glides, from the new place, on the same clock.
    public void Shift(double pixels, double maximum)
    {
        if (!Active) return;
        double top = Math.Max(0, maximum);
        From = Math.Clamp(From + pixels, 0, top); To = Math.Clamp(To + pixels, 0, top);
    }

    /// Something else took the page (the scroll bar, a finger, a key, a click): the glide lets go.
    public void Stop() => Active = false;
}
