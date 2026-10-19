import Foundation
import SwiftData

/// Behind a protocol so the coordinator can be unit-tested with a fake.
@MainActor
protocol HistoryStoring: AnyObject {
    func save(text: String, duration: Double?, device: String?, spokenWordCount: Int?, applicationName: String?, applicationBundleID: String?)
}

@MainActor
final class HistoryStore: HistoryStoring {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save(text: String, duration: Double?, device: String?, spokenWordCount: Int? = nil,
              applicationName: String? = nil, applicationBundleID: String? = nil) {
        let transcript = Transcript(text: text, durationSeconds: duration, inputDeviceName: device,
                                    spokenWordCount: spokenWordCount, applicationName: applicationName,
                                    applicationBundleID: applicationBundleID)
        context.insert(transcript)
        try? context.save()
    }

    func recent(limit: Int? = nil) -> [Transcript] {
        var descriptor = FetchDescriptor<Transcript>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        return (try? context.fetch(descriptor)) ?? []
    }

    func delete(_ transcript: Transcript) {
        context.delete(transcript)
        try? context.save()
    }

    func clearAll() {
        for transcript in recent() {
            context.delete(transcript)
        }
        try? context.save()
    }
}
