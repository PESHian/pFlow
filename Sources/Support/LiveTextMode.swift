import Foundation

/// What pFlow does with words while the person is still speaking.
/// The labels match the Windows app.
enum LiveTextMode: String, CaseIterable, Identifiable {
    case off
    case preview
    case typeInApp = "type"

    var id: String { rawValue }
    static let defaultsKey = "liveTextMode"

    var title: String {
        switch self {
        case .off: return "Off"
        case .preview: return "Preview in pFlow"
        case .typeInApp: return "Type in the current app"
        }
    }

    /// Live recognition runs for the take (Preview and Type).
    var showsPreview: Bool { self != .off }

    /// Whether the take shows the text card or the small waveform capsule.
    /// Type mode shows the capsule while pFlow is typing in the app: the words
    /// are already on screen there. The card appears only when typing could
    /// not start or has stopped, with its note. The one rule for both looks.
    func showsCard(typingLive: Bool) -> Bool {
        switch self {
        case .off: return false
        case .preview: return true
        case .typeInApp: return !typingLive
        }
    }

    /// Missing or unknown saved values are Off, so existing installs keep
    /// today's behavior until the person picks something else.
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .off
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
