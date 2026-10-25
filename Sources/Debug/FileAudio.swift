#if DEBUG
@preconcurrency import AVFoundation
import Foundation

/// Plays a recording at real-time pace, without drift, in ~46 ms buffers like
/// the microphone tap. Pausing stops the clock, as pausing the engine does.
final class FileCapture: AudioCapturing, @unchecked Sendable {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    private let url: URL
    private let lock = NSLock()
    private var running = false
    private var paused = false
    private(set) var startedAt: Double?
    private(set) var endedAt: Double?

    init(url: URL) { self.url = url }

    /// Each start plays the recording again from the beginning.
    func start() throws {
        let file = try AVAudioFile(forReading: url)
        lock.withLock { running = true; paused = false; startedAt = ProcessInfo.processInfo.systemUptime; endedAt = nil }
        let thread = Thread { [self] in play(file) }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func play(_ file: AVAudioFile) {
        let rate = file.processingFormat.sampleRate
        let chunk = AVAudioFrameCount(rate * 2048 / 44_100)
        var played = 0.0
        var clock = ProcessInfo.processInfo.systemUptime
        while file.framePosition < file.length {
            let (live, hold) = lock.withLock { (running, paused) }
            guard live else { return }
            if hold { Thread.sleep(forTimeInterval: 0.01); clock += 0.01; continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
            played += Double(buffer.frameLength) / rate
            let ahead = played - (ProcessInfo.processInfo.systemUptime - clock)
            if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
            onBuffer?(buffer)
            onLevel?(AudioLevel.normalized(from: buffer))
        }
        lock.withLock { endedAt = ProcessInfo.processInfo.systemUptime }
    }

    var finished: Bool { lock.withLock { endedAt != nil } }
    func stop() { lock.withLock { running = false } }
    func pause() { lock.withLock { paused = true } }
    func resume() throws { lock.withLock { paused = false } }
}

/// The real-use harness's microphone stand-in: each take plays the recording
/// named in `next` (a path written by the harness before it presses the key),
/// at real-time pace, then nothing until the take stops. No microphone opens.
final class QueuedFileCapture: AudioCapturing, @unchecked Sendable {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        didSet { current?.onBuffer = onBuffer }
    }
    var onLevel: ((Float) -> Void)? {
        didSet { current?.onLevel = onLevel }
    }
    let next: URL
    private var current: FileCapture?

    init(next: URL) { self.next = next }

    /// The recording the current take plays (the replayed recognizer reads it).
    nonisolated(unsafe) static var currentFile: URL?

    func start() throws {
        let path = try String(contentsOf: next, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        Self.currentFile = URL(fileURLWithPath: path)
        let capture = FileCapture(url: URL(fileURLWithPath: path))
        capture.onBuffer = onBuffer
        capture.onLevel = onLevel
        current = capture
        try capture.start()
    }
    func stop() { current?.stop() }
    func pause() { current?.pause() }
    func resume() throws { try current?.resume() }
}
/// Apple's recognizer does not run in the test VM, so its real output for
/// each recording is recorded on a Mac where it does (the speed harness's
/// "apple-stream" run: every transcript the engine posted, with its time
/// from the start of recognition, and the finished text with how long the
/// finish took) and replayed here at the same times. The rest of the take is
/// pFlow's real pipeline.
final class ReplayTranscriber: StreamingTranscriber, @unchecked Sendable {
    struct Stream: Codable {
        struct Post: Codable { let ms: Double; let text: String }
        let posts: [Post]
        let final: String
        let finishMs: Double
    }

    var onTranscript: ((String) -> Void)?
    private let stream: Stream
    private let lock = NSLock()
    private var running = false

    init(stream: Stream) { self.stream = stream }

    /// The recorded stream for the recording the take plays (streams.json beside the recordings).
    static func forCurrentFile() -> StreamingTranscriber {
        let empty = Stream(posts: [], final: "", finishMs: 0)
        guard let file = QueuedFileCapture.currentFile,
              let data = try? Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("streams.json")),
              let all = try? JSONDecoder().decode([String: Stream].self, from: data) else { return ReplayTranscriber(stream: empty) }
        return ReplayTranscriber(stream: all[file.lastPathComponent] ?? empty)
    }

    func begin(locale: Locale, contextualStrings: [String]) async throws {
        lock.withLock { running = true }
        let started = ProcessInfo.processInfo.systemUptime
        let posts = stream.posts
        Thread.detachNewThread { [self] in
            for post in posts {
                let wait = started + post.ms / 1000 - ProcessInfo.processInfo.systemUptime
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                guard lock.withLock({ running }) else { return }
                onTranscript?(post.text)
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws -> String {
        lock.withLock { running = false }
        try? await Task.sleep(nanoseconds: UInt64(max(0, stream.finishMs) * 1_000_000))
        return stream.final
    }

    func cancel() async { lock.withLock { running = false } }
}
#endif
