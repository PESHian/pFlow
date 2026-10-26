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
    /// Typed keys (KeyLiveTextField): while words come pFlow only adds
    /// characters at the caret after its own words, and a revised word ends
    /// live typing. At the end pFlow's own words are selected (no keys) and the
    /// finished text is pasted over them the checked way.
    var appendOnly: Bool { get }
    /// False while a write cannot be made safely right now (a key the person
    /// holds would change typed characters): the update is skipped.
    var readyToWrite: Bool { get }
    /// Why the last refused write sent nothing, when the field knows.
    var refusal: InsertionBlock? { get }
    /// Ends a selection pFlow made, without a key.
    func collapse()
    /// The person pressed a key or clicked since pFlow selected its words.
    func personActedSinceSelect() -> Bool
}

extension LiveTextField {
    var appendOnly: Bool { false }
    var readyToWrite: Bool { true }
    var refusal: InsertionBlock? { nil }
    func collapse() {}
    func personActedSinceSelect() -> Bool { true }
}

/// How a take's live typing turned out.
enum LiveInlineStart: Equatable {
    case typing
    /// The app was just asked to build its Accessibility tree (Electron,
    /// Chromium); `retryLive` finds the field once it is there.
    case waiting
    case preview(LiveInlineOwnership.Stop)
}

enum LiveInlineFinal: Equatable {
    /// The finished text replaced pFlow's provisional text and was read back.
    case applied
    /// Nothing was typed, so the finished text can be delivered the normal way.
    case notTyped
    /// pFlow's own typed words are selected; the finished text goes over them
    /// through the checked paste (`TextInjecting.insertOverSelection`).
    case replace(OwnedWords)
    /// pFlow could not safely put the finished text in; it stays in History.
    case kept(LiveInlineOwnership.Stop)
    /// The finished text was committed through the input method but could not be read back.
    case unconfirmed
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
    /// One short wait before the field is re-read at the end of a take; tests inject a no-op.
    private let settle: () -> Void
    private var ownership: LiveInlineOwnership

    private init(id: String, field: LiveTextField, ownership: LiveInlineOwnership, settle: @escaping () -> Void) {
        self.id = id
        self.field = field
        self.ownership = ownership
        self.settle = settle
    }

    static let settleWait: UInt32 = 50_000
    /// Re-reads after an accepted write, `settleWait` apart (0.4 s in all),
    /// before a write the field still does not show counts as uncertain.
    static let applyReads = 8

    static func begin(id: String, field: LiveTextField,
                      settle: @escaping () -> Void = { usleep(settleWait) }) -> Result<LiveInlineSession, LiveInlineOwnership.Stop> {
        let state = field.state()
        let writable = state.selection != nil && field.canWriteRanges()
        return LiveInlineOwnership.begin(state, writable: writable)
            .map { LiveInlineSession(id: id, field: field, ownership: $0, settle: settle) }
    }

    var stopped: LiveInlineOwnership.Stop? { ownership.stopped }
    /// An update was skipped because a key was held (typed keys would change).
    private(set) var heldBack = false
    var touched: Bool { ownership.touched }

    /// Applies the newest transcript. Returns the reason when typing stops now.
    func update(_ transcript: String) -> LiveInlineOwnership.Stop? {
        // Once typing has stopped for the take, the field is not read again.
        guard ownership.stopped == nil else { return nil }
        // A key the person holds now: no read, no write; the next update tries again.
        guard field.readyToWrite else {
            if !heldBack { ReasonLog.note("typed live words held back: a key is held") }
            heldBack = true
            return nil
        }
        heldBack = false
        var step = ownership.update(transcript: transcript, observed: field.state())
        // Append only: a write that would change pFlow's own typed words, move
        // the selection or add a line break ends live typing; no key is sent.
        if field.appendOnly, case .write(let write) = step,
           write.range.length > 0 || write.select != nil || write.text.contains(where: \.isNewline) {
            step = ownership.halt(.revised)
        }
        return logged(perform(step))
    }

