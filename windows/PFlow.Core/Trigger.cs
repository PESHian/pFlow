namespace PFlow.Core;

public enum TriggerAction { None, Start, Stop, Continuous, Cancel }
// Right Windows is the only trigger. A quick pair of taps is continuous mode.
public sealed class Trigger
{
    public bool Down { get; private set; }
    public bool Recording { get; private set; }
    public bool Continuous { get; private set; }
    public bool Chord { get; private set; }
    long pressed, lastTap = long.MinValue / 2;
    bool stopTap;
    public TriggerAction Press(long milliseconds)
    {
        if (Down) return TriggerAction.None;
        Down = true; Chord = false; pressed = milliseconds;
        if (Continuous) { stopTap = true; return TriggerAction.None; }
        stopTap = false;
        if (milliseconds - lastTap <= 300) { Continuous = Recording = true; return TriggerAction.Continuous; }
        Recording = true; return TriggerAction.Start;
    }
    public TriggerAction Release(long milliseconds)
    {
        if (!Down) return TriggerAction.None;
        Down = false;
        if (Chord) { Reset(); return TriggerAction.None; }
        if (stopTap) { Reset(); return TriggerAction.Stop; }
        if (Continuous) return TriggerAction.None;
        Recording = false;
        lastTap = milliseconds - pressed <= 300 ? milliseconds : long.MinValue / 2;
        return TriggerAction.Stop;
    }
    public TriggerAction OtherKey()
    {
        if (!Down) return TriggerAction.None;
        Chord = true; Recording = Continuous = false; lastTap = long.MinValue / 2;
        return TriggerAction.Cancel;
    }
    public void Reset() { Down = Recording = Continuous = Chord = stopTap = false; lastTap = long.MinValue / 2; }
}
