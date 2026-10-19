import Foundation
import SwiftData

@Model
final class Transcript {
    var id: UUID
    var text: String
    var createdAt: Date
    var durationSeconds: Double?
    var inputDeviceName: String?
    var spokenWordCount: Int?
    var applicationName: String?
    var applicationBundleID: String?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = .now,
        durationSeconds: Double? = nil,
        inputDeviceName: String? = nil,
        spokenWordCount: Int? = nil,
        applicationName: String? = nil,
        applicationBundleID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.inputDeviceName = inputDeviceName
        self.spokenWordCount = spokenWordCount
        self.applicationName = applicationName
        self.applicationBundleID = applicationBundleID
    }
}
