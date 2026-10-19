import Foundation

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case apple, whisper
    var id: String { rawValue }
    var title: String { self == .apple ? "Apple (default)" : "Whisper (local)" }
    static let defaultsKey = "transcriptionEngine"

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .apple
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
