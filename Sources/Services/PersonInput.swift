import AppKit
import Carbon
import CoreGraphics

/// Watches for the person's own key presses and clicks, without changing or
/// holding any event, so pFlow can tell whether they acted between its last
/// check and a paste or a batch of typed keys. pFlow's own synthetic events
/// carry `SyntheticKeys.marker` and are never counted.
///
/// A listen-only event tap on its own thread when Input Monitoring is
/// granted; otherwise a pass-through tap, which Accessibility allows. The
/// thread is separate so a busy main thread never delays what it records.
final class PersonInput: @unchecked Sendable {
    static let shared = PersonInput()

    private let lock = NSLock()
    private var lastAction: UInt64 = 0
    private var keysSinceCommit = false
    private var tap: CFMachPort?
    private var thread: Thread?
    private var watchingNow = false

    /// Nanoseconds on the clock `acted(since:)` compares against.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// True while key presses and clicks are being seen.
    var watching: Bool { lock.withLock { watchingNow } }

    /// Whether the person pressed a key or clicked at or after `time`; nil
    /// when nothing is watching, so nobody can say.
    func acted(since time: UInt64) -> Bool? {
        lock.withLock { watchingNow ? lastAction >= time : nil }
    }

    /// A key was pressed since the last Return, Enter, Escape, Tab or click.
    var uncommittedKeys: Bool { lock.withLock { keysSinceCommit } }

    /// Starts watching once Accessibility is granted; safe to call every take.
    func start() {
        lock.lock()
        let running = thread != nil
        lock.unlock()
        guard !running, AXIsProcessTrusted() else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "pFlow person input"
        thread.qualityOfService = .userInteractive
        lock.withLock { self.thread = thread }
        thread.start()
    }

    /// Test and self-test hook: what a key press or click by the person records.
    func record(keyCode: Int64?) {
        lock.withLock {
            lastAction = Self.now()
            if let keyCode {
                keysSinceCommit = !InputComposition.commitKeys.contains(keyCode)
            } else {
                keysSinceCommit = false
            }
        }
    }

    private func run() {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let options: CGEventTapOptions = CGPreflightListenEventAccess() ? .listenOnly : .defaultTap
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<PersonInput>.fromOpaque(info).takeUnretainedValue()
            monitor.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: options,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("pFlow: key presses and clicks cannot be watched (no event tap)")
            lock.withLock { thread = nil }
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock {
            self.tap = tap
            watchingNow = true
        }
        NSLog("pFlow: watching key presses and clicks (\(options == .listenOnly ? "listen-only" : "pass-through") tap)")
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enabled at once; anything missed meanwhile counts as acted.
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            record(keyCode: nil)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard event.getIntegerValueField(.eventSourceUserData) != SyntheticKeys.marker else { return }
            record(keyCode: type == .keyDown ? event.getIntegerValueField(.keyboardEventKeycode) : nil)
        default:
            break
        }
    }

    /// A key (other than a modifier or Caps Lock) or a mouse button is down right now.
    static func somethingHeld() -> Bool {
        for button in [CGMouseButton.left, .right, .center] where CGEventSource.buttonState(.hidSystemState, button: button) {
            return true
        }
        let modifiers: ClosedRange<CGKeyCode> = 54...63
        for key in CGKeyCode(0)..<CGKeyCode(128) where !modifiers.contains(key) && key != 0x3F {
            if CGEventSource.keyState(.hidSystemState, key: key) { return true }
        }
        return false
    }

    /// Command, Shift, Option, Control or Fn is down.
    static func modifiersHeld() -> Bool {
        let held: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]
        return !NSEvent.modifierFlags.intersection(held).isEmpty
    }

    /// The selected keyboard input source composes text (an input method mode,
    /// such as Japanese Hiragana or Chinese Pinyin), not a plain layout.
    static func inputMethodSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        guard type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodModeEnabled as String) else { return false }
        // A Roman mode of an input method types letters directly.
        if let modeRaw = TISGetInputSourceProperty(source, kTISPropertyInputModeID) {
            let mode = Unmanaged<CFString>.fromOpaque(modeRaw).takeUnretainedValue() as String
            if mode.hasSuffix(".Roman") || mode.hasSuffix(".ABC") { return false }
        }
        return true
    }
}

/// pFlow's synthetic key events: ⌘V for a paste, and Unicode text for live
/// words. Each is posted the moment the checks before it pass, with nothing
/// in between, and carries `marker` so the person-input watch ignores it.
enum SyntheticKeys {
    /// eventSourceUserData of every event pFlow posts ("pFlow").
    static let marker: Int64 = 0x7046_6C6F_77

    /// `NX_DEVICELCMDKEYMASK`: Carbon-era, Qt and Java apps read the
    /// device-dependent bits and ignore a bare command flag.
    private static let deviceLeftCommand: UInt64 = 0x0000_0008

    private static func source() -> CGEventSource? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = marker
        return source
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }

    /// A full ⌘V as four events (Command down, V down, V up, Command up):
    /// Chromium and Electron rebuild modifier state from the raw event stream
    /// and need a genuine Command key-down.
    @discardableResult
    static func paste() -> Bool {
        guard let source = source() else { return false }
        let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | deviceLeftCommand)
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [
            (CGKeyCode(kVK_Command), true, command), (CGKeyCode(kVK_ANSI_V), true, command),
            (CGKeyCode(kVK_ANSI_V), false, command), (CGKeyCode(kVK_Command), false, []),
        ]
        var events: [CGEvent] = []
        for (key, down, flags) in steps {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = flags
            events.append(event)
        }
        events.forEach(post)
        return true
    }

    /// Most UTF-16 units one key event carries.
    static let unitsPerEvent = 20

    /// `text` cut into key-event pieces of at most `unitsPerEvent` UTF-16
    /// units, never inside a character.
    static func chunks(_ text: String) -> [String] {
        var pieces: [String] = [], current = ""
        for character in text {
            if current.utf16.count + character.utf16.count > unitsPerEvent, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Types `text` as Unicode key events, no modifiers. Builds every event
    /// first, then posts them back to back.
    @discardableResult
    static func type(_ text: String) -> Bool {
        guard let source = source() else { return false }
        var events: [CGEvent] = []
        for piece in chunks(text) {
            let units = Array(piece.utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return false }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                events.append(event)
            }
        }
        events.forEach(post)
        return true
    }
}
