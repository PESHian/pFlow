import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ApplicationServices

/// Why the finished text was not put in. Named on the Copy card, in plain
/// words, so the person never sees a generic "saved in History" for a cause
/// they could fix (Accessibility off, another window in front).
enum InsertionBlock: Equatable {
    /// This build is not trusted for Accessibility: no typing, no paste.
    case accessibilityOff
    case secureInput
    case appChanged
    case fieldChanged
    case textChanged
    case caretMoved
    /// A key was still held when the paste was due.
    case interrupted
    /// The take was cancelled while the paste was waiting.
    case cancelled
    case clipboard
    case nothingToInsert
    case terminal
    case remoteViewer
    case passwordField
    /// The person pressed a key or clicked right when the text was due.
    case personActed
    case inputMethod
    /// The paste went out and the field still reads exactly as before.
    case notTaken
    /// The end replace: pFlow's selected words were no longer exactly its own.
    case selectionChanged
    /// The person's key presses and clicks could not be watched.
    case notWatching
    /// Live typing wrote into the field and then stopped for this reason.
    case typingStopped(LiveInlineOwnership.Stop)

    var reason: String {
        switch self {
        case .accessibilityOff: return "Accessibility is off, so pFlow could not put the text in."
        case .secureInput: return "Another app is blocking keystrokes, so the text was not put in."
        case .appChanged: return "You switched windows, so the text was not put in."
        case .fieldChanged: return "Can't reach this field, so the text was not put in."
        case .textChanged: return "The text in the field changed, so the words were not put in."
        case .caretMoved: return "The cursor moved, so the text was not put in."
        case .interrupted: return "A key was still held down, so the text was not put in."
        case .cancelled: return "The take was cancelled before the text could go in."
        case .clipboard: return "The clipboard could not be used, so the text was not put in."
        case .nothingToInsert: return "There was no text to put in."
        case .terminal: return "pFlow does not type into terminals, where a line break would run a command."
        case .remoteViewer: return "pFlow does not type into remote desktop or virtual machine windows."
        case .passwordField: return "That is a password field, so the text was not put in."
        case .personActed: return "You were typing or clicking, so the text was not put in."
        case .inputMethod: return "Your input method was still composing, so the text was not put in."
        case .notTaken: return "The app did not take the text."
        case .selectionChanged: return "The words in the app changed, so the finished text was not put in."
        case .notWatching: return "pFlow could not watch the keyboard, so the finished text was not put in."
        case .typingStopped(let stop): return stop.cardReason
        }
    }
}

enum InjectionOutcome: Equatable {
    case pasted
    case unconfirmed
    case leftOnClipboard
    case savedToHistory(InsertionBlock)
    /// Another app holds Secure Event Input, which blocks synthetic keystrokes.
    case blockedBySecureInput(String?)
}

@MainActor
protocol TextInjecting {
    var targetApplicationName: String? { get }
    var targetApplicationBundleID: String? { get }
    /// Records which app to paste into. Called the moment recording starts,
    /// before any Yap UI appears, so the target can't be mistaken for our own HUD.
    func captureTarget()
    func deliver(_ text: String) async -> InjectionOutcome
    func deliver(_ text: String, formatted: NSAttributedString?) async -> InjectionOutcome
    /// The captured field is a password field. Dictation does not start there.
    var targetIsSecure: Bool { get }
    /// This build is trusted for Accessibility right now (never cached: a
    /// grant made between two takes counts for the next one).
    var accessibilityGranted: Bool { get }

    // Live typing ("Type in the current app") for one take. `beginLive` uses
    // the field captured by `captureTarget`, so it runs right after it,
    // before any pFlow UI. The final-only `deliver` above is unchanged and is
    // what Off and Preview use.
    func beginLive(session: String) -> LiveInlineStart
    /// After `beginLive` returned `.waiting`: the same check over the field
    /// the app reports now. `.waiting` again while there is still nothing.
    func retryLive(session: String) -> LiveInlineStart
    /// Returns the reason when live typing stops with this update.
    func reconcileLive(session: String, transcript: String) -> LiveInlineOwnership.Stop?
    /// pFlow's words may be in the destination for this take.
    func typedLive(session: String) -> Bool
    func finalizeLive(session: String, text: String) -> LiveInlineFinal
    func cancelLive(session: String) -> LiveInlineCancel
    /// Waits (bounded) for held keys to be released, before the end of a take.
    func waitForKeysToClear() async
    /// After `finalizeLive` returned `.replace`: the finished text over pFlow's
    /// own selected words, through the checked paste.
    func insertOverSelection(_ text: String, own: OwnedWords, formatted: NSAttributedString?) async -> InjectionOutcome
    /// Live words through pFlow Dictation (the input method): the finished
    /// text committed once over the marked words and read back. Nil when the
    /// take did not use the input method.
    func finishInputMethod(session: String, text: String) async -> LiveInlineFinal?
    /// A held key kept this update's typed words out; the words belong in pFlow's own preview.
    func liveHeldBack(session: String) -> Bool
    /// The take ends before live words started (still waiting): anything begun is undone.
    func abandonLive(session: String)
}

