import AppKit
import Carbon
import CryptoKit

/// pFlow Dictation, the input method that shows live words as replaceable
/// marked text (the way Apple Dictation does) with no key events. It ships
/// inside pFlow.app; pFlow copies it to ~/Library/Input Methods at launch
/// whenever the copy there is missing or differs, so updating pFlow updates
/// it. macOS lets only the person turn a third-party input source on (in
/// Keyboard settings, once); until then pFlow uses its other live paths.
enum InputMethodInstall {
    static var embedded: URL { InputMethodWire.embedded(in: Bundle.main.bundleURL) }
    static var installed: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Input Methods").appendingPathComponent(InputMethodWire.bundleName)
    }
    static let keyboardSettings = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// Installs or updates the copy in ~/Library/Input Methods and registers it.
    static func ensure() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: embedded.path) else { return }
        if fingerprint(installed) != fingerprint(embedded) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodWire.sourceID) { app.terminate() }
            try? fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: installed)
            do {
                try fm.copyItem(at: embedded, to: installed)
                ReasonLog.note("input method installed or updated")
            } catch {
                ReasonLog.note("input method could not be installed")
                return
            }
        }
        TISRegisterInputSource(installed as CFURL)
        launch()
    }

    /// Starts pFlow Dictation in the background (once added) so the channel is up before the first take.
    static func launch() {
        guard enabled, NSRunningApplication.runningApplications(withBundleIdentifier: InputMethodWire.sourceID).isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: installed, configuration: configuration) { _, _ in }
    }

    /// Version and executable digest: any change in the shipped copy replaces the installed one.
    static func fingerprint(_ bundle: URL) -> String? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let name = info["CFBundleExecutable"] as? String,
              let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(info["CFBundleVersion"] ?? "")-\(digest)"
    }

    static func source(enabledOnly: Bool) -> TISInputSource? {
        source(id: InputMethodWire.sourceID, enabledOnly: enabledOnly)
    }

    static func source(id: String, enabledOnly: Bool) -> TISInputSource? {
        let list = TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, !enabledOnly)?.takeRetainedValue() as? [TISInputSource]
        return list?.first
    }

    /// The person has added pFlow Dictation in Keyboard settings.
    static var enabled: Bool { source(enabledOnly: true) != nil }

    static func currentSourceID() -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    @discardableResult
    static func select(_ id: String) -> Bool {
        guard let source = source(id: id, enabledOnly: true) else { return false }
        return TISSelectInputSource(source) == noErr
    }
}

/// After the input method committed the finished text: whether "Copy
/// dictation to clipboard" puts it on the clipboard. The same as the paste
/// path: whenever the text went out, seen or not.
enum InputMethodFinish {
    static func copiesToClipboard(_ result: LiveInlineFinal, keepCopy: Bool) -> Bool {
        guard keepCopy else { return false }
        return result == .applied || result == .unconfirmed
    }

    /// The target field shows one of `texts` (this take's newest marked text,
    /// or a newer one) exactly at the captured caret: the field's text before
    /// the caret, then the words, then the field's text after the selection.
    /// An editor's own line breaks at the ends and zero-width characters are
    /// set aside; a no-break space counts as a space. Words the field held
    /// before the take, or that show anywhere else, do not count.
    static func showsAtCaret(read: String?, texts: [String], before prefix: String, after suffix: String) -> Bool {
        guard let read else { return false }
        let head = clean(prefix)
        var shown = clean(read)
        if head.isEmpty { shown = String(shown.drop(while: { $0.isNewline })) }
        guard shown.hasPrefix(head) else { return false }
        let rest = String(shown.dropFirst(head.count))
        let tail = clean(suffix).trimmingCharacters(in: .newlines)
        return texts.contains { text in
            let words = clean(text)
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rest.hasPrefix(words) else { return false }
            return String(rest.dropFirst(words.count)).trimmingCharacters(in: .newlines) == tail
        }
    }

