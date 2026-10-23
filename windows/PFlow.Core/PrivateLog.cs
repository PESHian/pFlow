using System.Text.RegularExpressions;

namespace PFlow.Core;

/// What a private log line may carry. Windows error messages often quote a
/// file path, and a path holds the account name: every path is replaced before
/// a line is written, so the log can be sent along with a bug report. Account
/// names can hold spaces ("John Smith"): a quoted path runs to its closing
/// quote, and an unquoted one keeps spaces in every folder name before the
/// last separator (the last name ends at a space).
public static partial class PrivateLog
{
    const string WindowsRoot = @"(?:[A-Za-z]:|\\\\[^\s\\]+)\\", HomeRoot = @"(?<![\w.])/(?:home|Users)/";
    [GeneratedRegex(@"(?<=[""'])" + WindowsRoot + @"[^""'<>|\r\n]*(?=[""'])", RegexOptions.CultureInvariant)]
    private static partial Regex QuotedWindowsPath();
    [GeneratedRegex(WindowsRoot + @"(?:[^\\""'<>|\r\n:]*\\)*[^\s""'<>|\\]*", RegexOptions.CultureInvariant)]
    private static partial Regex WindowsPath();
    [GeneratedRegex(@"(?<=[""'])" + HomeRoot + @"[^""'<>|\r\n]*(?=[""'])", RegexOptions.CultureInvariant)]
    private static partial Regex QuotedHomePath();
    [GeneratedRegex(HomeRoot + @"(?:[^/""'<>|\r\n:]*/)*[^\s""'<>|/]*", RegexOptions.CultureInvariant)]
    private static partial Regex HomePath();

    public static string Scrub(string line)
    {
        line = QuotedWindowsPath().Replace(line, "<path>"); line = WindowsPath().Replace(line, "<path>");
        line = QuotedHomePath().Replace(line, "<path>"); return HomePath().Replace(line, "<path>");
    }

    /// An exception as a log reason: its type and its message with paths removed.
    public static string Reason(Exception error) => error.GetType().Name + ": " + Scrub(error.Message);
}
