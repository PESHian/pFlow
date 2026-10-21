using System.Text.RegularExpressions;

namespace PFlow.Core;

/// What a private log line may carry. Windows error messages often quote a
/// file path, and a path holds the account name: every path is replaced before
/// a line is written, so the log can be sent along with a bug report.
public static partial class PrivateLog
{
    [GeneratedRegex(@"(?:[A-Za-z]:|\\\\[^\s\\]+)\\[^\s""'<>|]*", RegexOptions.CultureInvariant)]
    private static partial Regex WindowsPath();
    [GeneratedRegex(@"(?<![\w.])/(?:home|Users)/[^\s""'<>|]*", RegexOptions.CultureInvariant)]
    private static partial Regex HomePath();

    public static string Scrub(string line) => HomePath().Replace(WindowsPath().Replace(line, "<path>"), "<path>");

    /// An exception as a log reason: its type and its message with paths removed.
    public static string Reason(Exception error) => error.GetType().Name + ": " + Scrub(error.Message);
}
