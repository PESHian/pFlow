import AppKit
import Carbon.HIToolbox

/// Watches the activation key: hold it to dictate, double-tap for continuous
/// recording, tap again to finish (`RightCommandActivation`, named for the
/// first key). A modifier is watched through flagsChanged, which says which
/// side moved. Any other key is watched by an event tap (`KeyTap`) that exists
/// only while such a key is chosen: on its own the key is taken, so the app
/// never sees it or its repeats; with a modifier already held it passes through.
@MainActor
final class ActivationKeyMonitor {
    var key: ActivationKey = .rightCommand {
        didSet {
            guard key != oldValue else { return }
            tapTask?.cancel()
            releaseTask?.cancel()
            activation.reset()
            keyTap.choose(key)
            syncTap()
        }
    }
    /// While a new key is being learned, the activation key starts nothing.
    var paused = false {
        didSet { keyTap.pause(paused) }
    }
    var onActivation: ((RightCommandActivation.Effect) -> Void)?
    var recordingIsBusy: () -> Bool = { false }
    private var activation = RightCommandActivation()
    private var tapTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var started = false
    private lazy var keyTap = KeyTap(key: key) { @Sendable [weak self] effect, time in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(effect, at: time) } }
    }

    private func emit(_ effects: [RightCommandActivation.Effect]) {
        for effect in effects {
            onActivation?(effect)
            if effect == .pause {
                tapTask?.cancel()
                tapTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(310)) } catch { return }
                    guard let self else { return }
                    self.emit(self.activation.expireTap(at: ProcessInfo.processInfo.systemUptime))
                }
            } else { tapTask?.cancel() }
        }
    }

    #if DEBUG
    /// The Debug harness reads what the monitor saw (key codes and states only,
    /// other keys only while the activation key is down), the last 200 lines.
    static var trace: [String] = []
    static func traceNote(_ line: String) {
        trace.append(line)
        if trace.count > 200 { trace.removeFirst(trace.count - 200) }
    }
    #endif

    private func combination(_ event: NSEvent) {
        #if DEBUG
        if activation.isDown { Self.traceNote("other \(event.type == .keyDown ? "key \(event.keyCode)" : "click") state \(activation.state)") }
        #endif
        // pFlow's own keys (live words, the paste) are not the person's. They
        // come while a key that is not a modifier is still held: it holds nothing back.
        if let posted = event.cgEvent, Self.isPFlows(posted) { return }
        if activation.isDown {
            NSLog("pFlow: activation key recording cancelled by a shortcut or click")
            emit(activation.interrupt())
        }
    }

    /// A flagsChanged event, while the key is a modifier.
    func modifierChanged(_ event: NSEvent) {
        guard let down = key.transition(keyCode: Int64(event.keyCode), flags: UInt64(event.modifierFlags.rawValue)) else { return }
        NSLog("pFlow: activation key \(key.keyCode) \(down ? "down" : "up"), flags=\(event.modifierFlags.rawValue)")
        // Starting audio can delay delivery. Classify the physical key times,
        // not the time the main thread finally handles their events.
        if down { pressed(at: event.timestamp) } else { released(at: event.timestamp) }
    }

    /// What the tap decided, on the main thread, in the order it decided it.
    private func apply(_ effect: ActivationKeyTap.Effect, at time: TimeInterval) {
        switch effect {
        case .press: pressed(at: time)
        case .release: released(at: time)
        case .again: released(at: time); pressed(at: time)
        }
    }

    private func pressed(at now: TimeInterval) {
        #if DEBUG
        Self.traceNote("pressed paused \(paused) state \(activation.state)")
        #endif
        guard !paused else { return }
        activation.reconcileIdle(isBusy: recordingIsBusy())
        guard activation.state != .idle || !recordingIsBusy() else { return }
        emit(activation.press(at: now))
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            // A key that is not a modifier counts as let go only after its state
            // was seen down: the tap takes it before the system records it, so
            // it ends with its own up, or the next press (`.again`). Secure
            // Input starting during the hold keeps its up from the tap, so the
            // hold ends then (Secure Input already on before the press does not).
            var seenDown = false
            let secureBefore = SecureInput.isEnabled
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard let self, self.activation.isDown else { return }
                let down = self.keyIsDown()
                seenDown = seenDown || down
                let held = self.key.isModifier ? down : (down || !seenDown) && (secureBefore || !SecureInput.isEnabled)
                let effects = self.activation.recoverRelease(keyIsDown: held, at: ProcessInfo.processInfo.systemUptime)
                if !self.activation.isDown {
                    NSLog("pFlow: activation key release recovered from key state")
                    #if DEBUG
                    Self.traceNote("release recovered")
                    #endif
                    self.emit(effects)
                    return
                }
            }
        }
    }

    private func released(at now: TimeInterval) {
        #if DEBUG
        Self.traceNote("released state \(activation.state)")
        #endif
        releaseTask?.cancel()
        emit(activation.release(at: now))
    }

    nonisolated static func isPFlows(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == SyntheticKeys.marker
    }

    /// A modifier: either side of it, as the person may still hold the other.
    private func keyIsDown() -> Bool {
        if let flag = key.flag { return CGEventSource.flagsState(.combinedSessionState).contains(flag) }
        return CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key.keyCode))
    }

    func start() {
        stop()
        started = true

        // Global monitors observe other apps; local ones cover pFlow's own windows.
        addGlobal(matching: .flagsChanged) { [weak self] event in self?.flagsChanged(event) }
        addGlobal(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.combination(event)
        }
        addLocal(matching: .flagsChanged) { [weak self] event in self?.flagsChanged(event) }
        addLocal(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.combination(event)
        }
        syncTap()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        tapTask?.cancel()
        releaseTask?.cancel()
        activation.reset()
        keyTap.choose(key)
        started = false
        syncTap()
    }

    private func flagsChanged(_ event: NSEvent) {
        if key.isModifier { modifierChanged(event) }
    }

    private func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in handler(event) }
        }) {
            monitors.append(monitor)
        }
    }

    private func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in handler(event) }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    // MARK: A key that is not a modifier

    /// The tap exists only while started with such a key chosen: pFlow is not
    /// in the key event path otherwise. Every 2 s it is checked: made when it
    /// could not be (Accessibility granted later works without a restart), made
    /// again when the system ended it, turned back on when the system turned it off.
    private func syncTap() {
        retryTask?.cancel()
        if started, !key.isModifier {
            _ = keyTap.ensure()
            retryTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, self.started, !self.key.isModifier else { return }
                    let had = self.keyTap.installed
                    if self.keyTap.ensure() != had {
                        PersonInput.setIgnoredHeldKey(self.keyTap.installed ? CGKeyCode(self.key.keyCode) : nil)
                    }
                }
            }
        } else {
            keyTap.remove()
        }
        PersonInput.setIgnoredHeldKey(keyTap.installed ? CGKeyCode(key.keyCode) : nil)
    }

    /// One key down or up as the tap sees it; true when it is taken. Tests call it without a tap.
    func keyEvent(_ event: CGEvent, down: Bool) -> Bool {
        keyTap.decide(event, down: down)
    }
}