    /// The reason line when typing stops: the stop and, for a read-back that
    /// differed, its kind.
    private func logged(_ stop: LiveInlineOwnership.Stop?) -> LiveInlineOwnership.Stop? {
        guard let stop else { return nil }
        ReasonLog.note("live typing stopped:", stop)
        if let shape = ownership.mismatch { ReasonLog.note("live typing read-back differed:", shape) }
        return stop
    }

    func finalize(_ text: String) -> LiveInlineFinal {
        // Nothing of pFlow's is in the field, so the finished text goes in
        // exactly as in Preview mode, whatever stopped the typing.
        if confirmNothingTyped() { return .notTyped }
        if field.appendOnly { return finalizeOwnWords(text) }
        if let stop = logged(perform(ownership.finalize(text: text, observed: field.state()))) { return .kept(stop) }
        return .applied
    }

    /// Typed keys: pFlow's own words, exactly as it left them, are selected
    /// without a key and read back for the finished text to go over them.
    private func finalizeOwnWords(_ text: String) -> LiveInlineFinal {
        let now = field.state()
        guard let span = ownership.ownSpan(now) else {
            let stopped = ownership.stopped.flatMap { $0 == .revised ? nil : $0 }
            let stop = stopped ?? ownership.check(now) ?? .uncertain
            ReasonLog.note("own words not found at the end:", stop)
            if stopped == nil, let shape = ReadBackShape.classify(expected: ownership.expectedValue, read: now.value) {
                ReasonLog.note("end read-back differed:", shape)
            }
            return .kept(stop)
        }
        if ownership.finished(text) { return .applied }
        guard field.select(span) else {
            ReasonLog.note("own words could not be selected at the end")
            field.collapse()
            return .kept(.uncertain)
        }
        let words = ((now.value ?? "") as NSString).substring(with: span)
        let field = self.field
        return .replace(OwnedWords(range: span, text: words,
                                   personActed: { field.personActedSinceSelect() },
                                   collapse: { field.collapse() }))
    }

    func cancel() -> LiveInlineCancel {
        if confirmNothingTyped() { return .nothingTyped }
        // Append only: what pFlow typed is never taken back out with keys.
        if field.appendOnly { return .left(.revised) }
        if let stop = perform(ownership.cancel(observed: field.state())) { return .left(stop) }
        return .removed
    }

    private func stop(_ step: LiveInlineOwnership.Step) -> LiveInlineOwnership.Stop? {
        if case .stopped(let stop) = step { return stop }
        return nil
    }

    private func perform(_ step: LiveInlineOwnership.Step) -> LiveInlineOwnership.Stop? {
        switch step {
        case .none: return nil
        case .stopped(let stop): return stop
        case .write(let write):
            var accepted = field.replace(write.range, with: write.text)
            // The field refused before sending anything (the guard): typing
            // stops for that reason, and nothing of this write is in the field.
            if !accepted, let refusal = field.refusal { return stop(ownership.halt(LiveInlineOwnership.Stop(refusal))) }
            if accepted, let select = write.select { accepted = field.select(select) }
            var state = field.state()
            // Chromium and Electron apply an accepted write a moment later:
            // read again, a few short waits at most, until the field shows it.
            // Native fields show it on the first read and never wait.
            var reads = 0
            while accepted, reads < Self.applyReads, !ownership.applied(state) {
                settle()
                state = field.state()
                reads += 1
            }
            if case .stopped(let stop) = ownership.confirm(accepted: accepted, observed: state) { return stop }
            return nil
        }
    }

    /// Before deciding that nothing was typed, give the field one short
    /// moment (a refused Accessibility write can still land late) and read
    /// it once more; any difference from its snapshot means it was touched.
    private func confirmNothingTyped() -> Bool {
        guard !ownership.touched else { return false }
        settle()
        ownership.noteFieldChanged(field.state())
        return !ownership.touched
    }
}

/// The captured field in another app, through Accessibility.
@MainActor
final class AXLiveTextField: LiveTextField {
    private let pid: pid_t
    private let element: AXUIElement
    private let application: AXUIElement
    /// Browsers show a typed space at a line end as a no-break space: read as a space.
    private let plainSpaces: Bool
    /// The field held only a placeholder when the take began (EditorPlaceholder):
    /// it is read and selected as an empty field would be.
    private let placeholder: EditorPlaceholder.Start?

    private let bundleID: String?

