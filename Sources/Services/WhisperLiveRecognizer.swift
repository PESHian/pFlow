import Foundation

/// Which audio the next live window covers, in 16 kHz samples. Windows start
/// where the kept words end and never exceed `maximumMs`, so a long take is
/// never decoded again from the beginning.
struct LiveWindowPlanner: Equatable {
    static let samplesPerMs = 16
    var maximumMs = 15_000
    var strideMs = 1_000
    var minimumMs = 1_000

    /// nil until `strideMs` of new audio arrived after `lastEndSample`.
    func next(totalSamples: Int, committedEndMs: Int, lastEndSample: Int) -> Range<Int>? {
        let perMs = Self.samplesPerMs
        guard totalSamples - lastEndSample >= strideMs * perMs else { return nil }
        let start = max(committedEndMs * perMs, totalSamples - maximumMs * perMs, 0)
        guard totalSamples - start >= minimumMs * perMs else { return nil }
        return start..<totalSamples
    }
}

/// Skips inference on audio with no speech in it, which is also where Whisper
/// invents words. Speech needs 150 ms of 30 ms frames louder than about -40 dBFS.
enum LiveAudioGate {
    static let frame = 480
    static let threshold: Float = 0.01
    static let framesNeeded = 5

    static func hasSpeech(_ samples: ArraySlice<Float>) -> Bool {
        var loud = 0
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + frame, samples.endIndex)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            if (sum / Float(end - start)).squareRoot() > threshold { loud += 1 }
            if loud >= framesNeeded { return true }
            start = end
        }
        return false
    }
}

/// The last few seconds of a take, fixed size. Written off the audio callback.
struct LiveAudioRing {
    private var storage: [Float]
    /// Samples written since the take began.
    private(set) var total = 0

    init(seconds: Int) { storage = Array(repeating: 0, count: seconds * 16_000) }

    var oldest: Int { max(0, total - storage.count) }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        // Audio older than the ring holds is counted, never stored.
        total += max(0, samples.count - storage.count)
        var rest = samples.suffix(storage.count)[...]
        while !rest.isEmpty {
            let at = total % storage.count
            let count = min(rest.count, storage.count - at)
            storage.replaceSubrange(at..<at + count, with: rest.prefix(count))
            rest = rest.dropFirst(count)
            total += count
        }
    }

    /// The held part of `range`.
    func snapshot(_ range: Range<Int>) -> [Float] {
        let lower = max(range.lowerBound, oldest)
        let upper = min(range.upperBound, total)
        guard lower < upper else { return [] }
        let start = lower % storage.count
        let end = start + (upper - lower)
        if end <= storage.count { return Array(storage[start..<end]) }
        return Array(storage[start...]) + storage[..<(end - storage.count)]
    }
}

/// Live Whisper for one take: copies audio into a ring, and on a timer
/// recognizes one bounded window at a time with a model loaded once. While a
/// window runs, newer audio waits in the ring; the next window takes the newest
/// audio, so nothing queues. After `stop` nothing is delivered.
final class WhisperLiveRecognizer: @unchecked Sendable {
    private let worker: WhisperLiveWorking
    private let language: String
    private let planner: LiveWindowPlanner
    private let tick: DispatchTimeInterval
    private let stopLimit: DispatchTimeInterval
    private let onText: (String) -> Void
    private let onFailure: () -> Void
    private let queue = DispatchQueue(label: "com.pesh.whisper.live", qos: .userInitiated)
    private let lock = NSLock()
    private var ring = LiveAudioRing(seconds: 20)
    private var merger = WhisperLiveMerger()
    private var lastEndSample = 0
    private var closed = false
    private var failed = false
    private var loaded = false
    private var timer: DispatchSourceTimer?
    private var recognized: [Range<Int>] = []

    init(worker: WhisperLiveWorking, language: String, planner: LiveWindowPlanner = LiveWindowPlanner(),
         tick: DispatchTimeInterval = .milliseconds(250), stopLimit: DispatchTimeInterval = .seconds(3),
         onText: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
        self.worker = worker
        self.language = language
        self.planner = planner
        self.tick = tick
        self.stopLimit = stopLimit
        self.onText = onText
        self.onFailure = onFailure
    }

    /// Loads the model in the background; recording does not wait for it.
    func start() {
        queue.async { [self] in
            do { try worker.load() } catch { fail(); return }
            lock.withLock { loaded = true }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.step() }
            guard lock.withLock({ () -> Bool in
                guard !closed, !failed else { return false }
                self.timer = timer
                return true
            }) else { return }
            timer.resume()
        }
    }

    /// 16 kHz mono samples, in order. Never called from the audio callback.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        lock.withLock { if !closed { ring.append(samples) } }
    }

    var text: String { lock.withLock { merger.text } }
    var recognizedWindows: [Range<Int>] { lock.withLock { recognized } }

    /// Ends live recognition for the take and returns the words shown so far.
    @discardableResult
    func stop() -> String {
        let text = closeWindows()
        worker.stop()
        return text
    }

    /// Ends live windows for the take but keeps the helper and its loaded
    /// model for the finished-text pass. A window or model load still running
    /// may finish first (one at most), so the helper is idle when this returns.
    /// If it does not finish within `stopLimit` the helper is ended. The
    /// worker is nil when it failed, never loaded or was ended; the caller
    /// then uses whisper-cli.
    func stopKeepingWorker() -> (text: String, worker: WhisperLiveWorking?) {
        let text = closeWindows()
        let idle = DispatchSemaphore(value: 0)
        queue.async { idle.signal() }
        if idle.wait(timeout: .now() + stopLimit) == .timedOut { worker.stop() }
        let usable = lock.withLock { loaded && !failed } && !worker.isStopped
        if !usable { worker.stop() }
        return (text, usable ? worker : nil)
    }

    private func closeWindows() -> String {
        let (timer, text) = lock.withLock { () -> (DispatchSourceTimer?, String) in
            closed = true
            defer { self.timer = nil }
            return (self.timer, merger.text)
        }
        timer?.cancel()
        return text
    }

    private func step() {
        let plan = lock.withLock { () -> (range: Range<Int>, fresh: [Float], window: [Float])? in
            guard !closed, !failed, let range = planner.next(totalSamples: ring.total,
                  committedEndMs: merger.committedEndMs, lastEndSample: lastEndSample) else { return nil }
            let fresh = ring.snapshot(lastEndSample..<range.upperBound)
            lastEndSample = range.upperBound
            return (range, fresh, ring.snapshot(range))
        }
        guard let plan, LiveAudioGate.hasSpeech(plan.fresh[...]), !plan.window.isEmpty else { return }
        let segments: [WhisperWindowSegment]
        do { segments = try worker.recognize(plan.window, language: language) }
        catch { fail(); return }
        lock.withLock {
            // A result that finishes after stop belongs to a take that is over.
            guard !closed, !failed else { return }
            recognized.append(plan.range)
            let perMs = LiveWindowPlanner.samplesPerMs
            let window = WhisperWindow(startMs: plan.range.lowerBound / perMs, endMs: plan.range.upperBound / perMs,
                                       segments: segments)
            if merger.apply(window) { onText(merger.text) }
        }
    }

    private func fail() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            guard !failed else { return nil }
            failed = true
            // After stop the take is over: nothing more is reported.
            if !closed { onFailure() }
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
        worker.stop()
    }
}
