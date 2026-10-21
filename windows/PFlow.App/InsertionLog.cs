namespace PFlow.Windows;

/// One private line per step of a take's insertion, so a failed test on another PC
/// says exactly where it stopped. Never the dictated words, the field's text, the
/// clipboard, or a window title: only app names, control kinds, lengths and messages.
internal static class InsertionLog
{
    const long Limit = 256 * 1024;
    static readonly object sync = new();
    internal static string? Path { get; set; }
    /// Tests read the lines as they are written.
    internal static event Action<string>? Written;
    internal static void Record(string line)
    {
        string entry = DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz") + " " + line;
        Written?.Invoke(entry);
        if (Path == null) return;
        lock (sync) {
            try {
                if (new FileInfo(Path) is { Exists: true, Length: > Limit } file) {
                    var lines = File.ReadAllLines(Path);
                    File.WriteAllLines(Path, lines.Skip(lines.Length / 2));
                }
                File.AppendAllText(Path, entry + Environment.NewLine);
            } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* the log is never worth a failure */ }
        }
    }
    /// A length in place of text: enough to see a mismatch, nothing to read.
    internal static string Length(string? text) => text == null ? "null" : text.Length + " chars";
}
