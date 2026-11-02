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
    /// The clipboard holds something pFlow cannot save whole and put back (a promise its app no
    /// longer keeps): it is left alone, so the text cannot be pasted this time.
    case clipboardUnsaved
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
        case .clipboardUnsaved: return "Your clipboard holds something pFlow can't put back whole, so pFlow left it alone. Copy the text here."
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
    /// The take ended without a finished text (recognition failed): the live words shown stay as they
    /// are, and pFlow Dictation lets go, so the person's input source comes back now, not at the next take.
    func endLive(session: String)
}

extension TextInjecting {
    func finishInputMethod(session: String, text: String) async -> LiveInlineFinal? { nil }
    func liveHeldBack(session: String) -> Bool { false }
    func abandonLive(session: String) {}
    func endLive(session: String) {}
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
    /// The take's input method never marked anything, so nothing of pFlow's is in the field.
    private var inputMethodNothingShown = false
    /// Cleared for the take once the input method could not be used.
    private var inputMethodAllowed = true
    /// When the take's target was captured: a person's key or click after it means the focused
    /// field may be one they chose, not the target, so it is never taken as the target later.
    private var capturedAt: UInt64 = 0
    /// Looking for the first marks in the target field, or taking marks back out: finishing waits for it.
    private var inputMethodCheck: Task<Void, Never>?
    /// Words heard while the first marks are being looked for; marked once they are seen.
    private var inputMethodPending: String?
    /// How long the first marks have to show in the target field before they are taken back out.
    static let confirmWithin: TimeInterval = 0.7
    /// Extra reads, 50 ms apart, of a field that still reads as before a paste (a slow app).
    static let lateReads = 30
    var inputMethod = InputMethodLink.shared
    /// The target field's text as Accessibility reads it (replaceable in tests).
    var readTarget: (AXUIElement) -> String? = { field in
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success ? value as? String : nil
    }
    /// The guard for marked text over the captured target: nil while it holds (replaceable in tests).
    lazy var markedTextCheck: () -> LiveInlineOwnership.Stop? = { [unowned self] in
        guard let check = self.targetCheck() else { return .app }
        return InsertionGuard.markedTextBlock(check.facts(since: self.inputMethodStarted)).map(LiveInlineOwnership.Stop.init)
    }
    /// A stop decided away from an update (the first marks never showed): shown with the next one.
    private var inputMethodStopNotice: LiveInlineOwnership.Stop?
    /// The take left pFlow Dictation for pFlow's card: said with the next update, once.
    private var previewNotice: (session: String, stop: LiveInlineOwnership.Stop)?
    /// pFlow's words the app committed itself that could not come back out: at the end, the finished
    /// text goes over them where they are, if the target field shows them at the caret.
    private var inputMethodLeftWords: [String] = []

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
        inputMethodNothingShown = false
        inputMethodAllowed = true
        inputMethodCheck?.cancel()
        inputMethodCheck = nil
        inputMethodPending = nil
        inputMethodStopNotice = nil
        previewNotice = nil
        inputMethodLeftWords = []
        targetApp = NSWorkspace.shared.frontmostApplication
        PersonInput.shared.start()
        capturedAt = PersonInput.now()
        // Whether the person was composing when the take started: the end of
        // the take refuses until a real commit is seen, whatever the time.
        composition = PersonInput.shared.compositionSnapshot(sourceID: PersonInput.selectedInputMethodID())
        captureField()
    }

    #if DEBUG
    /// Tests: a take on pFlow Dictation over a given field, its text and caret (no real app).
    func adoptInputMethodTakeForTesting(session: String, field: AXUIElement, value: String, caret: Int) {
        targetField = field
        fieldUnreadable = false
        originalValue = value
        originalSelection = CFRange(location: caret, length: 0)
        placeholder = nil
        inputMethodTake = session
        inputMethodStopped = nil
        inputMethodNothingShown = false
        inputMethodAllowed = true
        inputMethodStarted = PersonInput.now()
    }
    #endif

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
        // An app that types marked words in would get every mark typed again beside the last one.
        if appMarks[bundle] == .types {
            ReasonLog.note("input method not used: this app types marked words in")
            inputMethodAllowed = false
            return .preview(.uncertain)
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
        guard inputMethod.begin(id: session, bundle: bundle, readable: targetReadable, window: targetWindowFrame()) else {
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
                if inputMethod.provisional { ReasonLog.note("input method on probation: no activation came for this take") }
                return .typing
            case .pending:
                return .waiting
            case .failed(let why):
                ReasonLog.note("input method did not become active in the app; other live paths")
                ReasonLog.note("input method attach:", AttachReason(why))
                inputMethod.end()
                inputMethodTake = nil
                inputMethodAllowed = false
            }
        }
        guard let targetApp, targetApp.isActive else { return .preview(.app) }
        // The person clicked or typed since the take began: the focused field may be one they
        // moved to. It never becomes the target; the words show in the preview.
        if PersonInput.shared.acted(since: capturedAt) == true {
            ReasonLog.note("live typing not started: the person clicked or typed while it waited")
            return .preview(.caret)
        }
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
        if let notice = previewNotice, notice.session == session {
            previewNotice = nil
            return notice.stop
        }
        return live.reconcile(session: session, transcript: transcript)
    }

    func typedLive(session: String) -> Bool {
        if inputMethodTake == session { return !inputMethodNothingShown && (inputMethod.take?.marked == true || inputMethodStopped != nil) }
        return live.typed(session: session)
    }

    func liveHeldBack(session: String) -> Bool { live.heldBack(session: session) }

    func abandonLive(session: String) {
        guard inputMethodTake == session else { return }
        inputMethod.cancel()
        inputMethod.end()
        inputMethodTake = nil
    }

    func endLive(session: String) {
        guard inputMethodTake == session else { return }
        if inputMethodStopped == nil { _ = stopInputMethod(.uncertain) }
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
        guard inputMethodStopped == nil else {
            defer { inputMethodStopNotice = nil }
            return inputMethodStopNotice
        }
        if let reason = inputMethod.interrupted { return stopInputMethod(InputMethodLink.stop(for: reason)) }
        if let stop = markedTextCheck() { return stopInputMethod(stop) }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        if targetReadable {
            guard inputMethod.confirmed else {
                // The first words go out once; nothing more is written through the client until
                // they show in the target field at the caret (a client of another window would take them too).
                if inputMethod.take?.seq == 0 {
                    guard inputMethod.mark(prepared(words).text) else { return stopInputMethod(.uncertain) }
                    lookForFirstMarks()
                } else {
                    inputMethodPending = words
                }
                return nil
            }
            // Before every further mark: the earlier ones show at the caret in the target field.
            if inputMethod.showingCandidates() != nil, marksAtCaret() == nil { return notInTarget() }
        }
        guard inputMethod.mark(prepared(words).text) else { return stopInputMethod(.uncertain) }
        return nil
    }

    /// The field's text before the captured caret and after the selection (both empty over a placeholder).
    private var caretContext: (before: String, after: String)? {
        if placeholderStart { return ("", "") }
        guard let value = originalValue, let range = originalSelection, range.location >= 0, range.length >= 0 else { return nil }
        let text = value as NSString
        guard range.location + range.length <= text.length else { return nil }
        return (text.substring(to: range.location), text.substring(from: range.location + range.length))
    }

    /// The mark the target field shows at the captured caret: the newest acknowledged one or a newer
    /// one before the take is confirmed, any from the confirmed one on after. Nil when none shows.
    private func marksAtCaret(settled: TimeInterval = 0.15) -> Int? {
        guard let targetField, let context = caretContext, let candidates = inputMethod.showingCandidates(settled: settled) else { return nil }
        let read = readTarget(targetField)
        return candidates.reversed().first { InputMethodFinish.showsAtCaret(read: read, texts: [$0.text], before: context.before, after: context.after) }?.seq
    }

    /// The first marks are looked for in the target field. Seen: the client is the take's (it may now
    /// commit) and the words heard meanwhile go in. Not seen in time: they are taken back out of that
    /// client and the take goes on by pFlow's other live paths, once the input method reports them gone.
    private func lookForFirstMarks() {
        guard let session = inputMethodTake else { return }
        let started = Date()
        inputMethodCheck = Task { [weak self] in
            while let self, self.inputMethodTake == session, self.inputMethodStopped == nil, !Task.isCancelled {
                if let seq = self.marksAtCaret(settled: 0.05) {
                    let probation = self.inputMethod.provisional
                    var again: String?
                    if let bundle = self.inputMethod.take?.bundle, self.appMarks[bundle] == nil {
                        guard let words = await self.checkAppKeepsMarks(bundle: bundle, session: session) else { return }
                        again = words
                    }
                    self.inputMethod.confirm(seq: seq)
                    ReasonLog.note(probation ? "input method words seen in the target: the client on probation is the take's"
                                             : "input method words seen in the target")
                    if let words = self.inputMethodPending {
                        self.inputMethodPending = nil
                        if !self.inputMethod.mark(self.prepared(words).text) { _ = self.stopInputMethod(.uncertain) }
                    } else if let again, !self.inputMethod.mark(again) {
                        _ = self.stopInputMethod(.uncertain)
                    }
                    return
                }
                if Date().timeIntervalSince(started) > Self.confirmWithin {
                    await self.withdrawToOtherPaths(session: session)
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    /// What an app does with marked words, learned on its first take with pFlow Dictation this launch.
    enum AppMarks { case keeps, types }
    /// By bundle ID, for as long as pFlow runs.
    private(set) var appMarks: [String: AppMarks] = [:]
    #if DEBUG
    func rememberMarksForTesting(_ kind: AppMarks, for bundle: String) { appMarks[bundle] = kind }
    #endif

    /// The first take in an app this launch: its first words, just seen at the caret, are taken back
    /// out once. An app with marked text shows them gone, and they come straight back (the words to
    /// mark again are returned). An app that put them in as typed text still has them where the target
    /// field shows them, and every later mark would type the words again beside them: pFlow Dictation
    /// stops for this take (those words stay; the finished text goes over them at the end) and is not
    /// used in that app again this launch. Anything unclear stops it for this take only. pFlow Dictation
    /// deletes nothing either way.
    private func checkAppKeepsMarks(bundle: String, session: String) async -> String? {
        let words = inputMethod.newestMarked
        ReasonLog.note("input method: first take in this app, checking it keeps marked words")
        let cleared = await inputMethod.clear()
        guard inputMethodTake == session, inputMethodStopped == nil else { return nil }
        // pFlow Dictation's reads can come from a late cache: the target field itself decides.
        let stillThere = words.map { shownAtCaret($0) } ?? false
        if cleared || (!stillThere && fieldShowsCaretContext()) {
            appMarks[bundle] = .keeps
            ReasonLog.note("input method: this app keeps marked words")
            return words
        }
        if stillThere {
            appMarks[bundle] = .types
            ReasonLog.note("input method: this app types marked words in; pFlow's card for it from now on")
        } else {
            ReasonLog.note("input method: this app's marked words could not be checked")
        }
        inputMethodLeftWords = words.map { [$0] } ?? []
        inputMethodStopped = .unsupported
        inputMethodStopNotice = .unsupported
        inputMethod.end()
        return nil
    }

    /// The target field shows `words` at the captured caret (as the first marks are looked for).
    private func shownAtCaret(_ words: String) -> Bool {
        guard let targetField, let context = caretContext else { return false }
        return InputMethodFinish.showsAtCaret(read: readTarget(targetField), texts: [words], before: context.before, after: context.after)
    }

    /// The target field shows what it held around the caret when the take began, nothing of pFlow's.
    private func fieldShowsCaretContext() -> Bool {
        guard let targetField, let context = caretContext, let read = readTarget(targetField) else { return false }
        return InputMethodFinish.clean(read).trimmingCharacters(in: .newlines)
            == InputMethodFinish.clean(context.before + context.after).trimmingCharacters(in: .newlines)
    }

    /// The first marks never showed in the target: out of that client they come, and only once the
    /// input method reports them gone does the take go on another way. Not reported gone: nothing
    /// more is written, and the finished text is kept for the Copy card, never pasted beside them.
    private func withdrawToOtherPaths(session: String) async {
        ReasonLog.note("input method words not seen in the target field: taken back out")
        let provisional = inputMethod.provisional, words = inputMethod.newestMarked
        let cleared = await inputMethod.clear()
        let committed = inputMethod.lastClearReason == InputMethodTakeBack.committed.rawValue
        inputMethod.end()
        guard inputMethodTake == session else { return }
        if !cleared, committed { inputMethodLeftWords = words.map { [$0] } ?? [] }
        leaveInputMethod(session: session, proven: cleared, provisional: provisional)
    }

    /// The take's words are out of the input method's client (`proven`), or may still be there.
    /// Proven: a client still active from before (on probation) may simply have been another window's,
    /// so the take goes on by pFlow's other live paths. A client activated for this take in the target
    /// app means the app does not show the words where pFlow can check them (or not in time); keys
    /// would be checked the same way, so the words show on pFlow's card and the finished text goes in
    /// once at the end. Not proven: nothing more is written and the finished text stays on the card.
    private func leaveInputMethod(session: String, proven: Bool, provisional: Bool) {
        guard proven else {
            ReasonLog.note("input method words not proven gone: the finished text stays on the card")
            inputMethodStopped = .otherWindow
            inputMethodStopNotice = .otherWindow
            return
        }
        inputMethodTake = nil
        inputMethodAllowed = false
        inputMethodPending = nil
        guard provisional else {
            ReasonLog.note("live words on pFlow's card: the app does not show them where pFlow can check")
            _ = live.begin(id: session, field: nil)
            previewNotice = (session, .unsupported)
            return
        }
        let start = beginLiveOverCapturedField(session: session)
        ReasonLog.note("live typing after the input method:", start)
    }

    /// Live words stop for the take: the words shown stay as they are, the person's source comes back.
    private func stopInputMethod(_ stop: LiveInlineOwnership.Stop) -> LiveInlineOwnership.Stop {
        inputMethodStopped = stop
        if inputMethod.interrupted == "notSelected", inputMethod.take?.seq == 0 { inputMethodNothingShown = true }
        inputMethod.freeze()
        inputMethod.end()
        ReasonLog.note("live words through the input method stopped:", stop)
        return stop
    }

    func finishInputMethod(session: String, text: String) async -> LiveInlineFinal? {
        // The first marks may still be looked for, or marks taken back out: that decides first.
        await inputMethodCheck?.value
        guard inputMethodTake == session else { return nil }
        inputMethodTake = nil
        // Nothing was ever marked (pFlow's source was not the selected one): the text goes in the usual way.
        if inputMethodNothingShown || (inputMethod.interrupted == "notSelected" && inputMethod.take?.seq == 0) {
            inputMethod.end()
            return .notTyped
        }
        if let stop = inputMethodStopped { return overLeftWords() ?? .kept(stop) }
        if let reason = inputMethod.interrupted {
            return .kept(stopInputMethod(InputMethodLink.stop(for: reason)))
        }
        guard inputMethod.take?.marked == true else {
            // Nothing shown yet: the person's source comes back and the text goes in the usual way.
            inputMethod.end()
            return .notTyped
        }
        if let stop = markedTextCheck() { return .kept(stopInputMethod(stop)) }
        let final = prepared(text).text
        // The finished text goes through the input method only after its marks were seen at the caret in
        // the target this take, and are still there. Otherwise they come back out, and the usual checked
        // paste follows only once the input method reports them gone; if it does not, the Copy card.
        let atCaret = targetReadable && inputMethod.confirmed ? await targetShowsMarks(waiting: 0.5) : false
        if InputMethodFinish.takesBackFirst(targetReadable: targetReadable, confirmed: inputMethod.confirmed, marksAtCaret: atCaret) {
            ReasonLog.note(inputMethod.confirmed ? "input method words no longer at the caret: taken back out"
                                                 : "input method words never seen in the target: taken back out")
            let words = [inputMethod.newestMarked, inputMethod.everyMarkTyped].compactMap { $0 }
            let cleared = await inputMethod.clear()
            if !cleared { inputMethodLeftWords = words }
            inputMethod.end()
            if !cleared { ReasonLog.note("input method words not proven gone: the finished text stays on the card") }
            return cleared ? InputMethodFinish.afterTakeBack(cleared: true) : overLeftWords() ?? InputMethodFinish.afterTakeBack(cleared: false)
        }
        let result = await inputMethod.commit(final)
        inputMethod.end()
        if !result.ok { ReasonLog.note("input method commit refused") }
        let finished = await InputMethodFinish.conclude(
            committed: result.ok, seenByInputMethod: result.seen, targetReadable: targetReadable, keepCopy: copyToClipboard(),
            landedInTarget: { await self.landedAfterCommit(final) },
            copy: {
                if self.placeOnClipboard(Self.clipboardItem(text: text, formatted: nil, sessionID: UUID().uuidString, private: false)) == nil {
                    ReasonLog.note("the finished text could not be copied to the clipboard")
                }
            })
        ReasonLog.note(finished == .applied ? "finished text committed and seen in the target"
                       : finished == .unconfirmed ? "finished text committed but not seen in the target" : "finished text not committed")
        return finished
    }

    /// pFlow's words that the app committed itself and that could not come back out: when the target
    /// field shows exactly them at the captured caret (its text before the caret, the words, its text
    /// after), they are selected there and the finished text goes over them by the usual checked paste,
    /// the same end as typed keys: the whole text once. Anything else: nil, and the card says why.
    private func overLeftWords() -> LiveInlineFinal? {
        let candidates = inputMethodLeftWords
        inputMethodLeftWords = []
        guard !candidates.isEmpty, targetReadable, !placeholderStart, let context = caretContext, let field = leftWordsField() else { return nil }
        // The newest words, or every mark typed in one after another (an app with no marked text). Read
        // twice, a moment apart, both the same: a field that answers from a late cache is not trusted.
        let value = field.state().value
        leftWordsSettle()
        guard field.state().value == value,
              let words = candidates.first(where: { value == context.before + $0 + context.after }) else {
            ReasonLog.note("input method words the app committed: not found at the caret")
            return nil
        }
        // The spacing pFlow put before the words stays; only the words themselves are replaced.
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = (words as NSString).range(of: trimmed).location
        guard !trimmed.isEmpty, lead != NSNotFound else { return nil }
        let range = NSRange(location: (context.before as NSString).length + lead, length: (trimmed as NSString).length)
        guard field.select(range) else {
            ReasonLog.note("input method words the app committed: could not be selected")
            return nil
        }
        ReasonLog.note("input method words the app committed are at the caret: the finished text goes over them")
        return .replace(OwnedWords(range: range, text: trimmed, personActed: { field.personActedSinceSelect() },
                                   collapse: { field.collapse() }))
    }

    /// The pause between the two reads of the field before the select-and-paste (a test passes none).
    var leftWordsSettle: () -> Void = { usleep(250_000) }

    /// The target field for the select-and-paste over app-committed words (a test passes its own).
    lazy var leftWordsField: () -> LiveTextField? = { [unowned self] in
        guard let targetApp, let targetField else { return nil }
        return KeyLiveTextField(pid: targetApp.processIdentifier, element: targetField, bundleID: targetApp.bundleIdentifier,
                                composition: composition, placeholder: nil)
    }

    /// The target field can be read, so what it shows decides (never the input method's own client).
    private var targetReadable: Bool { targetField != nil && !fieldUnreadable && originalValue != nil }

    /// The target field shows this take's marks at the caret (waiting up to `waiting` seconds for it to draw).
    private func targetShowsMarks(waiting: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(waiting)
        repeat {
            if marksAtCaret(settled: 0) != nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        return false
    }

    /// The take's marks are not at the caret in the target field (another window or field of the app
    /// has them): they are taken back out of that client. The finished text goes in the usual way at
    /// the end only once the input method reports them gone; otherwise it stays on the Copy card.
    private func notInTarget() -> LiveInlineOwnership.Stop {
        ReasonLog.note("input method words not in the target field: taken back out")
        inputMethodStopped = .uncertain
        let previous = inputMethodCheck
        inputMethodCheck = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let words = [self.inputMethod.newestMarked, self.inputMethod.everyMarkTyped].compactMap { $0 }
            let cleared = await self.inputMethod.clear()
            self.inputMethod.end()
            if cleared { self.inputMethodNothingShown = true }
            else {
                ReasonLog.note("input method words not proven gone: the finished text stays on the card")
                self.inputMethodStopped = .otherWindow
                self.inputMethodLeftWords = words
            }
        }
        return .uncertain
    }

    /// The target window's frame in Cocoa screen coordinates, for the input method's check that a
    /// client on probation has its caret in that window.
    private func targetWindowFrame() -> CGRect? {
        guard let targetField, let window = attribute(targetField, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID(),
              let position = attribute(window as! AXUIElement, kAXPositionAttribute), let size = attribute(window as! AXUIElement, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              let height = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: point.x, y: height - point.y - extent.height, width: extent.width, height: extent.height)
    }

    /// The field now reads as it did with the finished text at the captured caret.
    private func landedAfterCommit(_ final: String) async -> Bool {
        guard let targetField, originalValue != nil else { return false }
        let expected = placeholderStart ? final : expectedValue(inserting: final)
        for _ in 0..<10 {
            let read = readTarget(targetField)
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
            // The person's clipboard comes back whole or is not touched: a type that cannot be saved
            // (Excel's lazy formats, a promised attachment) leaves it alone, and the card has the text.
            let count = pasteboard.changeCount
            guard let snapshot = PasteboardSnapshot.capture(pasteboard), pasteboard.changeCount == count else {
                ReasonLog.note("the clipboard holds something that cannot be saved whole: not used")
                return .savedToHistory(pasteboard.changeCount == count ? .clipboardUnsaved : .clipboard)
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
        let placeholderStart = self.placeholderStart
        let seen = await Self.pasteSeen(reads: keepCopy ? 30 : 20, late: Self.lateReads, read: read,
                                         landed: { EditorPlaceholder.landed($0, expected: expected, start: before, startedAsPlaceholder: placeholderStart) },
                                         asBefore: { now in before.map { !$0.isEmpty && EditorPlaceholder.same(now, $0, startedAsPlaceholder: false) } ?? false },
                                         owned: { PasteboardSnapshot.isOwned(self.pasteboard, change: change, session: sessionID) },
                                         wait: { await withCheckedContinuation { continuation in
                                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() } } })
        switch seen {
        case .landed: return .pasted
        case .landedLate:
            ReasonLog.note("the paste showed late in the field")
            return .pasted
        case .notTaken:
            ReasonLog.note("the paste went out and the field still reads as before")
            return .savedToHistory(.notTaken)
        case .unconfirmed: return .unconfirmed
        }
    }

    enum PasteSeen: Equatable { case landed, landedLate, notTaken, unconfirmed }

    /// What a paste did, read back every `wait` (50 ms): landed; the clipboard changed meanwhile
    /// (unconfirmed); or, after `reads`, a field that still reads exactly as before is read `late`
    /// more times (a slow app shows a paste late: a long document on an older Mac) before it counts
    /// as not taken, so a paste that did land never gets a card saying it did not.
    static func pasteSeen(reads: Int, late: Int, read: () -> String?, landed: (String?) -> Bool, asBefore: (String?) -> Bool,
                          owned: () -> Bool, wait: () async -> Void) async -> PasteSeen {
        for _ in 0..<reads {
            if landed(read()) { return .landed }
            if !owned() { return .unconfirmed }
            await wait()
        }
        var now = read()
        if landed(now) { return .landed }
        var extra = 0
        while extra < late, asBefore(now), owned() {
            extra += 1
            await wait()
            now = read()
            if landed(now) { return .landedLate }
        }
        // A field that held text (or a placeholder) and still reads exactly as before took nothing.
        return asBefore(now) ? .notTaken : .unconfirmed
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

    /// Every item of the clipboard with every type's data, so it can come back whole. Nil when any
    /// type gives no data (a promise its app no longer keeps, an Excel range's lazy formats): a
    /// partial copy would come back without them, so the clipboard is not used at all then. Nil too
    /// when it changed while being read.
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
