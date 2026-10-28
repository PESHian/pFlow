import Cocoa
import Carbon
import InputMethodKit
import os

/// Reason lines, the same subsystem as pFlow's (fixed words, no text, no client
/// names), kept only while pFlow's Troubleshooting log is on (`TroubleshootingLog`).
struct ReasonLines {
    private let logger = Logger(subsystem: "com.pesh.pflow", category: "inputmethod")

    func notice(_ line: String) {
        let on = TroubleshootingLog.isOn
        #if DEBUG
        logger.notice("\(line, privacy: .public)")
        #else
        if on { logger.notice("\(line, privacy: .public)") }
        #endif
        if on { TroubleshootingLog.append(line, by: .inputMethod) }
    }

    /// Only in the system log, and only on a test Mac.
    func debug(_ line: String) {
        #if DEBUG
        logger.debug("\(line, privacy: .public)")
        #endif
    }
}

let reasons = ReasonLines()

/// The input method's side of the private channel, and its one take.
final class Link {
    static let shared = Link()

    private var fd: Int32 = -1
    private var buffer = Data()
    private var current: PFlowInputController?
    private var currentClient: IMKClient?
    private var activatedAt: TimeInterval = 0
    /// Which client the take writes to, and what it wrote (InputMethodTakeCore, shared and tested).
    private let core = InputMethodTakeCore()

    /// The take pFlow started: the app it must be in, the person's source to restore if pFlow goes away.
    private struct Take {
        let id: String
        let bundle: String
        let source: String?
        var broken: String?
        var simulateNoActivation = false
        var simulateAppCommit = false
    }
    private var take: Take?
    #if DEBUG
    /// The client of the last take, for the simulation of macOS sending no activation.
    private var lastTakeClient: (PFlowInputController, IMKClient)?
    #endif

    func start() {
        connectSoon(after: 0)
    }

    // MARK: Channel

