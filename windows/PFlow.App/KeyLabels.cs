namespace PFlow.Windows;

internal static class KeyLabels
{
    public static string Name(ActivationKey key)
    {
        if (!key.Id.StartsWith("key:",StringComparison.Ordinal) || key.VirtualKey is 0xA0 or 0xA1 or 0xA4 or 0x5B or 0xB6 or 0xB7) return key.Name;
        uint scan = key.ScanCode == 0 ? Native.MapVirtualKey(key.VirtualKey,0) & 255 : key.ScanCode;
        var text = new System.Text.StringBuilder(80);
        if (scan != 0 && Native.GetKeyNameText((int)(scan << 16) | (key.Extended ? 1 << 24 : 0),text,text.Capacity) > 0) return text.ToString();
        return key.Name;
    }
    public static IReadOnlyList<ActivationKey> Options(string selected)
    {
        var key = ActivationKeys.Resolve(selected);
        return ActivationKeys.Choices.Concat(ActivationKeys.Choices.Any(x => x.Id == key.Id) ? [] : new[] { key }).Select(x => x with { Name = Name(x) }).ToArray();
    }
}
