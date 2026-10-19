import SwiftUI
import SwiftData
import Charts

struct StatisticsView: View {
    @Query(sort: \Transcript.createdAt, order: .reverse) private var transcripts: [Transcript]
    var onBack: () -> Void

    var body: some View {
        let metrics = UsageMetrics(transcripts: transcripts)
        VStack(spacing: 0) {
            PageHeader(title: "Usage statistics", onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s5) {
                    HStack(spacing: Theme.s4) {
                        metric("Words dictated", value: metrics.total.words.formatted())
                        metric("Dictations", value: metrics.total.dictations.formatted())
                        metric("Time tracked", value: time(metrics.total.seconds))
                        metric("WPM tracked", value: pace(metrics.total))
                    }
                    SectionLabel("Daily activity")
                    if metrics.days.isEmpty {
                        Text("Your first dictation will appear here.").foregroundStyle(.secondary)
                    } else {
                        Chart(metrics.recentDays()) { day in
                            BarMark(x: .value("Day", day.id.formatted(.dateTime.month(.abbreviated).day())),
                                    y: .value("Words", day.totals.words), width: .fixed(20))
                                .foregroundStyle(Theme.gradient)
                                .cornerRadius(3)
                                .annotation(position: .top) {
                                    if day.totals.words > 0 {
                                        Text(day.totals.words.formatted()).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }
                        }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 9)) } }
                        .frame(height: 145)
                        Text("Last 7 calendar days · words per day").font(.caption).foregroundStyle(.secondary)
                        if metrics.total.timedWords < metrics.total.words {
                            Text("Speaking pace uses \(metrics.total.timedWords.formatted()) words with recorded timing. Earlier word totals have no reliable timing.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        columns
                        ForEach(metrics.days.prefix(30)) { day in
                            row(day.id.formatted(date: .abbreviated, time: .omitted), totals: day.totals)
                        }
                        Text("Most recent 30 active days").font(.caption).foregroundStyle(.secondary)
                    }
                    SectionLabel("By app · all time")
                    columns
                    ForEach(metrics.applications) { application in
                        row(application.name, totals: application.totals)
                    }
                    Text("App and speaking-time tracking start with this update. Older word totals use saved text. Speaking pace includes pauses while recording, and excludes processing time.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Stored only on this Mac. Clearing history also clears these statistics.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(Theme.s5)
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 21, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: some View {
        HStack {
            Text("Day / app").frame(maxWidth: .infinity, alignment: .leading)
            Text("Words").frame(width: 65, alignment: .trailing)
            Text("Time").frame(width: 75, alignment: .trailing)
            Text("WPM").frame(width: 50, alignment: .trailing)
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func row(_ name: String, totals: UsageTotals) -> some View {
        HStack {
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(totals.words.formatted()).frame(width: 65, alignment: .trailing)
            Text(time(totals.seconds)).frame(width: 75, alignment: .trailing)
            Text(pace(totals)).frame(width: 50, alignment: .trailing)
        }.font(.system(size: 12)).monospacedDigit()
    }

    private func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        let minutes = Int(seconds / 60)
        if minutes == 0 { return "\(Int(seconds))s" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m \(Int(seconds) % 60)s"
    }

    private func pace(_ totals: UsageTotals) -> String {
        totals.wordsPerMinute.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
    }
}