    private func connectSoon(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            if fd < 0 { connect() }
        }
    }

    private func connect() {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0, var addr = InputMethodWire.address(InputMethodWire.socketPath) else { connectSoon(after: 0.5); return }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        // Retried twice a second, so a pFlow that just started is reached before its first take.
        guard ok, verifyServer(socket) else { close(socket); connectSoon(after: 0.5); return }
        fd = socket
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        reportClient()
        let thread = Thread { [self] in readLoop(socket) }
        thread.start()
    }

    /// The server must be pFlow, the very app this input method shipped in:
    /// its signing identifier, and its embedded copy of this input method
    /// whose designated requirement this running code satisfies.
    private func verifyServer(_ socket: Int32) -> Bool {
        guard let peer = InputMethodWire.peerCode(socket),
              InputMethodWire.identifier(peer) == InputMethodWire.appIdentifier,
              SecCodeCheckValidity(peer, [], nil) == errSecSuccess,
              let app = InputMethodWire.path(peer),
              let requirement = InputMethodWire.requirement(ofBundle: InputMethodWire.embedded(in: app)) else { return false }
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        return InputMethodWire.satisfies(me, requirement)
    }

    private func readLoop(_ socket: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        while true {
            let n = recv(socket, &chunk, chunk.count, 0)
            if n <= 0 { break }
            pending.append(chunk, count: n)
            guard let messages = InputMethodWire.unframe(&pending) else { break }
            for message in messages { DispatchQueue.main.async { [self] in handle(message) } }
        }
        DispatchQueue.main.async { [self] in lost(socket) }
    }

    private func send(_ message: InputMethodWire.Message) {
        guard fd >= 0 else { return }
        _ = InputMethodWire.send(message, on: fd)
    }

    /// pFlow went away (quit or crashed) mid-take: the shown words are
    /// committed as they are, and the person's own input source comes back.
    private func lost(_ socket: Int32) {
        if fd == socket { close(fd); fd = -1 }
        if take != nil {
            core.keepAsIs()
            restoreSource()
            take = nil
            core.end()
        }
        connectSoon(after: 0.5)
    }

    // MARK: Messages from pFlow

    private func handle(_ message: InputMethodWire.Message) {
        switch message.kind {
        case .begin:
            guard let id = message.take, let bundle = message.bundle else { return }
            take = Take(id: id, bundle: bundle, source: message.source)
            #if DEBUG
            if message.simulateAppCommit == true { take?.simulateAppCommit = true }
            if message.simulateNoActivation == true {
                take?.simulateNoActivation = true
                if let (controller, client) = lastTakeClient { current = controller; currentClient = client }
            }
            #endif
            // Only a client activated since pFlow selected the source for this take.
            let event = core.begin(bundle: bundle, after: message.at ?? .infinity)
            if event == .none { reasons.notice("begin: no activation for this take yet") }
            apply(event)
        case .rebind:
            guard message.take == take?.id else { return }
            let event = core.rebind(after: message.at ?? .infinity)
            if event == .none { reasons.notice("rebind: no activation for this take yet") }
            apply(event)
        case .probe:
            guard let take, message.take == take.id, take.broken == nil, let current, let client = currentClient else { return }
            let window = message.frame.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            #if DEBUG
            let caret = client.caretRect ?? .zero
            reasons.notice("trace probe: caret \(Int(caret.midX)),\(Int(caret.midY)) window \(Int(window?.minX ?? -1)),\(Int(window?.minY ?? -1)) \(Int(window?.width ?? -1))x\(Int(window?.height ?? -1)) same app \(client.bundle == take.bundle ? "yes" : "no")")
            #endif
            if core.probe(ObjectIdentifier(current), client: client, window: window) {
                reasons.notice("probation: the client still active in the app, until pFlow sees the words in the target")
                reportClient()
            } else {
                reasons.notice("probation refused: another app or another window")
            }
        case .confirm:
            guard message.take == take?.id else { return }
            core.confirm()
        case .mark:
            guard let text = message.text else { return }
            let ok = write { controller, client in core.mark(text, controller: controller, client: client) }
            #if DEBUG
            // The app commits the composition itself (as Chrome does on a blur), telling no input method.
            if ok, take?.simulateAppCommit == true, core.binding.provisional != nil {
                currentClient?.client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                reasons.notice("trace: the app committed the marked words itself (simulated)")
            }
            #endif
            send(.init(.marked, take: message.take, seq: message.seq, ok: ok))
        case .commit:
            guard let text = message.text else { return }
            let ok = write { controller, client in core.commit(text, controller: controller, client: client) }
            guard ok else { send(.init(.committed, take: message.take, ok: false)); return }
            readBack(text, take: message.take, tries: 4)
        case .cancel:
            // Back out of the very client that shows the words, with an empty mark, and confirmed gone.
            #if DEBUG
            if let client = currentClient {
                reasons.notice("trace take-back: caret \(client.caretLocation ?? -1) length \(client.textLength ?? -1) marked \(client.markedLength)")
            }
            #endif
            let result = core.clear()
            #if DEBUG
            if let client = currentClient {
                reasons.notice("trace take-back after: caret \(client.caretLocation ?? -1) result \(result.rawValue)")
            }
            #endif
            if result != .gone { reasons.notice("take-back not proven: \(result.rawValue)") }
            send(.init(.cleared, take: message.take, ok: result == .gone, reason: result.rawValue))
        case .keep:
            core.keepAsIs()
        case .end:
            // Words shown are never left half-done: kept as they are where confirmed, taken out elsewhere.
            core.keepAsIs()
            #if DEBUG
            if let current, let currentClient, core.mayCommit(ObjectIdentifier(current)) { lastTakeClient = (current, currentClient) }
            #endif
            take = nil
            core.end()
        default:
            break
        }
    }

    /// The finished text shows right before the caret.
    private func readBack(_ text: String, take id: String?, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            var seen = false
            if let client = currentClient?.client, take?.broken == nil, core.mayCommit(current.map(ObjectIdentifier.init)) {
                let caret = client.selectedRange().location
                let length = (text as NSString).length
                if caret != NSNotFound, caret >= length {
                    var actual = NSRange()
                    let range = NSRange(location: caret - length, length: length)
                    let shown = client.attributedSubstring(from: range)?.string
                        ?? client.string(from: range, actualRange: &actual)
                    seen = shown == text
                }
            }
            if seen || tries <= 1 {
                send(.init(.committed, take: id, ok: true, seen: seen))
            } else {
                readBack(text, take: id, tries: tries - 1)
            }
        }
    }

    /// Runs `body` only while a take is on and not interrupted, with the client active now.
    private func write(_ body: (ObjectIdentifier, IMKClient) -> Bool) -> Bool {
        guard let take else { reasons.notice("write refused: no take"); return false }
        guard take.broken == nil else { reasons.notice("write refused: take interrupted"); return false }
        guard let client = currentClient, let current else { reasons.notice("write refused: no active client"); return false }
        guard body(ObjectIdentifier(current), client) else { reasons.notice("write refused: not the take's client"); return false }
        return true
    }

    private func apply(_ event: InputMethodBinding.Event) {
        switch event {
        case .bound: reasons.notice("bound to a client activated for this take"); reportClient()
        case .rebound: reasons.notice("rebound to a newer client of this take before any words"); reportClient()
        case .changed: reasons.notice("activated in another client during a take"); broken("clientChanged")
        case .none: break
        }
    }

    // MARK: Activations and the person's input

    func activated(_ controller: PFlowInputController, client: (IMKTextInput & NSObjectProtocol)?) {
        #if DEBUG
        let same = current.map { $0 === controller } ?? false
        reasons.notice("trace activated: \(same ? "same controller" : "new controller"), take \(self.take != nil ? "yes" : "no")")
        if take?.simulateNoActivation == true { return }
        #endif
        current = controller
        currentClient = client.map(IMKClient.init)
        activatedAt = ProcessInfo.processInfo.systemUptime
        if take == nil { checkOrphanedSoon(); reasons.debug("activated with no take") }
        let activation = InputMethodBinding.Activation(controller: ObjectIdentifier(controller), bundle: client?.bundleIdentifier(), at: activatedAt)
        let event = core.activated(activation)
        if event == .none, take != nil, core.binding.bound == nil, core.binding.provisional == nil {
            let why = activation.bundle == core.binding.bundle ? "before the take's selection" : "another app"
            reasons.notice("activation not bound: \(why)")
        }
        apply(event)
        reportClient()
    }

    /// IMK delivers activations and deactivations in no reliable order; a
    /// deactivation changes nothing here. A take writes only to the client
    /// bound for it, and pFlow checks the target field itself.
    func deactivated(_ controller: PFlowInputController) {
        #if DEBUG
        let same = current.map { $0 === controller } ?? false
        reasons.notice("trace deactivated: \(same ? "current controller" : "other controller"), take \(self.take != nil ? "yes" : "no")")
        #endif
    }

    /// Selected with no take and no pFlow to talk to (pFlow died between the
    /// switch and its begin, or quit): after a few seconds the person's own
    /// source comes back, the one pFlow saved before switching.
    private func checkOrphanedSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + InputMethodBinding.orphanDelay) { [self] in
            guard InputMethodBinding.orphanRestoreDue(hasTake: take != nil, connected: fd >= 0,
                                                     selectedIsOurs: Self.selectedSourceID() == InputMethodWire.sourceID,
                                                     sinceActivation: ProcessInfo.processInfo.systemUptime - activatedAt) else { return }
            let saved = CFPreferencesCopyAppValue("inputMethodRestoreSource" as CFString, InputMethodWire.appIdentifier as CFString) as? String
            if let saved, Self.select(saved) {
                reasons.notice("orphaned selection: the person's source restored")
            } else if let fallback = Self.firstOtherKeyboardSource(), Self.select(fallback) {
                reasons.notice("orphaned selection: a keyboard layout restored")
            }
        }
    }

    static func select(_ id: String) -> Bool {
        guard let list = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return false }
        return TISSelectInputSource(source) == noErr
    }

    static func firstOtherKeyboardSource() -> String? {
        let list = (TISCreateASCIICapableInputSourceList()?.takeRetainedValue() as? [TISInputSource]) ?? []
        for source in list {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            if id != InputMethodWire.sourceID { return id }
        }
        return nil
    }

    static func selectedSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    func personInput(_ kind: String, controller: PFlowInputController) {
        guard core.mayMark(ObjectIdentifier(controller)), take?.broken == nil else { return }
        core.keepAsIs()
        broken(kind)
    }

    func appCommits(_ controller: PFlowInputController) {
        guard core.mayMark(ObjectIdentifier(controller)), let take, take.broken == nil, core.hasMarks else { return }
        core.keepAsIs()
        broken("appCommit")
    }

    private func broken(_ reason: String) {
        guard take != nil, take?.broken == nil else { return }
        reasons.notice("take interrupted: \(reason)")
        take?.broken = reason
        send(.init(.interrupted, take: take?.id, reason: reason))
    }

    private func reportClient() {
        let provisional = core.binding.provisional != nil
        send(.init(.client, take: core.binding.bound != nil || provisional ? take?.id : nil, bundle: currentClient?.bundle,
                   provisional: provisional))
    }

    private func restoreSource() {
        guard let id = take?.source,
              let list = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return }
        TISSelectInputSource(source)
    }
}

/// The IMK text client, as the shared take core sees it.
final class IMKClient: MarkedTextClient {
    let client: IMKTextInput & NSObjectProtocol
    init(_ client: IMKTextInput & NSObjectProtocol) { self.client = client }

    var bundle: String? { client.bundleIdentifier() }

    func setMarked(_ text: String) {
        let length = (text as NSString).length
        client.setMarkedText(text, selectionRange: NSRange(location: length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func insert(_ text: String) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    var markedLength: Int {
        let range = client.markedRange()
        return range.location == NSNotFound ? 0 : range.length
    }

    var caretRect: CGRect? {
        let selected = client.selectedRange()
        guard selected.location != NSNotFound else { return nil }
        var actual = NSRange()
        let rect = client.firstRect(forCharacterRange: selected, actualRange: &actual)
        return rect == .zero ? nil : rect
    }

    var caretLocation: Int? {
        let selected = client.selectedRange()
        return selected.location == NSNotFound ? nil : selected.location
    }

    var textLength: Int? {
        let length = client.length()
        return length == NSNotFound ? nil : length
    }

    func text(in range: NSRange) -> String? {
        var actual = NSRange()
        return client.attributedSubstring(from: range)?.string ?? client.string(from: range, actualRange: &actual)
    }
}
