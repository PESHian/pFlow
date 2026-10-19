import Foundation
import Testing
@testable import Yap

@MainActor
struct UsageMetricsTests {
    @Test func chartUsesSevenCalendarDaysIncludingQuietDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        let record = Transcript(text: "one", createdAt: now, durationSeconds: 60, spokenWordCount: 150)
        let metrics = UsageMetrics(transcripts: [record], calendar: calendar)
        let days = metrics.recentDays(now: now, calendar: calendar)
        #expect(days.count == 7)
        #expect(Set(days.map(\.id)).count == 7)
        #expect(days.dropLast().allSatisfy { $0.totals.words == 0 })
        #expect(days.last?.totals.words == 150)
        #expect(days.allSatisfy { calendar.component(.hour, from: $0.id) == 0 })
        #expect(metrics.total.timedWords == 150)
    }
    @Test func groupsByDayAndApplicationWithWeightedPace() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = Transcript(text: "saved text", createdAt: Date(timeIntervalSince1970: 1_000),
                               durationSeconds: 30, spokenWordCount: 60,
                               applicationName: "Safari", applicationBundleID: "com.apple.Safari")
        let second = Transcript(text: "saved text", createdAt: Date(timeIntervalSince1970: 90_000),
                                durationSeconds: 90, spokenWordCount: 40,
                                applicationName: "TextEdit", applicationBundleID: "com.apple.TextEdit")
        let metrics = UsageMetrics(transcripts: [first, second], calendar: calendar)
        #expect(metrics.total.dictations == 2)
        #expect(metrics.total.words == 100)
        #expect(metrics.total.seconds == 120)
        #expect(metrics.total.wordsPerMinute == 50)
        #expect(metrics.days.count == 2)
        #expect(metrics.days.first?.totals.words == 40)
        #expect(metrics.applications.first?.name == "Safari")
        #expect(metrics.applications.first?.totals.wordsPerMinute == 120)
    }

    @Test func legacyRecordsKeepWordsWithoutInventingAppOrPace() {
        let legacy = Transcript(text: "these are five saved words", durationSeconds: 1)
        let current = Transcript(text: "edited", durationSeconds: 60, spokenWordCount: 10,
                                 applicationName: "Safari", applicationBundleID: "com.apple.Safari")
        let metrics = UsageMetrics(transcripts: [legacy, current])
        #expect(metrics.total.words == 15)
        #expect(metrics.total.wordsPerMinute == 10)
        let earlier = metrics.applications.first { $0.name == "Earlier activity" }
        #expect(earlier?.totals.words == 5)
        #expect(earlier?.totals.wordsPerMinute == nil)
    }

    @Test func invalidTimingDoesNotProduceInfinitePace() {
        let invalid = Transcript(text: "one two", durationSeconds: .infinity, spokenWordCount: 2)
        let zero = Transcript(text: "three", durationSeconds: 0, spokenWordCount: 1)
        let metrics = UsageMetrics(transcripts: [invalid, zero])
        #expect(metrics.total.words == 3)
        #expect(metrics.total.seconds == 0)
        #expect(metrics.total.wordsPerMinute == nil)
        #expect(UsageMetrics(transcripts: []).total.dictations == 0)
    }
}