    /// At the end of a take whose target can be read: the finished text goes through the input method
    /// only when its marks were seen at the caret this take (`confirmed`) and still are. Otherwise the
    /// marks are taken back out first.
    static func takesBackFirst(targetReadable: Bool, confirmed: Bool, marksAtCaret: Bool) -> Bool {
        targetReadable && !(confirmed && marksAtCaret)
    }

    /// After marks were taken back out: the usual checked paste only once the input method proved
    /// them gone; otherwise they may be in another window, and the finished text stays on the Copy card.
    static func afterTakeBack(cleared: Bool) -> LiveInlineFinal {
        cleared ? .notTyped : .kept(.otherWindow)
    }

    static func clean(_ text: String) -> String {
        EditorPlaceholder.plain(text).filter { !["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"].contains($0) }
    }

    /// After the commit. Landed only when the target field itself shows the
    /// text; only where the target cannot be read, the input method's own
    /// read-back of the client bound for this take. "Copy dictation to
    /// clipboard" then keeps the text as the paste path does.
    static func conclude(committed ok: Bool, seenByInputMethod: Bool, targetReadable: Bool, keepCopy: Bool,
                         landedInTarget: () async -> Bool, copy: () -> Void) async -> LiveInlineFinal {
        guard ok else { return .kept(.focus) }
        let landed = targetReadable ? await landedInTarget() : seenByInputMethod
        let finished: LiveInlineFinal = landed ? .applied : .unconfirmed
        if copiesToClipboard(finished, keepCopy: keepCopy) { copy() }
        return finished
    }
}

/// Why the input method did not attach (fixed names: timeout, source changed, other app).
struct AttachReason: LogReason {
    let logName: String
    init(_ reason: String) { logName = ["timeout", "source changed", "other app", "no take"].contains(reason) ? reason : "other" }
}

/// A count line for the reason log (numbers only).
struct LogCounts: LogReason {
    let logName: String
    init(_ pairs: KeyValuePairs<String, Int>) { logName = pairs.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
}

/// pFlow's side of the channel to pFlow Dictation, and the one take that uses it.
@MainActor
final class InputMethodLink {
    static let shared = InputMethodLink()

    enum Attach: Equatable { case pending, attached, failed(String) }

    /// Why live words through the input method ended early.
    static func stop(for reason: String) -> LiveInlineOwnership.Stop {
        switch reason {
        case "key": return .text
        case "click", "appCommit": return .caret
        case "clientChanged": return .focus
        default: return .uncertain
        }
    }

    struct Take {
        let id: String
        let bundle: String
        let previous: String?
        let started: TimeInterval
        var attach: Attach = .pending
        var seq = 0
        var acked = 0
        var updates = 0
        var heldSkips = 0
        var marked = false
        var interrupted: String?
        var restored = false
        /// The begin message reached the input method (sent once it is connected).
        var beginSent = false
        /// Bounces when no activation came: odd while the person's source is selected, `reselect / 2` done.
        var reselect = 0
        /// When the begin reached the input method (the re-selection counts from then).
        var beganAt: TimeInterval?
        /// When pFlow last selected its source for this take; only later activations bind.
        var selectedAt: TimeInterval = 0
        /// Texts marked, by sequence number, and the newest one the input method confirmed.
        var sent: [Int: String] = [:]
        var lastAcked: (seq: Int, at: TimeInterval)?
        /// pFlow can read the target field: a leftover client may go on probation, and the take
        /// commits only after its marks showed there. `window`: the target window (Cocoa screen frame).
        var readable = false
        var window: [Double]?
        var probeSent = false
        /// The client is on probation (still active from before; no activation came for this take).
        var provisional = false
        /// The mark pFlow saw in the target field (0 where the target cannot be read and the client is fresh).
        var confirmedSeq: Int?
    }

