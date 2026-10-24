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

    private enum State { case off, starting, on }

    private let lock = NSLock()
    private var lastAction: UInt64 = 0
    private var tracker = CompositionTracker()
    /// Tests: in place of the tap thread (a stand-in that marks the watch running).
    var launcherForTesting: ((PersonInput) -> Void)?
    /// Tests: the tap's health when there is no real tap.
    var healthForTesting: (() -> Bool)?
    /// Tests: how often the watch was stopped.
    private(set) var stops = 0
    /// What `start` and the trust check ask; tests make it false so no tap is made.
    private let isTrusted: () -> Bool
    /// The last trust value `follow` was given (tests read it).
    private(set) var followsTrust: Bool?

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var state = State.off
    /// Tests only: what `watching` reports without a tap.
    private var watchingOverride: Bool?

    /// Nanoseconds on the clock `acted(since:)` compares against.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// True only while key presses and clicks are really being seen: the tap
    /// exists, is still valid and enabled, and pFlow is still trusted.
    var watching: Bool {
        let (override, healthy) = lock.withLock { () -> (Bool?, Bool) in
            guard state == .on else { return (watchingOverride, false) }
            guard let tap else { return (watchingOverride, healthForTesting?() ?? false) }
            return (watchingOverride, CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap))
        }
        if let override { return override }
        return healthy && isTrusted()
    }

    /// Whether the person pressed a key or clicked at or after `time`; nil
    /// when nothing is watching, so nobody can say.
    func acted(since time: UInt64) -> Bool? {
        guard watching else { return nil }
        return lock.withLock { lastAction >= time }
    }

    /// At the start of a take: an open composition (CompositionTracker.snapshot)
    /// for the input method selected now (read by the caller on the main thread), and when.
    func compositionSnapshot(sourceID: String?) -> (composing: Bool, at: UInt64) {
        let now = Self.now()
        return (lock.withLock { tracker.snapshot(at: now, sourceID: sourceID) }, now)
    }

    /// During or at the end of a take that started with `snapshot`, for the
    /// input method selected now. A plain layout now: never composing.
    func composing(since snapshot: (composing: Bool, at: UInt64), sourceID: String?) -> Bool {
        lock.withLock { tracker.composing(snapshot: snapshot.composing, takeStart: snapshot.at, sourceID: sourceID) }
    }

    /// Tests: the tracker as it is now.
    var trackerForTesting: CompositionTracker { lock.withLock { tracker } }

    /// Follows the Accessibility grant: watching while trusted, and a fresh
    /// tap once trust comes back (a tap from before a revoke can stay
    /// "enabled" and see nothing). Called from every permission refresh.
    func follow(trusted: Bool) {
        followsTrust = trusted
        if trusted { start() } else { stop() }
    }

    /// Starts watching once Accessibility is granted; safe to call every
    /// take. A tap that the system disabled or invalidated is replaced.
    func start() {
        guard isTrusted() else { return }
        let current = lock.withLock { state }
        if current == .starting || (current == .on && watching) { return }
        if current == .on { stop() }
        lock.withLock { state = .starting }
        if let launcherForTesting { launcherForTesting(self); return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "pFlow person input"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops watching; `watching` is false until `start` succeeds again.
    func stop() {
        lock.withLock {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let runLoop { CFRunLoopStop(runLoop) }
            tap = nil
            runLoop = nil
            state = .off
            stops += 1
        }
    }

    /// Tests: what the tap thread does once its tap is running.
    func markRunningForTesting() { lock.withLock { state = .on } }

    #if DEBUG
    /// Self-test only: the system shutting the tap down under pFlow.
    func invalidateTapForTesting() {
        lock.withLock { if let tap { CFMachPortInvalidate(tap) } }
    }
    #endif

    /// Tests only: pretend the tap is (or is not) running.
    func overrideWatching(_ value: Bool?) { lock.withLock { watchingOverride = value } }

    /// What one key press or click by the person records. A key with
    /// Command or Control held is a shortcut (pFlow's own hotkey among them),
    /// never part of a composition.
    func record(keyCode: Int64?, flags: CGEventFlags = [], clickCommits: Bool = true, at time: UInt64 = PersonInput.now()) {
        lock.withLock {
            lastAction = time
            guard let keyCode else { tracker.click(commits: clickCommits, at: time); return }
            let shortcut = !flags.intersection([.maskCommand, .maskControl]).isEmpty
            tracker.key(keyCode, shortcut: shortcut, at: time)
        }
    }

    /// The input source selected for the key pressed at `time`, read on the main thread.
    func stampSource(at time: UInt64, source: String) {
        lock.withLock { tracker.stamp(at: time, source: source) }
    }

    /// Whether a click at `point` (global, top-left origin) commits an open
    /// composition. A click on the input method's candidate list does not:
    /// on macOS 27 that list is a window above the app's normal windows
    /// (owned by the input method's process, or drawn by the app itself at a
    /// raised level), so a click on any window above level 0 counts as no
    /// commit, which errs to the safe side. A click on a normal window
    /// commits (browsers commit on blur and click). Looked up only while a
    /// composition is open.
    private func clickCommits(at point: CGPoint) -> Bool {
        guard lock.withLock({ !tracker.keys.isEmpty }) else { return true }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return Self.clickCommits(at: point, windows: windows)
    }

    /// The rule over a window list, front to back.
    static func clickCommits(at point: CGPoint, windows: [[String: Any]]) -> Bool {
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let pid = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            return layer == 0 && !isInputMethod(pid)
        }
        return true
    }

    /// An input method's own process (Kotoeri, Pinyin and other input methods' candidate windows).
    static func isInputMethod(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let id = app.bundleIdentifier?.lowercased() ?? ""
        let path = app.bundleURL?.path ?? ""
        return id.contains("inputmethod") || path.contains("/Input Methods/")
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
            NSLog("pFlow: key presses and clicks cannot be watched (no event tap); typed live words and the end replace are off")
            lock.withLock { state = .off }
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock {
            self.tap = tap
            runLoop = CFRunLoopGetCurrent()
            state = .on
        }
        NSLog("pFlow: watching key presses and clicks (\(options == .listenOnly ? "listen-only" : "pass-through") tap)")
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enabled at once; anything missed meanwhile counts as acted.
            // If it stays disabled, `watching` says so until a new tap.
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            record(keyCode: nil)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard event.getIntegerValueField(.eventSourceUserData) != SyntheticKeys.marker else { return }
            if type == .keyDown {
                let time = Self.now()
                record(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags, at: time)
                // The input source is read on the main thread (Text Input Sources must be), right after.
                DispatchQueue.main.async { [weak self] in
                    self?.stampSource(at: time, source: Self.selectedInputMethodID() ?? "")
                }
            } else {
                // Any click ends a word in Chrome, a right-click and the tab strip included (VM check),
                // except one on the input method's candidate list.
                record(keyCode: nil, clickCommits: clickCommits(at: event.location))
            }
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
    static func inputMethodSelected() -> Bool { selectedInputMethodID() != nil }

    /// The selected input method mode's ID, or nil for a plain layout or a
    /// Roman mode of an input method (which types letters directly).
    static func selectedInputMethodID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return nil }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        guard type == (kTISTypeKeyboardInputMode as String) || type == (kTISTypeKeyboardInputMethodModeEnabled as String) else { return nil }
        var id = ""
        if let idRaw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            id = Unmanaged<CFString>.fromOpaque(idRaw).takeUnretainedValue() as String
        }
        if let modeRaw = TISGetInputSourceProperty(source, kTISPropertyInputModeID) {
            let mode = Unmanaged<CFString>.fromOpaque(modeRaw).takeUnretainedValue() as String
            if mode.hasSuffix(".Roman") || mode.hasSuffix(".ABC") { return nil }
            if id.isEmpty { id = mode }
        }
        return id
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