extension TextInjecting {
    func finishInputMethod(session: String, text: String) async -> LiveInlineFinal? { nil }
    func liveHeldBack(session: String) -> Bool { false }
    func abandonLive(session: String) {}
    func deliver(_ text: String, formatted: NSAttributedString?) async -> InjectionOutcome { await deliver(text) }
    var targetIsSecure: Bool { false }
    var accessibilityGranted: Bool { true }
    func beginLive(session: String) -> LiveInlineStart { .preview(.unsupported) }
    func retryLive(session: String) -> LiveInlineStart { .preview(.unsupported) }
    func reconcileLive(session: String, transcript: String) -> LiveInlineOwnership.Stop? { nil }
    func typedLive(session: String) -> Bool { false }
    func finalizeLive(session: String, text: String) -> LiveInlineFinal { .notTyped }
    func cancelLive(session: String) -> LiveInlineCancel { .nothingTyped }
    func waitForKeysToClear() async {}
    func insertOverSelection(_ text: String, own: OwnedWords, formatted: NSAttributedString?) async -> InjectionOutcome {
        own.collapse()
        return .savedToHistory(.selectionChanged)
    }
}

@MainActor
final class TextInjector: TextInjecting {
    var copyToClipboard: () -> Bool = { false }
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var targetApplicationName: String? { targetApp?.localizedName }
    var targetApplicationBundleID: String? { targetApp?.bundleIdentifier }
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    private static let sessionType = PasteboardSnapshot.sessionType
    /// nspasteboard.org markers: clipboard managers and history tools skip
    /// pFlow's own writes (transient: about to be replaced; concealed: private).
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private var targetApp: NSRunningApplication?
    private var targetField: AXUIElement?
    private var originalValue: String?
    /// The field held only an empty editor's placeholder when the take began (EditorPlaceholder).
    private var placeholder: EditorPlaceholder.Start?
    private var placeholderStart: Bool { placeholder != nil }
    private var fieldUnreadable = false
    private var composition: (composing: Bool, at: UInt64) = (false, 0)
    private var originalSelection: CFRange?
    private(set) var targetIsSecure = false
    private var delivering = false
    private var live = LiveInlineSlot()
    /// The take using pFlow Dictation, while it does.
    private var inputMethodTake: String?
    private var inputMethodStarted: UInt64 = 0
    private var inputMethodStopped: LiveInlineOwnership.Stop?
    /// Cleared for the take once the input method could not be used.
    private var inputMethodAllowed = true
    var inputMethod: InputMethodLink { InputMethodLink.shared }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func focusedField(_ app: NSRunningApplication) -> AXUIElement? {
        FocusedElement.of(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    private func selection(_ field: AXUIElement) -> CFRange? {
        guard let raw = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    /// The first reason the captured target is no longer where the text can
    /// go, or nil while it is.
    private func targetBlock() -> InsertionBlock? {
        guard let targetApp, targetApp.isActive else { return .appChanged }
        guard let targetField else { return nil }
        guard let focused = focusedField(targetApp), CFEqual(focused, targetField),
              attribute(focused, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return .fieldChanged }
        if let originalValue, attribute(focused, kAXValueAttribute) as? String != originalValue { return .textChanged }
        if let originalSelection {
            guard let current = selection(focused), current.location == originalSelection.location,
                  current.length == originalSelection.length else { return .caretMoved }
        }
        return nil
    }

    private func targetUnchanged() -> Bool { targetBlock() == nil }

    func captureTarget() {
        guard !delivering else { return }
        inputMethod.end()
        inputMethodTake = nil
        inputMethodStopped = nil
        inputMethodAllowed = true
        targetApp = NSWorkspace.shared.frontmostApplication
        PersonInput.shared.start()
        // Whether the person was composing when the take started: the end of
        // the take refuses until a real commit is seen, whatever the time.
        composition = PersonInput.shared.compositionSnapshot(sourceID: PersonInput.selectedInputMethodID())
        captureField()
    }

    /// The focused field of the captured app and what it holds, so a paste
    /// later can tell whether anything changed.
    private func captureField() {
        targetField = targetApp.flatMap(focusedField)
        // A field whose text Accessibility does not show is treated as unreadable.
        fieldUnreadable = targetField.map(FocusedElement.unreadable) ?? false
        originalValue = fieldUnreadable ? nil : targetField.flatMap { attribute($0, kAXValueAttribute) as? String }
        originalSelection = targetField.flatMap(selection)
        placeholder = targetField.flatMap { field in
            EditorPlaceholder.start(value: originalValue, placeholderText: attribute(field, "AXPlaceholderValue") as? String,
                                    markedEmpty: markedEmpty(field), webContent: isWebContent(field))
        }
        targetIsSecure = targetField.map { attribute($0, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole } ?? false
    }

    /// The field is web content: a Chromium or Electron app, or a page's web area (Safari).
    private func isWebContent(_ field: AXUIElement) -> Bool {
        targetApp.map { WebAppAccessibility.kind(of: $0) != nil } == true || FocusedElement.inWebArea(field)
    }

    /// The editor marks itself empty (EditorPlaceholder.emptyEditorClasses), on
    /// the field or one of its first few descendants (a web page's own classes).
    private func markedEmpty(_ field: AXUIElement) -> Bool {
        var queue = [(field, 0)], seen = 0
        while !queue.isEmpty, seen < 12 {
            let (element, depth) = queue.removeFirst()
            seen += 1
            if let classes = attribute(element, "AXDOMClassList") as? [String],
               classes.contains(where: EditorPlaceholder.emptyEditorClasses.contains) { return true }
            if depth < 3, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue += children.prefix(4).map { ($0, depth + 1) }
            }
        }
        return false
    }

    /// Live words by Accessibility range writes in native text views, by typed
    /// keys where those writes do not show (LiveFieldMethod), or by keys in a
    /// native field that takes no range writes but can be read. Never in a
    /// terminal or a remote viewer.
    /// pFlow Dictation, when the person has added it: marked text through the
    /// text input client, no keys, so a held Command key changes nothing.
    /// Never for a password field or Secure Input, a terminal or remote
    /// viewer, or while another input method is composing.
    private func beginInputMethod(session: String) -> LiveInlineStart? {
        guard !delivering, inputMethodAllowed, let targetApp, let bundle = targetApp.bundleIdentifier else { return nil }
        guard inputMethod.usable else {
            ReasonLog.note(inputMethod.connected ? "input method not added in Keyboard settings" : "input method not connected")
            return nil
        }
        let classes = targetField.map { TargetCheck(pid: targetApp.processIdentifier, element: $0, bundleID: bundle).classes($0) } ?? []
        let composing = InputComposition.composing(markedLength: targetField.flatMap(FocusedElement.markedLength),
                                                   tracked: composition.composing)
        guard InputMethodRoute.allowed(secure: targetIsSecure || SecureInput.isEnabled,
                                       place: NoTypePlaces.place(bundleID: bundle, elementClasses: classes), composing: composing) else {
            ReasonLog.note("input method not used: secure field, terminal, remote viewer or open composition")
            inputMethodAllowed = false
            return nil
        }
        guard inputMethod.begin(id: session, bundle: bundle) else {
            ReasonLog.note("input method could not be selected")
            inputMethodAllowed = false
            return nil
        }
        inputMethodTake = session
        inputMethodStarted = PersonInput.now()
        ReasonLog.note("live words by the input method")
        return .waiting
    }

    private func beginLiveOverCapturedField(session: String) -> LiveInlineStart {
        if let started = beginInputMethod(session: session) { return started }
        guard !delivering, let targetApp, let targetField else {
            ReasonLog.note("live typing not started: no field found")
            return live.begin(id: session, field: nil)
        }
        let pid = targetApp.processIdentifier, bundleID = targetApp.bundleIdentifier
        let check = TargetCheck(pid: pid, element: targetField, bundleID: bundleID)
        // Never in a terminal or a remote viewer, nor while an input method may be composing.
        let composing = InputComposition.composing(markedLength: FocusedElement.markedLength(targetField),
                                                   tracked: composition.composing)
        guard !composing else {
            ReasonLog.note("live typing not started:", InsertionBlock.inputMethod)
            return live.begin(id: session, field: nil)
        }
        if let place = NoTypePlaces.place(bundleID: bundleID, elementClasses: check.classes(targetField)) {
            ReasonLog.note("live typing not started:", place)
            return live.begin(id: session, field: nil)
        }
        guard !fieldUnreadable else {
            ReasonLog.note("live typing not started: the field's text cannot be read")
            return live.begin(id: session, field: nil)
        }
        if placeholderStart { ReasonLog.note("the field holds only an empty editor's placeholder") }
        let composition = self.composition, placeholder = self.placeholder
        let keys = { KeyLiveTextField(pid: pid, element: targetField, bundleID: bundleID, composition: composition,
                                      placeholder: placeholder) }
        let web = isWebContent(targetField)
        switch LiveFieldMethod.method(webApp: web, bundleID: bundleID) {
        case .keys:
            ReasonLog.note("live words by typed keys")
            return beginLive(session: session, field: keys())
        case .ranges:
            ReasonLog.note("live words by Accessibility range writes")
            // Direct writes go to the captured caret and never through a placeholder view.
            let start = beginLive(session: session, field: AXLiveTextField(pid: pid, element: targetField, bundleID: bundleID))
            return start == .preview(.unsupported) ? beginLive(session: session, field: keys()) : start
        }
    }

    func beginLive(session: String) -> LiveInlineStart {
        let start = beginLiveOverCapturedField(session: session)
        if start == .waiting { return .waiting }
        // An Electron or Chromium app has no text field for Accessibility
        // until asked. Once asked, the coordinator looks again shortly.
        guard start == .preview(.unsupported), !delivering, let targetApp, WebAppAccessibility.enable(targetApp) else { return start }
        return .waiting
    }

    func retryLive(session: String) -> LiveInlineStart {
        if inputMethodTake == session {
            switch inputMethod.attachState() {
            case .attached:
                ReasonLog.note("input method active in the app")
                return .typing
            case .pending:
                return .waiting
            case .failed:
                ReasonLog.note("input method did not become active in the app; other live paths")
                inputMethod.end()
                inputMethodTake = nil
                inputMethodAllowed = false
            }
        }
        guard let targetApp, targetApp.isActive else { return .preview(.app) }
        // The field the app reports now replaces the one captured before it
        // built its tree, for live typing and for the normal paste alike.
        captureField()
        let start = beginLiveOverCapturedField(session: session)
        return start == .preview(.unsupported) ? .waiting : start
    }

    /// The same live typing over a given field; tests pass one they own.
    func beginLive(session: String, field: LiveTextField) -> LiveInlineStart {
        live.begin(id: session, field: field)
    }

    func reconcileLive(session: String, transcript: String) -> LiveInlineOwnership.Stop? {
        if inputMethodTake == session { return reconcileInputMethod(transcript) }
        return live.reconcile(session: session, transcript: transcript)
    }

    func typedLive(session: String) -> Bool {
        if inputMethodTake == session { return inputMethod.take?.marked == true || inputMethodStopped != nil }
        return live.typed(session: session)
    }

    func liveHeldBack(session: String) -> Bool { live.heldBack(session: session) }

    func abandonLive(session: String) {
        guard inputMethodTake == session else { return }
        inputMethod.cancel()
        inputMethod.end()
        inputMethodTake = nil
    }

    /// Spacing against the text around the caret, as the paste would put it.
    private func prepared(_ text: String, formatted: NSAttributedString? = nil) -> (text: String, formatted: NSAttributedString?) {
        placeholderStart
            ? InsertionSpacing.prepare(text, formatted: formatted, value: "", selection: NSRange(location: 0, length: 0))
            : InsertionSpacing.prepare(text, formatted: formatted, value: originalValue,
                                       selection: originalSelection.map { NSRange(location: $0.location, length: $0.length) })
    }

    /// The whole current transcript as marked text, only while every check passes.
    private func reconcileInputMethod(_ transcript: String) -> LiveInlineOwnership.Stop? {
        guard inputMethodStopped == nil else { return nil }
        if let reason = inputMethod.interrupted { return stopInputMethod(InputMethodLink.stop(for: reason)) }
        guard let check = targetCheck() else { return stopInputMethod(.app) }
        if let block = InsertionGuard.markedTextBlock(check.facts(since: inputMethodStarted)) {
            return stopInputMethod(LiveInlineOwnership.Stop(block))
        }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        guard inputMethod.mark(prepared(words).text) else { return stopInputMethod(.uncertain) }
        return nil
    }

    /// Live words stop for the take: the words shown stay as they are, the person's source comes back.
    private func stopInputMethod(_ stop: LiveInlineOwnership.Stop) -> LiveInlineOwnership.Stop {
        inputMethodStopped = stop
        inputMethod.freeze()
        inputMethod.end()
        ReasonLog.note("live words through the input method stopped:", stop)
        return stop
    }

    func finishInputMethod(session: String, text: String) async -> LiveInlineFinal? {
        guard inputMethodTake == session else { return nil }
        inputMethodTake = nil
        if let stop = inputMethodStopped { return .kept(stop) }
        if let reason = inputMethod.interrupted {
            return .kept(stopInputMethod(InputMethodLink.stop(for: reason)))
        }
        guard inputMethod.take?.marked == true else {
            // Nothing shown yet: the person's source comes back and the text goes in the usual way.
            inputMethod.end()
            return .notTyped
        }
        guard let check = targetCheck() else { return .kept(stopInputMethod(.app)) }
        if let block = InsertionGuard.markedTextBlock(check.facts(since: inputMethodStarted)) {
            return .kept(stopInputMethod(LiveInlineOwnership.Stop(block)))
        }
        let final = prepared(text).text
        let result = await inputMethod.commit(final)
        inputMethod.end()
        guard result.ok else {
            ReasonLog.note("input method commit refused")
            return .kept(.focus)
        }
        if result.seen {
            ReasonLog.note("finished text committed and read back through the input method")
        } else if await landedAfterCommit(final) {
            ReasonLog.note("finished text committed and read back through Accessibility")
        } else {
            ReasonLog.note("finished text committed but could not be read back")
            return .unconfirmed
        }
        if copyToClipboard(),
           placeOnClipboard(Self.clipboardItem(text: text, formatted: nil, sessionID: UUID().uuidString, private: false)) == nil {
            ReasonLog.note("the finished text could not be copied to the clipboard")
        }
        return .applied
    }

    /// The field now reads as it did with the finished text at the captured caret.
    private func landedAfterCommit(_ final: String) async -> Bool {
        guard let targetField, originalValue != nil else { return false }
        let expected = placeholderStart ? final : expectedValue(inserting: final)
        for _ in 0..<10 {
            let read = attribute(targetField, kAXValueAttribute) as? String
            if EditorPlaceholder.landed(read, expected: expected, start: originalValue, startedAsPlaceholder: placeholderStart) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func finalizeLive(session: String, text: String) -> LiveInlineFinal {
        let result = live.finalize(session: session, text: text)
        // "Copy dictation to clipboard": the finished words, once, after they
        // went in. Live words never touch the clipboard.
        if result == .applied, copyToClipboard(),
           placeOnClipboard(Self.clipboardItem(text: text, formatted: nil, sessionID: UUID().uuidString, private: false)) == nil {
            ReasonLog.note("the finished text could not be copied to the clipboard")
        }
        return result
    }

    func cancelLive(session: String) -> LiveInlineCancel {
        if inputMethodTake == session {
            inputMethodTake = nil
            if let stop = inputMethodStopped { return .left(stop) }
            let shown = inputMethod.take?.marked == true
            inputMethod.cancel()
            inputMethod.end()
            return shown ? .removed : .nothingTyped
        }
        return live.cancel(session: session)
    }

    func deliver(_ text: String) async -> InjectionOutcome {
        await deliver(text, formatted: nil)
    }

    /// The paste's clipboard write. Kept ("Copy dictation to clipboard"):
    /// unmarked, it is the person's copy. Otherwise temporary: marked, and
    /// the person's clipboard is put back after.
    static func pasteItem(text: String, formatted: NSAttributedString?, sessionID: String, keepCopy: Bool) -> NSPasteboardItem? {
        clipboardItem(text: text, formatted: formatted, sessionID: sessionID, private: !keepCopy)
    }

    /// pFlow's temporary paste write is marked so clipboard managers skip it
    /// (`private`); the copy the person asked to keep ("Copy dictation to
    /// clipboard") goes on unmarked, like any copy of theirs.
    static func clipboardItem(text: String, formatted: NSAttributedString?, sessionID: String, private: Bool) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setString(sessionID, forType: sessionType) else { return nil }
        if `private` {
            guard item.setString("", forType: transientType),
                  item.setString("", forType: concealedType) else { return nil }
        }
        if let formatted, formatted.string == text {
            for (type, data) in TemplateTextStyle.representations(for: formatted) {
                item.setData(data, forType: type)
            }
        }
        return item
    }

    func deliver(_ text: String, formatted: NSAttributedString?) async -> InjectionOutcome {
        guard !text.isEmpty else { return .savedToHistory(.nothingToInsert) }
        guard !delivering else { return .unconfirmed }
        // The person's own input source is back before anything is pasted.
        inputMethod.end()
        delivering = true
        defer { delivering = false }
        let keepCopy = copyToClipboard()
        let sessionID = UUID().uuidString

        func unavailable(_ block: InsertionBlock, _ outcome: InjectionOutcome = .leftOnClipboard) -> InjectionOutcome {
            guard keepCopy,
                  placeOnClipboard(Self.clipboardItem(text: text, formatted: formatted, sessionID: sessionID, private: false)) != nil else { return .savedToHistory(block) }
            return outcome
        }

        guard AXIsProcessTrusted() else {
            ReasonLog.note("not put in:", InsertionBlock.accessibilityOff)
            return unavailable(.accessibilityOff)
        }
        PersonInput.shared.start()
        guard let check = targetCheck() else { return unavailable(.appChanged) }
        // A terminal, a remote viewer or a password field never gets the text, whatever else holds.
        if let block = InsertionGuard.block(check.facts(since: PersonInput.now())),
           [.terminal, .remoteViewer, .passwordField].contains(block) { return unavailable(block) }
        if let block = targetBlock() { return unavailable(block) }
        await waitForKeysToClear()
        guard !Task.isCancelled else { return unavailable(.cancelled) }

        let insertion = prepared(text, formatted: formatted)
        // A field that held only a placeholder holds only pFlow's words afterwards.
        let expected = placeholderStart ? insertion.text : expectedValue(inserting: insertion.text)

        // Native text views: a verified Accessibility write, no clipboard.
        if insertion.formatted == nil, let expected, accessibilityWriteFits() {
            switch writeThroughAccessibility(insertion.text, expected: expected, check: check) {
            case .landed:
                if keepCopy, placeOnClipboard(Self.clipboardItem(text: text, formatted: nil, sessionID: sessionID, private: false)) == nil {
                    ReasonLog.note("the finished text could not be copied to the clipboard")
                }
                return .pasted
            case .blocked(let block): return unavailable(block)
            case .notShown: return unavailable(.notTaken)
            case .changedOtherwise: return .unconfirmed
            case .refused: break
            }
        }
        return await checkedPaste(insertion.text, formatted: insertion.formatted, keepCopy: keepCopy, sessionID: sessionID,
                                  expected: expected, before: originalValue, check: check,
                                  extraBlock: { self.targetBlock() }, read: { self.targetField.flatMap { self.attribute($0, kAXValueAttribute) as? String } })
    }

    /// What the field holds once `inserted` replaces the captured selection; nil when it cannot be told.
    private func expectedValue(inserting inserted: String) -> String? {
        guard let value = originalValue, let range = originalSelection, range.location >= 0,
              range.length >= 0, range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else { return nil }
        return (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: inserted)
    }

    /// The captured app and field as the guard reads them.
    private func targetCheck() -> TargetCheck? {
        guard let targetApp else { return nil }
        var check = TargetCheck(pid: targetApp.processIdentifier, element: targetField, bundleID: targetApp.bundleIdentifier)
        check.composition = composition
        return check
    }

    /// A native text field that takes Accessibility writes and shows them at
    /// once. Chromium and Electron apply them later or not at all, and Word
    /// and LibreOffice do not apply them to the document: those are pasted.
    private func accessibilityWriteFits() -> Bool {
        guard let targetApp, let targetField, originalSelection != nil, originalValue != nil,
              WebAppAccessibility.kind(of: targetApp) == nil, !FocusedElement.inWebArea(targetField),
              LiveFieldMethod.method(webApp: false, bundleID: targetApp.bundleIdentifier) == .ranges else { return false }
        return AXLiveTextField(pid: targetApp.processIdentifier, element: targetField, bundleID: targetApp.bundleIdentifier).canWriteRanges()
    }

    private enum AccessibilityWrite { case landed, refused, blocked(InsertionBlock), notShown, changedOtherwise }

    /// Selects the captured range and sets the text there through
    /// Accessibility, right after the guard passes; success only once the
    /// field reads back exactly the expected text.
    private func writeThroughAccessibility(_ text: String, expected: String, check: TargetCheck) -> AccessibilityWrite {
        guard let targetField, let range = originalSelection, let before = originalValue else { return .refused }
        let started = PersonInput.now()
        if let block = targetBlock() ?? InsertionGuard.block(check.facts(since: started)) { return .blocked(block) }
        var cf = range
        guard let rangeValue = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(targetField, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success else { return .refused }
        let result = AXUIElementSetAttributeValue(targetField, kAXSelectedTextAttribute as CFString, text as CFString)
        var read = attribute(targetField, kAXValueAttribute) as? String
        for _ in 0..<20 where !EditorPlaceholder.landed(read, expected: expected, start: before, startedAsPlaceholder: placeholderStart) {
            usleep(50_000)
            read = attribute(targetField, kAXValueAttribute) as? String
        }
        if EditorPlaceholder.landed(read, expected: expected, start: before, startedAsPlaceholder: placeholderStart) { return .landed }
        if read == before { return result == .success ? .notShown : .refused }
        return .changedOtherwise
    }

    /// The one paste: the clipboard is set first, then every check, then ⌘V
    /// with nothing in between; then the result's own check, and the person's
    /// clipboard back unless they asked to keep the words or copied something
    /// newer meanwhile.
    private func checkedPaste(_ text: String, formatted: NSAttributedString?, keepCopy: Bool, sessionID: String,
                              expected: String?, before: String?, check: TargetCheck,
                              extraBlock: () -> InsertionBlock?, read: () -> String?) async -> InjectionOutcome {
        // Prepare rich formats before the snapshot so generation cannot widen
        // the interval that could overwrite a newer clipboard change.
        let prepared = Self.pasteItem(text: text, formatted: formatted, sessionID: sessionID, keepCopy: keepCopy)
        var saved: [[NSPasteboard.PasteboardType: Data]]?
        if !keepCopy {
            let count = pasteboard.changeCount
            guard let snapshot = PasteboardSnapshot.capture(pasteboard), pasteboard.changeCount == count else {
                return .savedToHistory(.clipboard)
            }
            saved = snapshot
        }
        guard let change = placeOnClipboard(prepared, restoring: saved) else { return .savedToHistory(.clipboard) }
        defer {
            if let saved {
                _ = PasteboardSnapshot.restoreIfOwned(saved, to: pasteboard, change: change, session: sessionID)
            }
        }
        let started = PersonInput.now()
        let owned = PasteboardSnapshot.isOwned(pasteboard, change: change, session: sessionID)
        let block: InsertionBlock? = Task.isCancelled ? .cancelled
            : extraBlock() ?? InsertionGuard.block(check.facts(since: started)) ?? (owned ? nil : .clipboard)
        if let block {
            ReasonLog.note("paste refused:", block)
            return keepCopy && owned ? .leftOnClipboard : .savedToHistory(block)
        }
        SyntheticKeys.paste()
        // Unreadable fields (some Electron views) have no paste-completion
        // acknowledgment: they get a bounded grace period before the clipboard
        // goes back. Once a paste is queued, cancellation must not shorten it.
        let reads = keepCopy ? 30 : 20
        for _ in 0..<reads {
            if EditorPlaceholder.landed(read(), expected: expected, start: before, startedAsPlaceholder: placeholderStart) { return .pasted }
            if !PasteboardSnapshot.isOwned(pasteboard, change: change, session: sessionID) { return .unconfirmed }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
        let now = read()
        if EditorPlaceholder.landed(now, expected: expected, start: before, startedAsPlaceholder: placeholderStart) { return .pasted }
        // A field that held text (or a placeholder) and still reads exactly as before took nothing.
        if let before, !before.isEmpty, EditorPlaceholder.same(now, before, startedAsPlaceholder: false) {
            ReasonLog.note("the paste went out and the field still reads as before")
            return .savedToHistory(.notTaken)
        }
        return .unconfirmed
    }

    /// The end of a take with typed live words: pFlow's own words are selected
    /// (no keys). The finished text is pasted over them, the checked way, only
    /// while the selection is still exactly pFlow's words and the person has
    /// not pressed a key or clicked since the select; then read back. Any
    /// doubt ends the selection without a key and the card offers the text.
    #if DEBUG
    /// Self-test hook: runs right after pFlow selected its own words, before the replace checks.
    static var afterOwnSelect: (() -> Void)?
    #endif

    func insertOverSelection(_ text: String, own: OwnedWords, formatted: NSAttributedString?) async -> InjectionOutcome {
        #if DEBUG
        Self.afterOwnSelect?()
        #endif
        guard !delivering else { own.collapse(); return .savedToHistory(.selectionChanged) }
        delivering = true
        defer { delivering = false }
        func refuse(_ block: InsertionBlock) -> InjectionOutcome {
            ReasonLog.note("the finished text did not go over own words:", block)
            own.collapse()
            return .savedToHistory(block)
        }
        guard AXIsProcessTrusted() else { return refuse(.accessibilityOff) }
        guard let targetApp, let targetField, let check = targetCheck() else { return refuse(.appChanged) }
        let reader = AXLiveTextField(pid: targetApp.processIdentifier, element: targetField, plainSpaces: true,
                                     bundleID: targetApp.bundleIdentifier, placeholder: placeholder)
        let now = reader.state()
        if let why = own.mismatch(value: now.value, selection: now.selection) {
            _ = why
            ReasonLog.note("replace refused: own words no longer selected as left")
            return refuse(.selectionChanged)
        }
        guard let value = now.value else { return refuse(.selectionChanged) }
        let styled = formatted.flatMap { $0.string == text ? $0 : nil }
        let replacement = styled == nil ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        let expected = (value as NSString).replacingCharacters(in: own.range, with: replacement)
        let keepCopy = copyToClipboard()
        let outcome = await checkedPaste(replacement, formatted: styled, keepCopy: keepCopy, sessionID: UUID().uuidString,
                                         expected: expected, before: value, check: check, extraBlock: {
            let state = reader.state()
            if own.mismatch(value: state.value, selection: state.selection) != nil { return .selectionChanged }
            return own.personActed() ? .personActed : nil
        }, read: { reader.state().value })
        switch outcome {
        case .savedToHistory, .leftOnClipboard, .blockedBySecureInput:
            own.collapse()
            if case .savedToHistory(let block) = outcome { return .savedToHistory(block) }
            return .savedToHistory(.selectionChanged)
        default:
            return outcome
        }
    }

    /// Replaces the clipboard with `prepared`. Returns the new change count, or
    /// nil when it could not be written; then `saved`, if given, is put back
    /// unless something else changed the clipboard meanwhile.
    private func placeOnClipboard(_ prepared: NSPasteboardItem?,
                                  restoring saved: [[NSPasteboard.PasteboardType: Data]]? = nil) -> Int? {
        guard let item = prepared else { return nil }
        let cleared = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            if let saved, pasteboard.changeCount == cleared { PasteboardSnapshot.restore(saved, to: pasteboard) }
            return nil
        }
        return pasteboard.changeCount
    }

    /// The person's stop key (Right Command, a ⌘⇧ shortcut) may still be held
    /// when the text is due: up to `keyWait` for every modifier, key and
    /// button to be released, before the final paste and before the end
    /// replace selects pFlow's words. The checks after it still refuse a key
    /// held longer.
    static let keyWait: TimeInterval = 0.6

    func waitForKeysToClear() async {
        let deadline = Date().addingTimeInterval(Self.keyWait)
        while Date() < deadline {
            if !PersonInput.modifiersHeld() && !PersonInput.somethingHeld() { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}

enum PasteboardSnapshot {
    static let sessionType = NSPasteboard.PasteboardType("com.frigade.yap.session")

    static func capture(_ pasteboard: NSPasteboard = .general) -> [[NSPasteboard.PasteboardType: Data]]? {
        let before = pasteboard.changeCount
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representation: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                representation[type] = data
            }
            saved.append(representation)
        }
        return pasteboard.changeCount == before ? saved : nil
    }

    static func isOwned(_ pasteboard: NSPasteboard, change: Int, session: String) -> Bool {
        pasteboard.changeCount == change && pasteboard.string(forType: sessionType) == session
    }

    @discardableResult
    static func restoreIfOwned(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard,
                               change: Int, session: String) -> Bool {
        guard isOwned(pasteboard, change: change, session: session) else { return false }
        restore(saved, to: pasteboard)
        return true
    }

    static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items = saved.map { representation -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representation {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
