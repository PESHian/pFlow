import Cocoa
import Carbon
import InputMethodKit
import os

/// Reason lines, the same subsystem as pFlow's (fixed words, no text, no client names).
let reasons = Logger(subsystem: "com.pesh.pflow", category: "inputmethod")

/// The input method's side of the private channel, and its one take.
final class Link {
    static let shared = Link()

    private var fd: Int32 = -1
    private var buffer = Data()
    private var current: PFlowInputController?
    private var currentClient: (IMKTextInput & NSObjectProtocol)?
    /// When the current client was activated. pFlow selects this input source
    /// right after it sends a take's begin, so the take binds to the client
    /// activated then; an older activation is not the take's client.
    private var activatedAt = Date.distantPast
    /// The current controller was activated and IMK has not deactivated it
    /// since. Re-selecting this source while IMK still has it active brings
    /// no new activation (VM logs: none for 1.9 s after the select), so a
    /// take binds to that still-active client at once.
    private var currentActive = false

    /// The take pFlow started: the app it must be in, the client it is bound
    /// to (once activated there), the person's source to restore if pFlow goes away.
    private struct Take {
        let id: String
        let bundle: String
        let source: String?
        /// The controller of the client the take is bound to (one per text client; its
        /// own ID string is not stable from call to call).
        var uid: ObjectIdentifier?
        var marked = ""
        var broken: String?
    }
    private var take: Take?

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
            commitMarkedAsIs()
            restoreSource()
            take = nil
        }
        connectSoon(after: 0.5)
    }

    // MARK: Messages from pFlow

    private func handle(_ message: InputMethodWire.Message) {
        switch message.kind {
        case .begin:
            guard let id = message.take, let bundle = message.bundle else { return }
            reasons.notice("begin; last activation \(Int(Date().timeIntervalSince(self.activatedAt) * 1000), privacy: .public) ms ago, still active \(self.currentActive, privacy: .public)")
            take = Take(id: id, bundle: bundle, source: message.source)
            // Bound now only when the client was activated a moment ago (this input method was just started
            // by the selection); otherwise by the activation the selection brings.
            if currentActive || Date().timeIntervalSince(activatedAt) < 1.0 { bindIfPossible() }
        case .mark:
            guard let text = message.text else { return }
            let ok = write { client in
                let length = (text as NSString).length
                client.setMarkedText(text, selectionRange: NSRange(location: length, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                take?.marked = text
            }
            let marked = ok ? currentClient?.markedRange().length : nil
            send(.init(.marked, take: message.take, seq: message.seq, ok: ok, markedLength: marked == NSNotFound ? nil : marked))
        case .commit:
            guard let text = message.text else { return }
            let ok = write { client in
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                take?.marked = ""
            }
            guard ok else { send(.init(.committed, take: message.take, ok: false)); return }
            readBack(text, take: message.take, tries: 4)
        case .cancel:
            _ = write { client in
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                take?.marked = ""
            }
        case .keep:
            commitMarkedAsIs()
        case .end:
            // Words shown are never left half-done: anything still marked is committed as it is.
            commitMarkedAsIs()
            take = nil
        default:
            break
        }
    }

    /// The finished text shows right before the caret.
    private func readBack(_ text: String, take id: String?, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            var seen = false
            if let client = currentClient, take?.broken == nil {
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

    /// Runs `body` only against the take's own client, never another one.
    private func write(_ body: (IMKTextInput & NSObjectProtocol) -> Void) -> Bool {
        guard let take else { reasons.notice("write refused: no take"); return false }
        guard take.broken == nil else { reasons.notice("write refused: take interrupted"); return false }
        guard let uid = take.uid else { reasons.notice("write refused: not bound to a client"); return false }
        guard let client = currentClient, let current else { reasons.notice("write refused: no active client"); return false }
        guard ObjectIdentifier(current) == uid else { reasons.notice("write refused: another client"); return false }
        body(client)
        return true
    }

    // MARK: Activations and the person's input

    func activated(_ controller: PFlowInputController, client: (IMKTextInput & NSObjectProtocol)?) {
        current = controller
        currentClient = client
        activatedAt = Date()
        currentActive = true
        if take == nil { checkOrphanedSoon() }
        reasons.notice("activated controller \(UInt(bitPattern: ObjectIdentifier(controller).hashValue) % 10000, privacy: .public) take \(self.take != nil, privacy: .public) bound \(self.take?.uid != nil, privacy: .public)")
        if let take, let uid = take.uid, ObjectIdentifier(controller) != uid {
            if take.marked.isEmpty, client?.bundleIdentifier() == take.bundle, take.broken == nil {
                // Nothing shown yet, same app: the client that came active is the take's (pFlow checks the field itself).
                self.take?.uid = ObjectIdentifier(controller)
                reasons.notice("rebound before any words")
            } else {
                reasons.notice("activated in another client during a take")
                broken("clientChanged")
            }
        }
        bindIfPossible()
        reportClient()
    }

    /// IMK delivers activations and deactivations in no reliable order, so a
    /// deactivation never forgets the client: only another client's
    /// activation replaces it (and ends a take bound elsewhere). pFlow checks
    /// the app and field itself before every write.
    func deactivated(_ controller: PFlowInputController) {
        reasons.notice("deactivated controller \(UInt(bitPattern: ObjectIdentifier(controller).hashValue) % 10000, privacy: .public) current \(self.current === controller, privacy: .public)")
        if current === controller { currentActive = false }
    }

    /// Selected with no take and no pFlow to talk to (pFlow died between the
    /// switch and its begin, or quit): after a few seconds the person's own
    /// source comes back, the one pFlow saved before switching.
    private func checkOrphanedSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            guard take == nil, fd < 0, Self.selectedSourceID() == InputMethodWire.sourceID else { return }
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
        guard controller === current, take?.uid != nil, take?.broken == nil else { return }
        commitMarkedAsIs()
        broken(kind)
    }

    func appCommits(_ controller: PFlowInputController) {
        guard controller === current, let take, take.uid != nil, take.broken == nil, !take.marked.isEmpty else { return }
        commitMarkedAsIs()
        broken("appCommit")
    }

    private func bindIfPossible() {
        guard var take, take.uid == nil, let client = currentClient, let current, client.bundleIdentifier() == take.bundle else { return }
        take.uid = ObjectIdentifier(current)
        self.take = take
        reasons.notice("bound to the take's client")
        reportClient()
    }

    private func broken(_ reason: String) {
        guard take != nil, take?.broken == nil else { return }
        reasons.notice("take interrupted: \(reason, privacy: .public)")
        take?.broken = reason
        send(.init(.interrupted, take: take?.id, reason: reason))
    }

    /// The words shown stay in the field exactly as they are.
    private func commitMarkedAsIs() {
        guard let marked = take?.marked, !marked.isEmpty, let client = currentClient, let current,
              let uid = take?.uid, ObjectIdentifier(current) == uid else { return }
        client.insertText(marked, replacementRange: NSRange(location: NSNotFound, length: 0))
        take?.marked = ""
    }

    private func reportClient() {
        send(.init(.client, take: take?.uid != nil ? take?.id : nil, bundle: currentClient?.bundleIdentifier()))
    }

    private func restoreSource() {
        guard let id = take?.source,
              let list = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return }
        TISSelectInputSource(source)
    }
}
