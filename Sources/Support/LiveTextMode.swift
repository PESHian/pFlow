import Foundation

/// What pFlow does with words while the person is still speaking.
/// The labels match the Windows app. "Preview in pFlow" was a third choice
/// until 2026-10-22; Type mode shows the same card whenever it cannot type,
/// so a saved "preview" loads as Type.
enum LiveTextMode: String, CaseIterable, Identifiable {
    case off
    case typeInApp = "type"

    var id: String { rawValue }
    static let defaultsKey = "liveTextMode"

    var title: String {
        switch self {
        case .off: return "Off"
        case .typeInApp: return "Type in the current app"
        }
    }

    /// Live recognition runs for the take (Type).
    var showsPreview: Bool { self != .off }

    /// Whether the take shows the text card or the small waveform capsule.
    /// Type in the current app keeps the capsule for the whole take: the words
    /// belong in the app, not in a pFlow window. Words that could not go in are
    /// offered in the Copy card after the take. The one rule for both platforms.
    func showsCard(typingLive: Bool) -> Bool { false }

    /// Missing or unknown saved values are Off, so existing installs keep
    /// today's behavior until the person picks something else.
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        let raw = defaults.string(forKey: defaultsKey) ?? ""
        if raw == "preview" { return .typeInApp }
        return Self(rawValue: raw) ?? .off
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
