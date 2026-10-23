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
}

extension TextInjecting {
    func deliver(_ text: String, formatted: NSAttributedString?) async -> InjectionOutcome { await deliver(text) }
    var targetIsSecure: Bool { false }
    var accessibilityGranted: Bool { true }
    func beginLive(session: String) -> LiveInlineStart { .preview(.unsupported) }
    func retryLive(session: String) -> LiveInlineStart { .preview(.unsupported) }
    func reconcileLive(session: String, transcript: String) -> LiveInlineOwnership.Stop? { nil }
    func typedLive(session: String) -> Bool { false }
    func finalizeLive(session: String, text: String) -> LiveInlineFinal { .notTyped }
    func cancelLive(session: String) -> LiveInlineCancel { .nothingTyped }
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
    /// Lets the pasteboard server round-trip complete before ⌘V.
    private static let prePasteDelay: TimeInterval = 0.03

    /// `NX_DEVICELCMDKEYMASK` — "left command physically down". Carbon-era, Qt
    /// and Java apps read the device-dependent bits and ignore a bare command flag.
    private static let deviceLeftCommand: UInt64 = 0x0000_0008

    private static let sessionType = PasteboardSnapshot.sessionType
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private var targetApp: NSRunningApplication?
    private var targetField: AXUIElement?
    private var originalValue: String?
    private var originalSelection: CFRange?
    private(set) var targetIsSecure = false
    private var delivering = false
    private var live = LiveInlineSlot()

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func focusedField(_ app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let value = attribute(element, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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
        targetApp = NSWorkspace.shared.frontmostApplication
        captureField()
    }

    /// The focused field of the captured app and what it holds, so a paste
    /// later can tell whether anything changed.
    private func captureField() {
        targetField = targetApp.flatMap(focusedField)
        originalValue = targetField.flatMap { attribute($0, kAXValueAttribute) as? String }
        originalSelection = targetField.flatMap(selection)
        targetIsSecure = targetField.map { attribute($0, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole } ?? false
    }

    private func beginLiveOverCapturedField(session: String) -> LiveInlineStart {
        guard !delivering, let targetApp, let targetField else { return live.begin(id: session, field: nil) }
        return beginLive(session: session, field: AXLiveTextField(pid: targetApp.processIdentifier, element: targetField))
    }

    func beginLive(session: String) -> LiveInlineStart {
        let start = beginLiveOverCapturedField(session: session)
        // An Electron or Chromium app has no text field for Accessibility
        // until asked. Once asked, the coordinator looks again shortly.
        guard start == .preview(.unsupported), !delivering, let targetApp, WebAppAccessibility.enable(targetApp) else { return start }
        return .waiting
    }

    func retryLive(session: String) -> LiveInlineStart {
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
        live.reconcile(session: session, transcript: transcript)
    }

    func typedLive(session: String) -> Bool { live.typed(session: session) }

    func finalizeLive(session: String, text: String) -> LiveInlineFinal {
        let result = live.finalize(session: session, text: text)
        // "Copy dictation to clipboard": the finished words, once, after they
        // went in. Live words never touch the clipboard.
        if result == .applied, copyToClipboard(),
           placeOnClipboard(Self.clipboardItem(text: text, formatted: nil, sessionID: UUID().uuidString)) == nil {
            NSLog("pFlow: the finished text could not be copied to the clipboard")
        }
        return result
    }

    func cancelLive(session: String) -> LiveInlineCancel {
        live.cancel(session: session)
    }

    func deliver(_ text: String) async -> InjectionOutcome {
        await deliver(text, formatted: nil)
    }

    static func clipboardItem(text: String, formatted: NSAttributedString?, sessionID: String) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setString(sessionID, forType: sessionType),
              item.setString("", forType: transientType) else { return nil }
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
        delivering = true
        defer { delivering = false }
        let keepCopy = copyToClipboard()
        let sessionID = UUID().uuidString
        var saved: [[NSPasteboard.PasteboardType: Data]]?

        func unavailable(_ block: InsertionBlock, _ outcome: InjectionOutcome = .leftOnClipboard) -> InjectionOutcome {
            guard keepCopy,
                  placeOnClipboard(Self.clipboardItem(text: text, formatted: formatted, sessionID: sessionID)) != nil else { return .savedToHistory(block) }
            return outcome
        }

        guard AXIsProcessTrusted() else {
            NSLog("pFlow: Accessibility is off for this build, so the text cannot be put in")
            return unavailable(.accessibilityOff)
        }
        guard !SecureInput.isEnabled else { return unavailable(.secureInput, .blockedBySecureInput(SecureInput.holderName())) }
        if let block = targetBlock() { return unavailable(block) }
        await waitForModifiersToClear()
        let held: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        guard !Task.isCancelled else { return unavailable(.cancelled) }
        guard NSEvent.modifierFlags.intersection(held).isEmpty else { return unavailable(.interrupted) }
        guard !SecureInput.isEnabled else { return unavailable(.secureInput, .blockedBySecureInput(SecureInput.holderName())) }
        if let block = targetBlock() { return unavailable(block) }

        let insertion = InsertionSpacing.prepare(text, formatted: formatted, value: originalValue,
            selection: originalSelection.map { NSRange(location: $0.location, length: $0.length) })
        // Prepare rich formats before the snapshot so generation cannot widen
        // the interval that could overwrite a newer clipboard change.
        let prepared = Self.clipboardItem(text: insertion.text, formatted: insertion.formatted, sessionID: sessionID)
        if !keepCopy {
            let before = pasteboard.changeCount
            guard let snapshot = PasteboardSnapshot.capture(pasteboard), pasteboard.changeCount == before else {
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
        try? await Task.sleep(nanoseconds: UInt64(Self.prePasteDelay * 1_000_000_000))
        let owned = PasteboardSnapshot.isOwned(pasteboard, change: change, session: sessionID)
        let lateBlock: InsertionBlock? = Task.isCancelled ? .cancelled
            : SecureInput.isEnabled ? .secureInput
            : targetBlock() ?? (owned ? nil : .clipboard)
        if let lateBlock {
            return keepCopy && owned ? .leftOnClipboard : .savedToHistory(lateBlock)
        }
        let expected: String? = {
            guard let value = originalValue, let range = originalSelection, range.location >= 0,
                  range.length >= 0, range.location <= (value as NSString).length,
                  range.length <= (value as NSString).length - range.location else { return nil }
            return (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: insertion.text)
        }()
        await postPaste()
        // Unreadable Electron fields have no public paste-completion acknowledgment.
        // Give asynchronous readers a bounded 0.5s before best-effort restoration.
        // Once a paste is queued, cancellation must not shorten that grace period.
        for _ in 0..<(keepCopy ? 20 : 10) {
            if let field = targetField, let expected,
               attribute(field, kAXValueAttribute) as? String == expected { return .pasted }
            if !PasteboardSnapshot.isOwned(pasteboard, change: change, session: sessionID) { return .unconfirmed }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
        }
        if let field = targetField, let expected,
           attribute(field, kAXValueAttribute) as? String == expected { return .pasted }
        return .unconfirmed
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

    /// System Events (via Apple Events) is the only route that proved reliable
    /// across native, Electron and web apps alike; synthetic key events remain a
    /// fallback for when automation is unavailable.
    private func postPaste() async {
        if pasteViaAppleScript() { return }
        NSLog("pFlow: AppleScript paste unavailable, falling back to synthetic key events")
        await postSyntheticPaste()
    }

    /// Posts a full ⌘V as four events (Command down, V down, V up, Command up).
    /// A lone V with `.maskCommand` works for native apps, but Chromium/Electron
    /// rebuilds modifier state from the raw event stream and needs a genuine
    /// Command keyDown or the paste silently does nothing.
    private func postSyntheticPaste() async {
        // A private source has its own modifier state, so nothing ambient can
        // bleed into the events we create.
        guard let source = CGEventSource(stateID: .privateState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let commandFlags = CGEventFlags(
            rawValue: CGEventFlags.maskCommand.rawValue | Self.deviceLeftCommand
        )
        let commandKey = CGKeyCode(kVK_Command)
        let vKey = CGKeyCode(kVK_ANSI_V)

        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            else { return }
            event.flags = flags
            // The HID tap is where hardware events enter the window server, so
            // Chromium treats the sequence as genuine typing.
            event.post(tap: .cghidEventTap)
        }

        let step: UInt64 = 10_000_000

        post(commandKey, down: true, flags: commandFlags)
        try? await Task.sleep(nanoseconds: step)
        post(vKey, down: true, flags: commandFlags)
        try? await Task.sleep(nanoseconds: step)
        post(vKey, down: false, flags: commandFlags)
        try? await Task.sleep(nanoseconds: step)
        post(commandKey, down: false, flags: [])
    }

    private func pasteViaAppleScript() -> Bool {
        let source = "tell application \"System Events\" to keystroke \"v\" using command down"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            NSLog("pFlow: AppleScript paste failed: \(error)")
            return false
        }
        return true
    }

    private func waitForModifiersToClear(timeout: TimeInterval = 0.6) async {
        let deadline = Date().addingTimeInterval(timeout)
        let watched: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]

        while Date() < deadline {
            if NSEvent.modifierFlags.intersection(watched).isEmpty { return }
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
