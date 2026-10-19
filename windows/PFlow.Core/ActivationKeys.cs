namespace PFlow.Core;

public sealed record ActivationKey(string Id, string Name, uint VirtualKey, bool Extended = false);

public static class ActivationKeys
{
    public const string DefaultId = "rightWindows";
    public static IReadOnlyList<ActivationKey> Choices { get; } = Array.AsReadOnly<ActivationKey>([
        new(DefaultId, "Right Windows", 0x5C, true),
        new("rightControl", "Right Ctrl", 0xA3, true),
        new("f8", "F8", 0x77), new("f9", "F9", 0x78), new("f10", "F10", 0x79),
        new("f11", "F11", 0x7A), new("f12", "F12", 0x7B)
    ]);
    public static ActivationKey Resolve(string? id) => Choices.FirstOrDefault(key => key.Id == id) ?? Choices[0];
}

public readonly record struct KeyRoute(TriggerAction Action = TriggerAction.None, bool Consume = false, ActivationKey? Replay = null);

// Tracks whether a suppressed down or replayed modifier still owns a physical up.
// Resetting dictation must not lose that ownership or start again during key-repeat.
public sealed class ActivationRouter
{
    static readonly uint[] modifiers = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C];
    readonly Trigger trigger = new();
    bool blockedUntilUp, passUntilUp;
    public ActivationKey Selected { get; private set; }
    public bool Enabled { get; private set; } = true;
    public bool Held => trigger.Down || blockedUntilUp || passUntilUp;
    public bool CanRebind => !Held && !trigger.Recording;
    public ActivationRouter(string? id = ActivationKeys.DefaultId) => Selected = ActivationKeys.Resolve(id);
    public void Select(string id)
    {
        var selected = ActivationKeys.Resolve(id);
        if (selected == Selected) return;
        if (!CanRebind) throw new InvalidOperationException("Finish or cancel recording, then release the activation key before changing it.");
        Selected = selected; trigger.Reset();
    }
    public TriggerAction SetEnabled(bool enabled)
    {
        if (enabled == Enabled) return TriggerAction.None;
        bool recording = trigger.Recording;
        Reset(); Enabled = enabled;
        return recording ? TriggerAction.Cancel : TriggerAction.None;
    }
    public void Reset()
    {
        if (trigger.Down && !trigger.Chord) blockedUntilUp = true;
        trigger.Reset();
    }
    public void ReplayFailed()
    {
        passUntilUp = false; blockedUntilUp = true; trigger.Reset();
    }
    public KeyRoute Process(uint key, bool down, bool injected, long time, Func<uint, bool> held)
    {
        if (injected) return default;
        if (key == Selected.VirtualKey) {
            if (blockedUntilUp) { if (!down) blockedUntilUp = false; return new(Consume: true); }
            if (passUntilUp) {
                if (!down) { passUntilUp = false; if (trigger.Chord) trigger.Reset(); }
                return default;
            }
        }
        // A canceled/unsupported recording still owes the suppressed modifier to
        // a later real shortcut, until the physical activation key is released.
        if (blockedUntilUp && down && key != 0x1B) {
            blockedUntilUp = false; passUntilUp = true;
            return new(Replay: Selected);
        }
        if (!Enabled) return default;
        if (key == 0x1B && down) { Reset(); return new(TriggerAction.Cancel); }
        if (key == Selected.VirtualKey) {
            if (down && !trigger.Down && modifiers.Any(modifier => modifier != key && held(modifier))) {
                passUntilUp = true; return default;
            }
            if (!down && !trigger.Down) return default;
            return new(down ? trigger.Press(time) : trigger.Release(time), true);
        }
        if (down && trigger.Down && !trigger.Chord) {
            var action = trigger.OtherKey(); passUntilUp = true;
            return new(action, Replay: Selected);
        }
        return default;
    }
}
