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

/// Where History lives. The file SwiftData opens by default is never moved, copied or changed
/// here; when it cannot be opened (a damaged file, another app's schema in the same default file),
/// pFlow still starts, with History kept in memory for this launch only.
enum HistoryContainer {
    static let unavailableNote = "pFlow couldn't open your History file this time, so new takes are kept only until pFlow quits. Your earlier History file is left as it was."

    static func make(open: () throws -> ModelContainer = { try ModelContainer(for: Transcript.self) })
        -> (container: ModelContainer, unavailable: Bool) {
        do {
            return (try open(), false)
        } catch {
            NSLog("pFlow: History file could not be opened, History is in memory for this launch: \(error)")
            // An in-memory store cannot fail for want of a file.
            let memory = try! ModelContainer(for: Transcript.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            return (memory, true)
        }
    }
}
