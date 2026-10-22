import AppKit
import ApplicationServices

/// A text field pFlow may type into while a take is spoken. The real one
/// talks to another app through Accessibility; tests use a test-owned field.
@MainActor
protocol LiveTextField: AnyObject {
    func state() -> LiveFieldState
    /// Whether text ranges and text can be set here at all. Checked once at
    /// begin without writing anything.
    func canWriteRanges() -> Bool
    /// Selects `range` and replaces it with `text` through a native
    /// text-range operation, never with keys or the clipboard.
    func replace(_ range: NSRange, with text: String) -> Bool
    func select(_ range: NSRange) -> Bool
}

/// How a take's live typing turned out.
enum LiveInlineStart: Equatable {
    case typing
    case preview(LiveInlineOwnership.Stop)
}

enum LiveInlineFinal: Equatable {
    /// The finished text replaced pFlow's provisional text and was read back.
    case applied
    /// Nothing was typed, so the finished text can be delivered the normal way.
    case notTyped
    /// pFlow could not safely put the finished text in; it stays in History.
    case kept(LiveInlineOwnership.Stop)
}

enum LiveInlineCancel: Equatable {
    case nothingTyped
    case removed
    /// The destination changed, so pFlow left it alone; typed words remain there.
    case left(LiveInlineOwnership.Stop)
}

/// One take's live typing: the ownership rules applied to one real field.
/// Every write happens on the main actor, one at a time, and is read back
/// before the next. The first failure ends typing for the take.
@MainActor
final class LiveInlineSession {
    let id: String
    private let field: LiveTextField
    private var ownership: LiveInlineOwnership

    private init(id: String, field: LiveTextField, ownership: LiveInlineOwnership) {
        self.id = id
        self.field = field
        self.ownership = ownership
    }

    static func begin(id: String, field: LiveTextField) -> Result<LiveInlineSession, LiveInlineOwnership.Stop> {
        let state = field.state()
        let writable = state.selection != nil && field.canWriteRanges()
        return LiveInlineOwnership.begin(state, writable: writable)
            .map { LiveInlineSession(id: id, field: field, ownership: $0) }
    }

    var stopped: LiveInlineOwnership.Stop? { ownership.stopped }
    var touched: Bool { ownership.touched }

    /// Applies the newest transcript. Returns the reason when typing stops now.
    func update(_ transcript: String) -> LiveInlineOwnership.Stop? {
        // Once typing has stopped for the take, the field is not read again.
        guard ownership.stopped == nil else { return nil }
        return perform(ownership.update(transcript: transcript, observed: field.state()))
    }

    func finalize(_ text: String) -> LiveInlineFinal {
        // Nothing of pFlow's is in the field, so the finished text goes in
        // exactly as in Preview mode, whatever stopped the typing.
        if !ownership.touched { return .notTyped }
        if let stop = perform(ownership.finalize(text: text, observed: field.state())) { return .kept(stop) }
        return .applied
    }

    func cancel() -> LiveInlineCancel {
        guard ownership.touched else { return .nothingTyped }
        if let stop = perform(ownership.cancel(observed: field.state())) { return .left(stop) }
        return .removed
    }

    private func perform(_ step: LiveInlineOwnership.Step) -> LiveInlineOwnership.Stop? {
        switch step {
        case .none: return nil
        case .stopped(let stop): return stop
        case .write(let write):
            var accepted = field.replace(write.range, with: write.text)
            if accepted, let select = write.select { accepted = field.select(select) }
            if case .stopped(let stop) = ownership.confirm(accepted: accepted, observed: field.state()) { return stop }
            return nil
        }
    }
}

/// The captured field in another app, through Accessibility.
@MainActor
final class AXLiveTextField: LiveTextField {
    private let pid: pid_t
    private let element: AXUIElement
    private let application: AXUIElement

    init(pid: pid_t, element: AXUIElement) {
        self.pid = pid
        self.element = element
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.3)
        AXUIElementSetMessagingTimeout(element, 0.3)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    func state() -> LiveFieldState {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        var same = false
        if let focused = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            same = CFEqual(focused, element)
        }
        let secure = SecureInput.isEnabled
            || attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
        return LiveFieldState(app: front, element: same ? LiveFieldState.target : "other", secure: secure,
                              trusted: AXIsProcessTrusted(), value: boundedValue(), selection: selection())
    }

    /// The field's text, unless it is too long to read on every update; a
    /// missing value means Preview at begin and a stop during a take.
    private func boundedValue() -> String? {
        if let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int,
           count > LiveInlineOwnership.maxFieldLength { return nil }
        return attribute(element, kAXValueAttribute) as? String
    }

    /// The one selection, or nil when there is none or more than one (several
    /// cursors in a code editor), which pFlow cannot keep track of.
    private func selection() -> NSRange? {
        if let ranges = attribute(element, kAXSelectedTextRangesAttribute) as? [AXValue], ranges.count != 1 { return nil }
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func settable(_ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    func canWriteRanges() -> Bool {
        settable(kAXSelectedTextRangeAttribute) && settable(kAXSelectedTextAttribute)
    }

    func select(_ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func replace(_ range: NSRange, with text: String) -> Bool {
        guard select(range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}

extension LiveInlineOwnership.Stop {
    /// Shown in the preview when typing could not start, so the take is Preview only.
    var previewNote: String {
        switch self {
        case .permission: return "No permission to type"
        case .secure: return "Secure input is on"
        default: return "Can't type in this app"
        }
    }

    /// Shown in the preview when typing stops partway through a take. Short
    /// enough for one line on the narrowest preview.
    var stoppedNote: String {
        switch self {
        case .unsupported, .uncertain: return "Stopped: couldn't check"
        case .permission: return "Stopped: no permission"
        case .app: return "Stopped: app changed"
        case .focus: return "Stopped: field changed"
        case .secure: return "Stopped: password field"
        case .text: return "Stopped: text changed"
        case .caret: return "Stopped: cursor moved"
        }
    }
}

/// Holds at most one take's live typing. A call for any other take is
/// ignored, and finalize or cancel ends the take, so a late or stale call can
/// never write.
@MainActor
struct LiveInlineSlot {
    private var current: LiveInlineSession?

    mutating func begin(id: String, field: LiveTextField?) -> LiveInlineStart {
        current = nil
        guard let field else { return .preview(.unsupported) }
        switch LiveInlineSession.begin(id: id, field: field) {
        case .success(let session):
            current = session
            return .typing
        case .failure(let stop):
            return .preview(stop)
        }
    }

    func reconcile(session: String, transcript: String) -> LiveInlineOwnership.Stop? {
        guard let current, current.id == session else { return nil }
        return current.update(transcript)
    }

    /// pFlow's words may be in the destination for this take.
    func typed(session: String) -> Bool {
        guard let current, current.id == session else { return false }
        return current.touched
    }

    mutating func finalize(session: String, text: String) -> LiveInlineFinal {
        guard let current, current.id == session else { return .notTyped }
        self.current = nil
        return current.finalize(text)
    }

    mutating func cancel(session: String) -> LiveInlineCancel {
        guard let current, current.id == session else { return .nothingTyped }
        self.current = nil
        return current.cancel()
    }
}
