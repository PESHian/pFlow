import Foundation

/// One step of a take's transcript. `text` is the whole transcript so far,
/// never an appended chunk: a recognizer may rewrite earlier words at any time.
/// The same shape is used by the Windows app and by the shared fixtures in
/// `fixtures/live-text/transcript-updates`.
struct TranscriptUpdate: Equatable, Codable, Sendable {
    let session: String
    let sequence: Int
    let text: String
    let isFinal: Bool
}

/// Decides which transcript updates count. It drops updates from another
/// take, updates that arrive out of order or twice, and anything that comes
/// after the take was finished or cancelled. No UI and no engine in here.
struct LiveTranscriptReconciler {
    enum Phase: String, Equatable { case idle, open, final, cancelled }

    private(set) var session: String?
    private(set) var phase: Phase = .idle
    private(set) var text = ""
    private(set) var lastSequence: Int?

    mutating func begin(session: String) {
        self = LiveTranscriptReconciler()
        self.session = session
        phase = .open
    }

    /// Applies `update` if it belongs. Returns true when the visible text changed.
    @discardableResult
    mutating func apply(_ update: TranscriptUpdate) -> Bool {
        guard phase == .open, update.session == session else { return false }
        if let lastSequence, update.sequence <= lastSequence { return false }
        lastSequence = update.sequence
        if update.isFinal { phase = .final }
        guard update.text != text else { return false }
        text = update.text
        return true
    }

    mutating func cancel() {
        guard phase != .idle else { return }
        phase = .cancelled
        text = ""
    }
}

/// Numbers a take's transcript revisions where the engine produces them and
/// hands only the newest one to the main thread. A burst of engine results
/// becomes one main-thread update; nothing here touches UI or runs inference.
final class LiveTranscriptFeed: @unchecked Sendable {
    let session: String
    private let lock = NSLock()
    private var nextSequence = 0
    private var pending: TranscriptUpdate?
    private var drainScheduled = false
    private var closed = false
    private let deliver: @MainActor (TranscriptUpdate) -> Void

    init(session: String, deliver: @escaping @MainActor (TranscriptUpdate) -> Void) {
        self.session = session
        self.deliver = deliver
    }

    /// Safe from any thread. Ignored after `finish` or `close`.
    func post(_ text: String) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        let update = TranscriptUpdate(session: session, sequence: nextSequence, text: text, isFinal: false)
        nextSequence += 1
        pending = update
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { drain() } }
    }

    /// The take's last update. Numbered after every partial, so a partial that
    /// is still on its way to the main thread can never replace it.
    func finish(_ text: String) -> TranscriptUpdate {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        pending = nil
        let update = TranscriptUpdate(session: session, sequence: nextSequence, text: text, isFinal: true)
        nextSequence += 1
        return update
    }

    /// Stops delivering anything for this take.
    func close() {
        lock.lock()
        closed = true
        pending = nil
        lock.unlock()
    }

    @MainActor private func drain() {
        lock.lock()
        let update = pending
        pending = nil
        drainScheduled = false
        lock.unlock()
        if let update { deliver(update) }
    }
}

enum LivePreviewText {
    /// The end of a long transcript, cut at a word so the preview never opens
    /// on half a word. History always keeps the full text; this is display only.
    static func tail(of text: String, limit: Int = 240) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -limit)
        var tail = String(trimmed[start...])
        let startsMidWord = !trimmed[trimmed.index(before: start)].isWhitespace
        if startsMidWord, let space = tail.firstIndex(where: \.isWhitespace) {
            let rest = tail[space...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { tail = rest }
        }
        return "…" + tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
