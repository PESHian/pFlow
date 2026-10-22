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
    /// Type mode shows the capsule while pFlow is typing in the app, or is
    /// about to once the app has built its Accessibility tree: the words are
    /// on screen there. The card appears only when typing could not start or
    /// has stopped, with its note. The one rule for both looks.
    func showsCard(typingLive: Bool) -> Bool {
        switch self {
        case .off: return false
        case .typeInApp: return !typingLive
        }
    }

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
