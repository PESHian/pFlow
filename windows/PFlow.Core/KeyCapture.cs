namespace PFlow.Core;

public readonly record struct CaptureRoute(bool Consume = false, ActivationKey? Key = null, string? Issue = null);

// Own every suppressed down through its up, even after cancellation or window close.
public sealed class KeyCapture
{
    public KeyCapture(IEnumerable<uint>? initiallyHeld = null)
    {
        if (initiallyHeld?.Any() == true) throw new InvalidOperationException("Release held keys, then choose Press a key again.");
    }
    readonly HashSet<uint> owned = [];
    ActivationKey? candidate;
    long candidateTime;
    bool canceled, completed;
    public bool Listening => !canceled && !completed;
    public bool Drained => !Listening && owned.Count == 0;
    public bool Cancel() { bool active = Listening; canceled = true; return active; }
    public CaptureRoute Process(uint key, uint scan, bool extended, bool down, bool injected, long time)
    {
        if (injected) return default;
        uint token = scan == 0 ? key : 0x10000u | (scan & 255) | (extended ? 0x100u : 0);
        if (!Listening) {
            bool consume = owned.Contains(token);
            if (!down) owned.Remove(token);
            return new(consume);
        }
        if (down) {
            if (!owned.Add(token)) return new(true);
            if (key == 0x1B) { Cancel(); return new(true, Issue: "Key selection canceled."); }
            if (!ActivationKeys.Usable(key)) { Cancel(); return new(true, Issue: "Windows did not report a usable keyboard key. Try another key."); }
            if (candidate != null) {
                // AltGr is delivered as a same-timestamp Left Ctrl / Right Alt pair.
                if (candidate.VirtualKey != 0xA2 || key != 0xA5 || candidateTime != time) {
                    Cancel(); return new(true, Issue: "Press one key on its own, then release it.");
                }
            }
            candidate = ActivationKeys.FromEvent(key, scan, extended); candidateTime = time;
            return new(true);
        }
        if (!owned.Remove(token)) return default;
        if (owned.Count != 0 || candidate == null) return new(true);
        completed = true;
        return new(true, candidate);
    }
}