    init(pid: pid_t, element: AXUIElement, plainSpaces: Bool = false, bundleID: String? = nil,
         placeholder: EditorPlaceholder.Start? = nil) {
        self.pid = pid
        self.element = element
        self.plainSpaces = plainSpaces
        self.placeholder = placeholder
        self.bundleID = bundleID
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
        if let focused = FocusedElement.of(pid: pid, bundleID: bundleID) {
            same = CFEqual(focused, element)
        }
        let secure = SecureInput.isEnabled
            || attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
        let state = LiveFieldState(app: front, element: same ? LiveFieldState.target : "other", secure: secure,
                                   trusted: AXIsProcessTrusted(), value: boundedValue(), selection: selection())
        guard let placeholder else { return state }
        return EditorPlaceholder.seen(state, placeholderText: placeholder.text)
    }

    /// The field's text, unless it is too long to read on every update; a
    /// missing value means Preview at begin and a stop during a take.
    private func boundedValue() -> String? {
        if let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int,
           count > LiveInlineOwnership.maxFieldLength { return nil }
        let value = attribute(element, kAXValueAttribute) as? String
        return plainSpaces ? value?.replacingOccurrences(of: "\u{00A0}", with: " ") : value
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

    /// pFlow can select a range here (the end replace of typed keys).
    func selectionSettable() -> Bool { settable(kAXSelectedTextRangeAttribute) }

    func select(_ range: NSRange) -> Bool {
        let range = placeholder.map { EditorPlaceholder.fieldRange(range, raw: boundedValue(), placeholderText: $0.text) } ?? range
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func replace(_ range: NSRange, with text: String) -> Bool {
        // A direct write goes to the field's own positions only, never through a placeholder view.
        guard placeholder == nil, select(range) else { return false }
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

    /// The one plain line on the Copy card when the finished text could not
    /// go in after live typing: the real reason, never a generic one.
    var cardReason: String {
        switch self {
        case .permission: return "Accessibility is off, so the finished text was not put in."
        case .app: return "You switched apps, so the finished text was not put in."
        case .focus: return "You moved to another field, so the finished text was not put in."
        case .secure: return "A password field or secure typing was on, so the finished text was not put in."
        case .text: return "The text in the field changed, so the finished text was not put in."
        case .caret: return "The cursor moved, so the finished text was not put in."
        case .unsupported, .uncertain, .revised: return "pFlow could not check this field, so the finished text was not put in."
        case .otherWindow: return "Your words may have gone to another window."
        }
    }

    /// Shown in the preview when typing stops partway through a take. Short
    /// enough for one line on the narrowest preview.
    var stoppedNote: String {
        switch self {
        case .unsupported, .uncertain: return "Stopped: couldn't check"
        case .revised: return "Stopped: words changed"
        case .permission: return "Stopped: no permission"
        case .app: return "Stopped: app changed"
        case .focus: return "Stopped: field changed"
        case .secure: return "Stopped: password field"
        case .text: return "Stopped: text changed"
        case .caret: return "Stopped: cursor moved"
        case .otherWindow: return "Stopped: another window"
        }
    }
}

/// Holds at most one take's live typing. A call for any other take is
/// ignored, and finalize or cancel ends the take, so a late or stale call can
/// never write.
@MainActor
struct LiveInlineSlot {
    private var current: LiveInlineSession?
    /// The one short wait before a take's final re-read; tests inject a no-op.
    var settle: () -> Void = { usleep(LiveInlineSession.settleWait) }

    mutating func begin(id: String, field: LiveTextField?) -> LiveInlineStart {
        current = nil
        guard let field else { return .preview(.unsupported) }
        switch LiveInlineSession.begin(id: id, field: field, settle: settle) {
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

    func heldBack(session: String) -> Bool {
        guard let current, current.id == session else { return false }
        return current.heldBack
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

extension LiveInlineOwnership.Stop {
    /// The stop for a guard refusal before any key went out.
    init(_ block: InsertionBlock) {
        switch block {
        case .appChanged: self = .app
        case .fieldChanged: self = .focus
        case .passwordField, .secureInput: self = .secure
        case .accessibilityOff: self = .permission
        default: self = .uncertain
        }
    }
}
