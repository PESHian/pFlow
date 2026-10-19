using System.Globalization;
using System.Text;

namespace PFlow.Core;

// MIT Mac InsertionSpacing port. Destination padding never changes History or words.
public static class InsertionSpacing
{
    public readonly record struct Padding(string Before, string After)
    {
        public string Apply(string text) => Before + text + After;
    }
    public static Padding AtCaret(string text, string value, int start, int length)
    {
        var none = new Padding("", "");
        if (text.Length == 0 || length != 0 || start < 0 || start > value.Length) return none;
        int[] boundaries = StringInfo.ParseCombiningCharacters(value);
        int index = start == value.Length ? boundaries.Length : Array.BinarySearch(boundaries, start);
        if (index < 0) return none;
        string? left = index > 0 ? value[boundaries[index - 1]..start] : null;
        string? right = start < value.Length ? StringInfo.GetNextTextElement(value, start) : null;
        if (left != null && right != null && IsWord(left) && IsWord(right)) return none;
        int[] incoming = StringInfo.ParseCombiningCharacters(text);
        string first = StringInfo.GetNextTextElement(text), last = text[incoming[^1]..];
        return new(left != null && NeedsGap(left, first) ? " " : "", right != null && NeedsGap(last, right) ? " " : "");
    }
    static bool IsWord(string value) => value.EnumerateRunes().Any(Rune.IsLetterOrDigit);
    static bool Unspaced(string value) => value.EnumerateRunes().Any(r => r.Value is >= 0x2E80 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF or >= 0x20000 and <= 0x323AF);
    static bool NeedsGap(string left, string right) => !string.IsNullOrWhiteSpace(left) && !string.IsNullOrWhiteSpace(right)
        && !"([{‘“_-/'\\@#".Contains(left, StringComparison.Ordinal) && !".,;:!?%)]}’”_-/'\\@#".Contains(right, StringComparison.Ordinal)
        && !Unspaced(left) && !Unspaced(right);
}
