using System.Globalization;
using System.Text.RegularExpressions;

namespace PFlow.Windows;

/// What one History row shows: when, the first words, and one word for what happened.
internal static class HistoryRow
{
    /// "Today 4:06 PM", "Yesterday 9:12 AM", else a short date with the time ("Oct 20 4:06 PM").
    public static string When(DateTimeOffset created, DateTimeOffset now)
    {
        var local = created.ToLocalTime(); var today = now.ToLocalTime().Date;
        string time = local.ToString("t", CultureInfo.CurrentCulture);
        if (local.Date == today) return "Today " + time;
        if (local.Date == today.AddDays(-1)) return "Yesterday " + time;
        return local.ToString(local.Year == today.Year ? "MMM d" : "MMM d, yyyy", CultureInfo.CurrentCulture) + " " + time;
    }
    /// The first words on one line, cut at a word with an ellipsis.
    public static string Words(string text, int limit = 72)
    {
        string one = Regex.Replace(text, @"\s+", " ").Trim();
        if (one.Length <= limit) return one;
        int cut = one.LastIndexOf(' ', limit);
        return one[..(cut >= limit / 2 ? cut : limit)] + "…";
    }
    public const string Inserted = "Inserted", CheckTheField = "Check the field", Kept = "Kept";
    /// One word for the insertion status: the words went in, went out unchecked, or stayed in History.
    public static string Status(string status) =>
        status.StartsWith("Inserted", StringComparison.Ordinal) ? Inserted
        : status.StartsWith(InsertionTarget.Unchecked, StringComparison.Ordinal) || status.StartsWith(InsertionTarget.Unconfirmed, StringComparison.Ordinal) ? CheckTheField
        : Kept;
}