    private(set) var take: Take?
    private(set) var connected = false
    /// How long the input method has to become active in the app before pFlow uses its other paths.
    static let attachTimeout: TimeInterval = 1.8
    static let reselectAfter: TimeInterval = 0.5
    static let reselectGap: TimeInterval = 0.2
    /// How many bounces, and how far apart they start: all three end before `attachTimeout`.
    static let bounces = 3
    static let bounceEvery: TimeInterval = 0.4
    /// How long pFlow waits for a fresh activation before it puts the client still active on probation.
    static let probeAfter: TimeInterval = 0.12
    static let restoreKey = "inputMethodRestoreSource"

    // The outside world, replaceable in tests.
    var enabled: () -> Bool = { InputMethodInstall.enabled }
    var currentSource: () -> String? = { InputMethodInstall.currentSourceID() }
    var selectSource: (String) -> Bool = { InputMethodInstall.select($0) }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var transmit: (InputMethodWire.Message) -> Bool = { _ in false }
    var defaults: UserDefaults = .standard

    private var listener: Int32 = -1
    private var peer: Int32 = -1
    private var commitWaiter: CheckedContinuation<(ok: Bool, seen: Bool), Never>?
    private var commitTake: String?
    private var clearWaiter: CheckedContinuation<Bool, Never>?
    private var clearTake: String?

    #if DEBUG
    var connectedForTesting: Bool {
        get { connected }
        set { connected = newValue }
    }
    func adoptForTesting() { sendBegin() }
    #endif

