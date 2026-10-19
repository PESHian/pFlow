namespace PFlow.Core;

public sealed record DailyUsage(DateOnly Date, Usage Totals);
public sealed record ApplicationUsage(string Name, Usage Totals);

// A read-only view of saved history. Local calendar dates also keep DST days intact.
public sealed record UsageStatistics(Usage Total, IReadOnlyList<DailyUsage> RecentDays,
    IReadOnlyList<DailyUsage> ActiveDays, IReadOnlyList<ApplicationUsage> Applications)
{
    public static UsageStatistics From(IEnumerable<Transcript> records, DateOnly today)
    {
        var all = records.OrderByDescending(x => x.CreatedAt).ToList();
        var days = all.GroupBy(x => DateOnly.FromDateTime(x.CreatedAt.LocalDateTime))
            .ToDictionary(g => g.Key, g => Usage.From(g));
        var recent = Enumerable.Range(-6, 7).Select(offset => {
            var date = today.AddDays(offset);
            return new DailyUsage(date, days.GetValueOrDefault(date) ?? Usage.From([]));
        }).ToList();
        var active = days.OrderByDescending(x => x.Key).Take(30).Select(x => new DailyUsage(x.Key, x.Value)).ToList();
        string Key(Transcript x) => !string.IsNullOrWhiteSpace(x.ApplicationBundleID) ? "id:" + x.ApplicationBundleID.Trim()
            : !string.IsNullOrWhiteSpace(x.ApplicationName) ? "name:" + x.ApplicationName.Trim() : "earlier:";
        var apps = all.GroupBy(Key, StringComparer.OrdinalIgnoreCase).Select(g => new ApplicationUsage(
            g.Select(x => x.ApplicationName).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x))?.Trim()
                ?? g.Select(x => x.ApplicationBundleID).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x))?.Trim() ?? "Earlier activity", Usage.From(g)))
            .OrderByDescending(x => x.Totals.Words).ThenBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        return new(Usage.From(all), recent, active, apps);
    }
}
