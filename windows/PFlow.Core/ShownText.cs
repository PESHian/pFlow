namespace PFlow.Core;

/// The check for an app pFlow can read only around the caret (LibreOffice's paragraphs on screen, a
/// Scintilla editor's text): the words landed when what the app shows holds the expected passage (the
/// caret paragraph with the words in place) once more than it did before the write. Line breaks of any
/// kind count as one, and a no-break space as a space; nothing else is forgiven.
public static class ShownText
{
    public static string Plain(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n').Replace('\u00A0', ' ').Replace('\u2029', '\n').Replace('\u2028', '\n');

    public static int Count(string text, string part)
    {
        if (part.Length == 0) return 0;
        int count = 0;
        for (int at = text.IndexOf(part, StringComparison.Ordinal); at >= 0; at = text.IndexOf(part, at + part.Length, StringComparison.Ordinal)) count++;
        return count;
    }

    public static bool Landed(string before, string after, string expected)
    {
        string passage = Plain(expected);
        return passage.Trim().Length > 0 && Count(Plain(after), passage) > Count(Plain(before), passage);
    }
}
