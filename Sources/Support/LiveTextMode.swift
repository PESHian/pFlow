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

    /// Typing into the app also shows the preview, which says when typing is
    /// not possible or has stopped and the take continues as Preview.
    var showsPreview: Bool { self != .off }

    /// Missing or unknown saved values are Off, so existing installs keep
    /// today's behavior until the person picks something else.
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .off
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