    /// Live words can go through the input method: the person has added it.
    /// Selecting it starts it if it is not running; the take waits for it.
    var usable: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "pflow.debug.noInputMethod") { return false }
        #endif
        return enabled()
    }

    // MARK: Take

    /// Selects pFlow's input source for a take in `bundle`. False when it cannot be used.
    func begin(id: String, bundle: String, readable: Bool = false, window: CGRect? = nil) -> Bool {
        end()
        guard usable else { return false }
        var previous = currentSource()
        if previous == InputMethodWire.sourceID {
            // Left selected (pFlow went away mid-take): the person's source first, so this take's
            // selection brings a fresh activation; a take never binds to a leftover client.
            guard let saved = defaults.string(forKey: Self.restoreKey), selectSource(saved) else { return false }
            previous = saved
        }
        // Remembered durably before the switch: if pFlow dies in between, the
        // input method (and pFlow's next launch) can still put it back.
        defaults.set(previous, forKey: Self.restoreKey)
        defaults.synchronize()
        take = Take(id: id, bundle: bundle, previous: previous, started: clock())
        take?.readable = readable
        take?.window = window.map { [$0.origin.x, $0.origin.y, $0.width, $0.height] }
        // The input method binds only to a client activated from this moment on.
        take?.selectedAt = clock()
        sendBegin()
        if !selectSource(InputMethodWire.sourceID) {
            ReasonLog.note("input source could not be selected")
            take = nil
            return false
        }
        ReasonLog.note("input source switched for the take")
        return true
    }

    private func sendBegin() {
        guard let take, !take.beginSent, connected else { return }
        var message = InputMethodWire.Message(.begin, take: take.id, bundle: take.bundle, source: take.previous, at: take.selectedAt)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "pflow.debug.simulateNoActivation") { message.simulateNoActivation = true }
        if UserDefaults.standard.bool(forKey: "pflow.debug.simulateAppCommit") { message.simulateAppCommit = true }
        #endif
        guard transmit(message) else { return }
        self.take?.beginSent = true
        self.take?.beganAt = clock()
    }

    /// Whether the input method is active in the take's app yet.
    func attachState() -> Attach {
        guard var take else { return .failed("no take") }
        let waited = clock() - take.started
        if take.attach == .pending, waited > Self.attachTimeout {
            take.attach = .failed("timeout")
            self.take = take
        } else if take.attach == .pending, let previous = take.previous, let beganAt = take.beganAt {
            let waited = clock() - beganAt
            // No fresh activation yet (macOS can leave the last take's client active and send none):
            // where pFlow can read the target, the client still active goes on probation. Its first
            // marked words must show in the target field before anything more is written through it.
            if take.readable, !take.probeSent, take.reselect == 0, waited > Self.probeAfter {
                take.probeSent = true
                self.take = take
                _ = transmit(.init(.probe, take: take.id, frame: take.window))
                return take.attach
            }
            // macOS sometimes leaves this source selected-but-inactive in the app (VM logs: no
            // activation at all after the select; the app holds it back until the next switch).
            // A bounce: select the person's source (the held-back activation arrives then, and is
            // not bound), then pFlow's again, which brings a fresh one. One bounce rescued none
            // of 6 such takes in the VM; up to three, inside the same 1.8 s wait, rescued 5 of 6.
            // Odd `reselect`: the person's source is selected; `reselect / 2` bounces are done.
            let done = take.reselect / 2, start = Self.reselectAfter + Double(done) * Self.bounceEvery
            if take.reselect.isMultiple(of: 2), done < Self.bounces, waited > start {
                // Only while the source is still the one pFlow set: a person who changed it (Ctrl-Space) is respected.
                guard currentSource() == InputMethodWire.sourceID else {
                    take.attach = .failed("source changed")
                    self.take = take
                    return take.attach
                }
                take.reselect += 1
                self.take = take
                _ = selectSource(previous)
                ReasonLog.note("no activation yet: selecting the source again")
            } else if !take.reselect.isMultiple(of: 2), waited > start + Self.reselectGap {
                guard currentSource() == previous else {
                    take.attach = .failed("source changed")
                    self.take = take
                    return take.attach
                }
                take.reselect += 1
                take.selectedAt = clock()
                self.take = take
                _ = transmit(.init(.rebind, take: take.id, at: take.selectedAt))
                _ = selectSource(InputMethodWire.sourceID)
                ReasonLog.note("no activation yet: pFlow's source selected again")
            }
        }
        return self.take?.attach ?? .failed("no take")
    }


    var provisional: Bool { take?.provisional == true }
    var confirmed: Bool { take?.confirmedSeq != nil }

    /// The target field showed mark `seq`: the client is the take's and may commit.
    func confirm(seq: Int) {
        guard let take, take.confirmedSeq == nil else { return }
        self.take?.confirmedSeq = seq
        self.take?.provisional = false
        _ = transmit(.init(.confirm, take: take.id, seq: seq))
    }

    /// The whole current transcript as replaceable marked text.
    func mark(_ text: String) -> Bool {
        guard var take, take.attach == .attached, take.interrupted == nil else { return false }
        // Marked text shows only while pFlow's source is the selected one.
        guard currentSource() == InputMethodWire.sourceID else { interrupt("notSelected"); return false }
        take.updates += 1
        take.seq += 1
        take.sent[take.seq] = text
        let sent = transmit(.init(.mark, take: take.id, text: text, seq: take.seq))
        #if DEBUG
        LiveLatency.markPost[take.seq] = LiveLatency.postAt
        #endif
        if sent { take.marked = true }
        self.take = take
        return sent
    }

    func noteHeldSkip() { take?.heldSkips += 1 }

    /// The marks that must be showing now, by sequence number: before the take is confirmed, the
    /// newest one the input method marked (or a newer one); after, any from the confirmed one on.
    /// Nil until a mark was acknowledged at least `settled` ago (the app draws it a moment later).
    func showingCandidates(settled: TimeInterval = 0.15) -> [(seq: Int, text: String)]? {
        guard let take, let acked = take.lastAcked, clock() - acked.at >= settled else { return nil }
        let from = take.confirmedSeq ?? acked.seq
        return take.sent.filter { $0.key >= from }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var interrupted: String? { take?.interrupted }

    /// Commits the finished text once over the marked text; waits for the input method's answer.
    func commit(_ text: String) async -> (ok: Bool, seen: Bool) {
        // Only through a client confirmed this take (its marks seen in the target, or fresh where it cannot be read).
        guard let take, take.attach == .attached, take.interrupted == nil, take.confirmedSeq != nil else { return (false, false) }
        guard currentSource() == InputMethodWire.sourceID else { interrupt("notSelected"); return (false, false) }
        guard transmit(.init(.commit, take: take.id, text: text)) else { return (false, false) }
        self.take?.marked = true
        commitTake = take.id
        let id = take.id
        let result = await withCheckedContinuation { continuation in
            commitWaiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard self?.commitTake == id else { return }
                self?.answerCommit(ok: false, seen: false)
            }
        }
        return result
    }

    /// The words shown so far stay as they are (typing stopped for the take).
    func freeze() {
        guard let take, take.marked, take.interrupted == nil else { return }
        // The input method commits only to the take's own client.
        self.take?.interrupted = "stopped"
        _ = transmit(.init(.keep, take: take.id))
    }

    /// Takes the marked words back out (a cancelled take).
    func cancel() {
        guard let take, take.marked, take.interrupted == nil else { return }
        _ = transmit(.init(.cancel, take: take.id))
        self.take?.marked = false
    }

    /// Takes the marked words back out and waits for the input method to report them gone.
    /// False when it does not (refused, no answer, channel lost): the words may still be showing.
    func clear() async -> Bool {
        guard let take else { return true }
        guard take.marked || take.seq > 0 else { return true }
        guard transmit(.init(.cancel, take: take.id)) else { return false }
        self.take?.marked = false
        clearTake = take.id
        let id = take.id
        return await withCheckedContinuation { continuation in
            clearWaiter = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard self?.clearTake == id else { return }
                self?.answerClear(false)
            }
        }
    }

    private func answerClear(_ ok: Bool) {
        guard let waiter = clearWaiter else { return }
        clearWaiter = nil
        clearTake = nil
        waiter.resume(returning: ok)
    }

    /// Ends the take: the person's input source comes back. Safe to call more than once.
    func end() {
        guard let take else { return }
        _ = transmit(.init(.end, take: take.id))
        restore(take)
        ReasonLog.note("input method take:", LogCounts(["updates": take.updates, "marks": take.seq, "acked": take.acked, "heldSkips": take.heldSkips]))
        self.take = nil
    }

    private func restore(_ take: Take) {
        guard !take.restored else { return }
        self.take?.restored = true
        if currentSource() == InputMethodWire.sourceID, let previous = take.previous {
            let restored = selectSource(previous)
            ReasonLog.note(restored ? "input source restored" : "input source could not be restored")
            // Never kept past a successful restore, so no later restore can bring back an old source.
            if restored { defaults.removeObject(forKey: Self.restoreKey) }
        } else {
            ReasonLog.note("input source already the person's")
            defaults.removeObject(forKey: Self.restoreKey)
        }
    }

    /// At launch: a source left on pFlow's (pFlow quit mid-take) goes back to the person's.
    func restoreLeftover() {
        guard currentSource() == InputMethodWire.sourceID, let previous = defaults.string(forKey: Self.restoreKey) else { return }
        let restored = selectSource(previous)
        ReasonLog.note(restored ? "input source restored at launch" : "input source could not be restored at launch")
        if restored { defaults.removeObject(forKey: Self.restoreKey) }
    }

    // MARK: Messages from the input method

    func receive(_ message: InputMethodWire.Message) {
        switch message.kind {
        case .client:
            // While re-selecting, the person's source is selected for a moment: an activation then is a
            // late one from before, not the take's (marks would go to a client that shows nothing).
            guard var take, message.take == take.id else { return }
            if take.attach == .attached {
                // A fresh activation replaced the client on probation before any words.
                if take.provisional, message.provisional != true { self.take?.provisional = false }
                return
            }
            guard take.attach == .pending, take.reselect.isMultiple(of: 2) else { return }
            take.attach = message.bundle == take.bundle ? .attached : .failed("other app")
            take.provisional = message.provisional == true
            self.take = take
            // Where the target cannot be read, a client activated for this take is the only check there is.
            if take.attach == .attached, !take.readable, !take.provisional { confirm(seq: 0) }
        case .marked:
            guard message.take == take?.id else { return }
            guard message.ok == true else { interrupt("clientChanged"); return }
            take?.acked += 1
            if let seq = message.seq, seq > (take?.lastAcked?.seq ?? 0) { take?.lastAcked = (seq, clock()) }
            #if DEBUG
            if let seq = message.seq, let posted = LiveLatency.markPost[seq], posted > 0 {
                LiveLatency.samples.append((ProcessInfo.processInfo.systemUptime - posted) * 1000)
            }
            #endif
        case .interrupted:
            guard message.take == take?.id else { return }
            interrupt(message.reason ?? "uncertain")
        case .committed:
            guard message.take == commitTake else { return }
            answerCommit(ok: message.ok == true, seen: message.seen == true)
        case .cleared:
            guard message.take == clearTake else { return }
            answerClear(message.ok == true)
        default:
            break
        }
    }

    private func answerCommit(ok: Bool, seen: Bool) {
        guard let waiter = commitWaiter else { return }
        commitWaiter = nil
        commitTake = nil
        waiter.resume(returning: (ok, seen))
    }

    /// The first reason the take can no longer be written is kept.
    private func interrupt(_ reason: String) {
        guard var take, take.interrupted == nil else { return }
        take.interrupted = reason
        self.take = take
    }

    /// The channel went away mid-take: nothing more is written, the source comes back.
    func lost() {
        connected = false
        interrupt("linkLost")
        answerCommit(ok: false, seen: false)
        answerClear(false)
    }

    // MARK: Socket

    /// Listens for pFlow Dictation. Only a peer whose code satisfies the
    /// designated requirement of the copy shipped inside this app is kept.
    func start() {
        guard listener < 0 else { return }
        restoreLeftover()
        let fm = FileManager.default
        try? fm.createDirectory(at: InputMethodWire.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(InputMethodWire.folder.path, 0o700)
        unlink(InputMethodWire.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = InputMethodWire.address(InputMethodWire.socketPath) else { return }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        guard bound, listen(fd, 2) == 0 else { close(fd); ReasonLog.note("input method channel could not open"); return }
        chmod(InputMethodWire.socketPath, 0o600)
        listener = fd
        transmit = { [weak self] message in
            guard let self, self.peer >= 0 else { return false }
            return InputMethodWire.send(message, on: self.peer)
        }
        let requirement = InputMethodWire.requirement(ofBundle: InputMethodInstall.embedded)
        let thread = Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                guard let requirement, let code = InputMethodWire.peerCode(client),
                      InputMethodWire.satisfies(code, requirement) else {
                    close(client)
                    DispatchQueue.main.async { ReasonLog.note("input method channel refused a peer that is not pFlow Dictation") }
                    continue
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.main.async { self?.adopt(client) }
                // Each connection reads on its own thread, so the next one is always answered (or refused).
                Thread.detachNewThread { self?.readLoop(client) }
            }
        }
        thread.start()
    }

    private func adopt(_ fd: Int32) {
        if peer >= 0, peer != fd { close(peer) }
        peer = fd
        connected = true
        ReasonLog.note("input method connected")
        sendBegin()
    }

    nonisolated private func readLoop(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            pending.append(chunk, count: n)
            guard let messages = InputMethodWire.unframe(&pending) else { break }
            for message in messages { DispatchQueue.main.async { [weak self] in self?.receive(message) } }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.peer == fd else { close(fd); return }
            close(fd)
            self.peer = -1
            self.lost()
            ReasonLog.note("input method disconnected")
        }
    }
}
