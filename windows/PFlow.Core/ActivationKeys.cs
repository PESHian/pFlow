namespace PFlow.Core;

public sealed record ActivationKey(string Id, string Name, uint VirtualKey, bool Extended = false, uint ScanCode = 0)
{
    public bool Matches(uint key, uint scan = 0, bool? extended = null) => ScanCode != 0 && scan != 0
        ? ScanCode == scan && (extended == null || Extended == extended)
        : VirtualKey == key && (extended == null || !Id.StartsWith("key:", StringComparison.Ordinal) || Extended == extended);
}

public static class ActivationKeys
{
    public const string DefaultId = "rightWindows";
    public static IReadOnlyList<ActivationKey> Choices { get; } = Array.AsReadOnly<ActivationKey>([
        new(DefaultId, "Right Windows", 0x5C, true),
        new("rightControl", "Right Ctrl", 0xA3, true), new("leftControl", "Left Ctrl", 0xA2),
        new("rightAlt", "Right Alt", 0xA5, true), new("menu", "Menu / App", 0x5D, true),
        new("f8", "F8", 0x77), new("f9", "F9", 0x78), new("f10", "F10", 0x79),
        new("f11", "F11", 0x7A), new("f12", "F12", 0x7B)
    ]);
    public static bool Usable(uint key) => key is >= 8 and <= 255 && key != 0x1B && key is not (0x10 or 0x11 or 0x12);
    public static ActivationKey FromEvent(uint key, uint scan = 0, bool extended = false)
    {
        if (!Usable(key)) throw new ArgumentException("Choose a keyboard key. Escape is kept for cancellation.");
        return Choices.FirstOrDefault(choice => choice.VirtualKey == key) ?? new($"key:{key:X2}:{scan & 255:X2}:{(extended ? 1 : 0)}", Name(key), key, extended, scan & 255);
    }
    public static ActivationKey Resolve(string? id)
    {
        if (Choices.FirstOrDefault(key => key.Id == id) is { } known) return known;
        var parts = id?.Split(':');
        if (parts is ["key", var vk, var scan, var ext] && vk.Length == 2 && scan.Length == 2 && ext is "0" or "1" &&
            uint.TryParse(vk, System.Globalization.NumberStyles.HexNumber, null, out uint code) && Usable(code) &&
            uint.TryParse(scan, System.Globalization.NumberStyles.HexNumber, null, out uint scanCode)) return FromEvent(code, scanCode, ext == "1");
        return Choices[0];
    }
    static string Name(uint key) => key switch {
        >= 0x41 and <= 0x5A or >= 0x30 and <= 0x39 => ((char)key).ToString(),
        >= 0x70 and <= 0x87 => "F" + (key - 0x6F),
        0xA0 => "Left Shift", 0xA1 => "Right Shift", 0xA2 => "Left Ctrl", 0xA3 => "Right Ctrl", 0xA4 => "Left Alt", 0xA5 => "Right Alt",
        0x5B => "Left Windows", 0x5C => "Right Windows", 0x5D => "Menu / App", 0xB6 => "App 1", 0xB7 => "App 2",
        0x08 => "Backspace", 0x09 => "Tab", 0x0D => "Enter", 0x20 => "Space", 0x14 => "Caps Lock", 0x2E => "Delete", _ => $"Key {key:X2}"
    };
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
    public KeyRoute Process(uint key, bool down, bool injected, long time, Func<uint, bool> held, uint scan = 0, bool? extended = null)
    {
        if (injected) return default;
        bool selectedKey = Selected.Matches(key, scan, extended);
        if (selectedKey) {
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
        if (selectedKey) {
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
