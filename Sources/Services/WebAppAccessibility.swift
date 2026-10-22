import AppKit
import ApplicationServices

/// Electron and Chromium apps build their Accessibility tree only once an
/// assistive client asks for it. Until then their focused element is a bare
/// group: no text, no selection, nothing settable, so Type mode could not
/// start in T3 Code, VS Code, Slack or Chrome and showed the card instead.
/// Asking is one attribute on the application element. Electron documents
/// `AXManualAccessibility` for exactly this; Chromium browsers take
/// `AXEnhancedUserInterface`, the flag VoiceOver sets. The tree arrives a
/// moment later, so the caller looks for the field again after asking.
@MainActor
enum WebAppAccessibility {
    enum Kind: Equatable { case electron, chromium }

    static let electronAttribute = "AXManualAccessibility"
    static let chromiumAttribute = "AXEnhancedUserInterface"

    /// Frameworks that mark an Electron or Chromium app. Electron is checked
    /// first: it bundles its own Chromium, and its flag has none of the AppKit
    /// side effects the VoiceOver flag can have (animated window moves).
    static func kind(frameworks: [String]) -> Kind? {
        if frameworks.contains("Electron Framework.framework") { return .electron }
        let chromium = ["Google Chrome Framework.framework", "Chromium Framework.framework",
                        "Microsoft Edge Framework.framework", "Brave Browser Framework.framework",
                        "Vivaldi Framework.framework", "Opera Framework.framework"]
        return frameworks.contains(where: chromium.contains) ? .chromium : nil
    }

    static func kind(of app: NSRunningApplication) -> Kind? {
        guard let url = app.bundleURL else { return nil }
        let frameworks = url.appendingPathComponent("Contents/Frameworks").path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks) else { return nil }
        return kind(frameworks: names)
    }

    static func attribute(for kind: Kind) -> String {
        kind == .electron ? electronAttribute : chromiumAttribute
    }

    /// A process is asked again only after this long, so an app that keeps
    /// focus on something that is not text does not make every take wait.
    static let askAgainAfter: TimeInterval = 10
    private static var asked: [pid_t: TimeInterval] = [:]

    /// Whether to ask this process now; records the ask.
    static func dueToAsk(pid: pid_t, now: TimeInterval) -> Bool {
        if let last = asked[pid], now - last < askAgainAfter { return false }
        asked[pid] = now
        return true
    }

    /// Asks the app to build its tree. True when it is an app that builds one
    /// on request and was asked now; false for every other app, and for a
    /// process asked a moment ago. The app's answer to the set is not trusted
    /// either way: Electron enables the tree and then lets AppKit refuse the
    /// unknown attribute.
    @discardableResult
    static func enable(_ app: NSRunningApplication, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let kind = kind(of: app), dueToAsk(pid: app.processIdentifier, now: now) else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let result = AXUIElementSetAttributeValue(element, attribute(for: kind) as CFString, kCFBooleanTrue)
        if result != .success {
            NSLog("pFlow: \(app.localizedName ?? "the app") answered \(result.rawValue) to \(attribute(for: kind))")
        }
        return true
    }
}
