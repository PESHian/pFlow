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
        /// Marks the client showed at the length sent, and marks it did not.
        var shown = 0
        var unshown = 0
        var lastLength = 0
    }

    private(set) var take: Take?
    private(set) var connected = false
    /// How long the input method has to become active in the app before pFlow uses its other paths.
    static let attachTimeout: TimeInterval = 1.8
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

    #if DEBUG
    var connectedForTesting: Bool {
        get { connected }
        set { connected = newValue }
    }
    func adoptForTesting() { sendBegin() }
    #endif

    /// Live words can go through the input method: the person has added it.
    /// Selecting it starts it if it is not running; the take waits for it.
    var usable: Bool { enabled() }

    // MARK: Take

    /// Selects pFlow's input source for a take in `bundle`. False when it cannot be used.
    func begin(id: String, bundle: String) -> Bool {
        end()
        guard usable else { return false }
        let previous = currentSource()
        guard previous != InputMethodWire.sourceID || defaults.string(forKey: Self.restoreKey) != nil else { return false }
        let restoreTo = previous == InputMethodWire.sourceID ? defaults.string(forKey: Self.restoreKey) : previous
        defaults.set(restoreTo, forKey: Self.restoreKey)
        take = Take(id: id, bundle: bundle, previous: restoreTo, started: clock())
        sendBegin()
        if previous == InputMethodWire.sourceID {
            // Already selected (left over): the input method binds to its active client on begin.
        } else if !selectSource(InputMethodWire.sourceID) {
            take = nil
            return false
        }
        ReasonLog.note("input source switched for the take")
        return true
    }

    private func sendBegin() {
        guard let take, !take.beginSent, connected,
              transmit(.init(.begin, take: take.id, bundle: take.bundle, source: take.previous)) else { return }
        self.take?.beginSent = true
    }

    /// Whether the input method is active in the take's app yet.
    func attachState() -> Attach {
        guard var take else { return .failed("no take") }
        let waited = clock() - take.started
        if take.attach == .pending, waited > Self.attachTimeout {
            take.attach = .failed("timeout")
            self.take = take
        }
        return self.take?.attach ?? .failed("no take")
    }


    /// The whole current transcript as replaceable marked text.
    func mark(_ text: String) -> Bool {
        guard var take, take.attach == .attached, take.interrupted == nil else { return false }
        take.updates += 1
        take.seq += 1
        take.lastLength = (text as NSString).length
        let sent = transmit(.init(.mark, take: take.id, text: text, seq: take.seq))
        if sent { take.marked = true }
        self.take = take
        return sent
    }

    func noteHeldSkip() { take?.heldSkips += 1 }

    var interrupted: String? { take?.interrupted }

    /// Commits the finished text once over the marked text; waits for the input method's answer.
    func commit(_ text: String) async -> (ok: Bool, seen: Bool) {
        guard let take, take.attach == .attached, take.interrupted == nil else { return (false, false) }
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

    /// Ends the take: the person's input source comes back. Safe to call more than once.
    func end() {
        guard let take else { return }
        _ = transmit(.init(.end, take: take.id))
        restore(take)
        ReasonLog.note("input method take:", LogCounts(["updates": take.updates, "marks": take.seq, "acked": take.acked,
                                                        "shown": take.shown, "unshown": take.unshown, "heldSkips": take.heldSkips]))
        self.take = nil
    }

    private func restore(_ take: Take) {
        guard !take.restored else { return }
        self.take?.restored = true
        if currentSource() == InputMethodWire.sourceID, let previous = take.previous {
            ReasonLog.note(selectSource(previous) ? "input source restored" : "input source could not be restored")
        } else {
            ReasonLog.note("input source already the person's")
        }
    }

    /// At launch: a source left on pFlow's (pFlow quit mid-take) goes back to the person's.
    func restoreLeftover() {
        guard currentSource() == InputMethodWire.sourceID, let previous = defaults.string(forKey: Self.restoreKey) else { return }
        ReasonLog.note(selectSource(previous) ? "input source restored at launch" : "input source could not be restored at launch")
    }

    // MARK: Messages from the input method

    func receive(_ message: InputMethodWire.Message) {
        switch message.kind {
        case .client:
            guard var take, take.attach == .pending, message.take == take.id else { return }
            take.attach = message.bundle == take.bundle ? .attached : .failed("other app")
            self.take = take
        case .marked:
            guard message.take == take?.id else { return }
            guard message.ok == true else { interrupt("clientChanged"); return }
            take?.acked += 1
            // The client must show the marked text at the length sent; a client that takes it but
            // shows nothing (macOS left the source inactive there) means nothing of pFlow's is in the field.
            if message.markedLength == take?.lastLength { take?.shown += 1 } else { take?.unshown += 1 }
            if take?.shown == 0, (take?.unshown ?? 0) >= 2 { interrupt("notShown") }
        case .interrupted:
            guard message.take == take?.id else { return }
            interrupt(message.reason ?? "uncertain")
        case .committed:
            guard message.take == commitTake else { return }
            answerCommit(ok: message.ok == true, seen: message.seen == true)
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
                self?.readLoop(client)
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
