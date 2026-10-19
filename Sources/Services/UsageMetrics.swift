import Foundation

struct UsageTotals {
    var dictations = 0
    var words = 0
    var seconds: Double = 0
    private(set) var timedWords = 0

    var wordsPerMinute: Double? { seconds > 0 ? Double(timedWords) * 60 / seconds : nil }

    mutating func add(_ transcript: Transcript) {
        dictations += 1
        words += transcript.spokenWordCount ?? transcript.text.split(whereSeparator: \.isWhitespace).count
        // Earlier durations included processing, so only use the new timed records.
        if let count = transcript.spokenWordCount, let duration = transcript.durationSeconds,
           duration.isFinite, duration > 0 {
            seconds += duration
            timedWords += count
        }
    }
}

struct UsageDay: Identifiable {
    let id: Date
    let totals: UsageTotals
}

struct UsageApplication: Identifiable {
    let id: String
    let name: String
    let totals: UsageTotals
}

struct UsageMetrics {
    var total = UsageTotals()
    var days: [UsageDay]
    var applications: [UsageApplication]

    /// Calendar days, including quiet days. Never turn a lone daily total into
    /// an intraday graph or space days by fixed seconds across daylight saving.
    func recentDays(count: Int = 7, now: Date = .now, calendar: Calendar = .current) -> [UsageDay] {
        guard count > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        let known = Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0.totals) })
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return UsageDay(id: date, totals: known[date] ?? UsageTotals())
        }
    }

    init(transcripts: [Transcript], calendar: Calendar = .current) {
        var daily: [Date: UsageTotals] = [:]
        var apps: [String: UsageTotals] = [:]
        var names: [String: String] = [:]
        for transcript in transcripts {
            total.add(transcript)
            let day = calendar.startOfDay(for: transcript.createdAt)
            daily[day, default: UsageTotals()].add(transcript)
            let key = transcript.applicationBundleID ?? transcript.applicationName ?? "earlier-activity"
            names[key] = names[key] ?? transcript.applicationName ?? "Earlier activity"
            apps[key, default: UsageTotals()].add(transcript)
        }
        days = daily.map { UsageDay(id: $0.key, totals: $0.value) }.sorted { $0.id > $1.id }
        applications = apps.map { UsageApplication(id: $0.key, name: names[$0.key]!, totals: $0.value) }
            .sorted { $0.totals.words == $1.totals.words ? $0.name < $1.name : $0.totals.words > $1.totals.words }
    }
}
