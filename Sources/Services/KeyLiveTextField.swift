import AppKit
import ApplicationServices

/// Reads, from another app, everything `InsertionGuard` decides on. The slow
/// Accessibility reads come first; the fast checks (front app, Secure Input,
/// keys and buttons held, input method, the person's own input) come last, so
/// nothing slow sits between them and the keys pFlow then sends.
@MainActor
struct TargetCheck {
    let pid: pid_t
    /// The captured field; nil when the app has no field pFlow could read
    /// (the focused element then only has to stay a non-password one).
    let element: AXUIElement?
    let bundleID: String?

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// The focused element of the app right now.
    func focused() -> AXUIElement? { FocusedElement.of(pid: pid, bundleID: bundleID) }

    /// The web classes of an element (Chromium and Electron), e.g. xterm.js's input box.
    func classes(_ element: AXUIElement) -> [String] {
        (attribute(element, "AXDOMClassList") as? [String]) ?? []
    }

    /// The app that has the keyboard, asked of the system (not a cached notification).
    private func keyboardAppPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        guard let value = attribute(system, kAXFocusedApplicationAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil
    }

    /// Everything the guard needs, with the person's input counted from `since`.
    func facts(since: UInt64) -> InsertionFacts {
        var facts = InsertionFacts()
        let now = focused()
        if let element {
            facts.sameField = now.map { CFEqual($0, element) } ?? false
        }
        if let now {
            facts.password = attribute(now, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole
            facts.place = NoTypePlaces.place(bundleID: bundleID, elementClasses: classes(now))
        } else {
            facts.place = NoTypePlaces.place(bundleID: bundleID, elementClasses: [])
        }
        let keyboardApp = keyboardAppPID()
        // The fast checks, last.
        let front = NSWorkspace.shared.frontmostApplication
        facts.sameApp = keyboardApp.map { $0 == pid } ?? true && front?.processIdentifier == pid
        facts.secureInput = SecureInput.isEnabled
        facts.modifiersHeld = PersonInput.modifiersHeld()
        facts.keyDown = PersonInput.somethingHeld()
        facts.composing = InputComposition.composing(markedText: false, inputMethod: PersonInput.inputMethodSelected(),
                                                     uncommittedKeys: PersonInput.shared.uncommittedKeys)
        facts.personActed = PersonInput.shared.acted(since: since) ?? false
        return facts
    }
}

/// A field in an app that does not apply Accessibility writes (Chrome,
/// Electron apps, Word, LibreOffice) but can be read: live words go in as
/// typed characters, the way a person's typing would. Append only while words
/// come: pFlow only ever adds settled words at the caret right after its own
/// words; it never presses Delete, Shift or an arrow and never revises what it
/// typed. A revised word ends live typing for the take. At the end pFlow's own
/// words are selected through Accessibility (no keys), read back, and the
/// finished text is pasted over them the checked way
/// (`TextInjector.insertOverSelection`); any doubt ends the selection again
/// without a key and offers the finished text on the Copy card. Every batch of
/// keys goes out only right after `InsertionGuard` passes.
@MainActor
final class KeyLiveTextField: LiveTextField {
    private let reader: AXLiveTextField
    private let check: TargetCheck
    private var aborted = false
    private var selectedAt: UInt64?
    private(set) var refusal: InsertionBlock?

    init(pid: pid_t, element: AXUIElement, bundleID: String?) {
        reader = AXLiveTextField(pid: pid, element: element, plainSpaces: true, bundleID: bundleID)
        check = TargetCheck(pid: pid, element: element, bundleID: bundleID)
    }

    var appendOnly: Bool { true }

    /// A key or modifier held now would change the typed characters; the
    /// update waits for the next one.
    var readyToWrite: Bool { !PersonInput.modifiersHeld() && !PersonInput.somethingHeld() }

    func state() -> LiveFieldState { reader.state() }

    /// Typed keys need a readable caret and, for the end replace, a selection
    /// pFlow can set. Never while an input method that composes is selected:
    /// it could turn typed characters into a composition.
    func canWriteRanges() -> Bool {
        guard !PersonInput.inputMethodSelected() else { return false }
        return reader.selectionSettable()
    }

    /// Adds `text` at the caret, which must be right after pFlow's own words
    /// (`range` is empty and there). Anything else sends no key and returns false.
    func replace(_ range: NSRange, with text: String) -> Bool {
        guard !aborted, range.length == 0, !text.isEmpty, !text.contains(where: \.isNewline) else { return false }
        let now = reader.state()
        guard now.element == LiveFieldState.target, let value = now.value,
              now.selection == NSRange(location: range.location, length: 0),
              range.location <= (value as NSString).length else { return false }
        let expected = (value as NSString).replacingCharacters(in: range, with: text)
        let started = PersonInput.now()
        if let block = InsertionGuard.block(check.facts(since: started)) {
            aborted = true
            refusal = block
            NSLog("pFlow: live typing stopped before a key went out: \(block)")
            return false
        }
        SyntheticKeys.type(text)
        let caret = NSRange(location: range.location + text.utf16.count, length: 0)
        return Self.until(milliseconds: 800 + 15 * text.utf16.count) {
            let state = reader.state()
            return state.value.map { Self.plain($0) == Self.plain(expected) } == true && state.selection == caret
        }
    }

    /// An empty range only checks the caret. pFlow's own words at the end of a
    /// take: selected through Accessibility (no keys) only while the guard
    /// passes, then read back; any doubt ends the selection again.
    func select(_ range: NSRange) -> Bool {
        if range.length == 0 { return Self.until(milliseconds: 300) { reader.state().selection == range } }
        guard !aborted else { return false }
        let started = PersonInput.now()
        if let block = InsertionGuard.block(check.facts(since: started)) {
            NSLog("pFlow: pFlow's words were not selected: \(block)")
            return false
        }
        let before = reader.state().value
        selectedAt = started
        #if DEBUG
        Self.lastOwnSelect = started
        #endif
        guard reader.select(range) else { collapse(); return false }
        if Self.until(milliseconds: 500, { let state = reader.state(); return state.selection == range && state.value == before }) { return true }
        collapse()
        return false
    }

    /// Ends pFlow's selection at its end without a key, only while the field
    /// still has the focus in the app in front; a field the person left is
    /// left alone.
    func collapse() {
        let state = reader.state()
        guard state.element == LiveFieldState.target, state.app == check.pid,
              let selection = state.selection, selection.length > 0 else { return }
        _ = reader.select(NSRange(location: NSMaxRange(selection), length: 0))
    }

    /// True when the person pressed a key or clicked since the select, or
    /// when nothing was watching (nobody can say they did not).
    #if DEBUG
    /// Self-test: when pFlow last selected its own words.
    static var lastOwnSelect: UInt64 = 0
    #endif

    func personActedSinceSelect() -> Bool {
        guard let selectedAt else { return true }
        return PersonInput.shared.acted(since: selectedAt) ?? true
    }

    /// A browser shows a typed space at a line end as a no-break space.
    private static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{00A0}", with: " ") }

    /// Waits for the app to show a write, reading again every 10 ms.
    private static func until(milliseconds: Int, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while true {
            if done() { return true }
            if Date() > deadline { return false }
            usleep(10_000)
        }
    }
}