/// The event tap for a key that is not a modifier, on its own thread, so a
/// busy main thread never delays anyone's typing and the system never turns
/// the tap off for being slow. What it decides is handed to the main thread.
final class KeyTap: @unchecked Sendable {
    private let lock = NSLock()
    private var rule = ActivationKeyTap()
    private var key: ActivationKey
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private let deliver: @Sendable (ActivationKeyTap.Effect, TimeInterval) -> Void

    init(key: ActivationKey, deliver: @escaping @Sendable (ActivationKeyTap.Effect, TimeInterval) -> Void) {
        self.key = key
        self.deliver = deliver
    }

    /// Whether the tap could not be made was logged (once, not every 2 s).
    private var loggedFailure = false

    var installed: Bool { lock.withLock { port.map(CFMachPortIsValid) ?? false } }

    deinit { remove() }

    /// The tap made, valid and on. False when it can't be made (Accessibility not granted).
    @discardableResult
    func ensure() -> Bool {
        if let port = lock.withLock({ self.port }) {
            if CFMachPortIsValid(port) {
                if !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
                return true
            }
            remove()
        }
        return install()
    }

    func choose(_ key: ActivationKey) {
        lock.withLock {
            self.key = key
            rule.reset()
        }
    }

    func pause(_ paused: Bool) { lock.withLock { rule.paused = paused } }

    private func install() -> Bool {
        if installed { return true }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyTap>.fromOpaque(info).takeUnretainedValue().handle(type, event)
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        // At the head of the HID chain: the key is taken before macOS or any app acts on it.
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            if !loggedFailure { NSLog("pFlow: could not create the activation key event tap; is Accessibility granted?") }
            loggedFailure = true
            return false
        }
        loggedFailure = false
        lock.withLock { self.port = port }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self?.lock.withLock { self?.runLoop = CFRunLoopGetCurrent() }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "pFlow activation key"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func remove() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { self.port = nil; self.runLoop = nil; rule.reset() }
            return (self.port, self.runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Turned off by the system: back on at once. A press taken before may
            // have lost its up meanwhile, so it counts as let go.
            let lost = lock.withLock { () -> Bool in
                if let port { CGEvent.tapEnable(tap: port, enable: true) }
                defer { rule.reset() }
                return rule.owned
            }
            if lost { deliver(.release, ProcessInfo.processInfo.systemUptime) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        return decide(event, down: type == .keyDown) ? nil : Unmanaged.passUnretained(event)
    }

    /// Whether to take this key event; what it starts or stops is delivered after.
    func decide(_ event: CGEvent, down: Bool) -> Bool {
        guard !ActivationKeyMonitor.isPFlows(event) else { return false }
        let (take, effect) = lock.withLock {
            rule.handle(keyCode: event.getIntegerValueField(.keyboardEventKeycode), down: down,
                        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, flags: event.flags, key: key)
        }
        if let effect { deliver(effect, ProcessInfo.processInfo.systemUptime) }
        return take
    }
}
