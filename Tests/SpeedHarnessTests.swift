@preconcurrency import AVFoundation
import Darwin
import Speech
import Testing
@testable import Yap

// Speed measurement on a Mac. Fictional recordings play in real time through
// the real DictationSession and RecordingCoordinator; a FileCapture stands in
// for the microphone, so no microphone is opened and no key events are posted.
// The HUD, injector and History are fakes that keep timestamps.
//
// Runs only when PFLOW_SPEED_AUDIO names a folder of recordings, each with a
// .txt reference beside it. PFLOW_SPEED_RUN picks what to measure:
//   apple, apple-fast        Apple Speech with Live text Preview (fast = .fastResults)
//   apple-off                Apple Speech with Live text Off
//   whisper-on, whisper-off  Whisper (needs PFLOW_WHISPER_MODEL)
//   whisper-identity         the live helper's finished text against whisper-cli
//   locale                   locale resolution, cold/warm and after a language change
//   cleanup                  on-device cleanup of each reference text
// PFLOW_SPEED_FILES limits the recordings (comma list), PFLOW_SPEED_TAKES sets
// takes per recording in this process (the first take in a process is cold).
// Each run writes PFLOW_SPEED_REPORT/<run>-<time>.json.

private let env = ProcessInfo.processInfo.environment
private let speedAudio = env["PFLOW_SPEED_AUDIO"]
private let speedReport = env["PFLOW_SPEED_REPORT"]
private let speedRun = env["PFLOW_SPEED_RUN"] ?? "apple"
private let speedFiles = env["PFLOW_SPEED_FILES"]
private let speedTakes = Int(env["PFLOW_SPEED_TAKES"] ?? "") ?? 1
private let speedModel = env["PFLOW_WHISPER_MODEL"]

private func now() -> Double { ProcessInfo.processInfo.systemUptime }

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
        lock.withLock { running = true; paused = false; startedAt = now(); endedAt = nil }
        let thread = Thread { [self] in play(file) }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func play(_ file: AVAudioFile) {
        let rate = file.processingFormat.sampleRate
        let chunk = AVAudioFrameCount(rate * 2048 / 44_100)
        var played = 0.0
        var clock = now()
        while file.framePosition < file.length {
            let (live, hold) = lock.withLock { (running, paused) }
            guard live else { return }
            if hold { Thread.sleep(forTimeInterval: 0.01); clock += 0.01; continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                  (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
            played += Double(buffer.frameLength) / rate
            let ahead = played - (now() - clock)
            if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
            onBuffer?(buffer)
            onLevel?(AudioLevel.normalized(from: buffer))
        }
        lock.withLock { endedAt = now() }
    }

    var finished: Bool { lock.withLock { endedAt != nil } }
    func stop() { lock.withLock { running = false } }
    func pause() { lock.withLock { paused = true } }
    func resume() throws { lock.withLock { paused = false } }
}

/// Forwards to the real session and times start and stop.
@MainActor
private final class TimedSession: DictationSessioning {
    let real: DictationSession
    var onLevel: ((Float) -> Void)? { get { real.onLevel } set { real.onLevel = newValue } }
    var onTranscript: ((TranscriptUpdate) -> Void)? { get { real.onTranscript } set { real.onTranscript = newValue } }
    var onLiveStopped: (() -> Void)? { get { real.onLiveStopped } set { real.onLiveStopped = newValue } }
    private(set) var startCalled: Double?
    private(set) var ready: Double?
    private(set) var stopCalled: Double?
    private(set) var stopped: Double?

    init(_ real: DictationSession) { self.real = real }
    func start(take: String, live: Bool) async throws {
        startCalled = now()
        try await real.start(take: take, live: live)
        ready = now()
    }
    func stop() async throws -> TranscriptUpdate {
        stopCalled = now()
        defer { stopped = now() }
        return try await real.stop()
    }
    func cancel() async { await real.cancel() }
    func setCapturePaused(_ paused: Bool) throws { try real.setCapturePaused(paused) }
}

@MainActor
private final class TimedHUD: HUDControlling {
    var partials: [(at: Double, text: String)] = []
    var phases: [HUDPhase] = []
    func show(device: String?, livePreview: Bool) {}
    func setPhase(_ phase: HUDPhase) { phases.append(phase) }
    func setLevel(_ level: Float) {}
    func setPartial(_ text: String) { partials.append((now(), text)) }
    func setLiveNote(_ note: String?) {}
    func hide(after seconds: Double) {}
    func setActions(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {}
    func offerCopy(_ text: String) {}
}

@MainActor
private final class TimedInjector: TextInjecting {
    var targetApplicationName: String? = "Fictional Notes"
    var targetApplicationBundleID: String? = "com.example.fictional"
    var delivered: [(at: Double, text: String)] = []
    func captureTarget() {}
    func deliver(_ text: String) async -> InjectionOutcome {
        delivered.append((now(), text))
        return .pasted
    }
}

/// Lower-case words without punctuation, for word error rate.
func speedWords(_ text: String) -> [String] {
    text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
}

/// Word-level edit distance over reference length.
func wordErrorRate(_ hypothesis: String, reference: String) -> Double {
    let h = speedWords(hypothesis), r = speedWords(reference)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var row = Array(0...h.count)
    for i in 1...r.count {
        var previous = row[0]
        row[0] = i
        for j in stride(from: 1, through: h.count, by: 1) {
            let current = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (r[i - 1] == h[j - 1] ? 0 : 1))
            previous = current
        }
    }
    return Double(row[h.count]) / Double(r.count)
}

private func cpuSeconds(_ who: Int32) -> Double {
    var usage = rusage()
    getrusage(who, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

private func ms(_ from: Double?, _ to: Double?) -> Double {
    guard let from, let to else { return -1 }
    return ((to - from) * 1000).rounded()
}

@MainActor
@Suite(.serialized)
struct SpeedHarnessTests {
    private var folder: URL { URL(fileURLWithPath: speedAudio!) }

    private func recordings() throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".aiff") && !$0.hasPrefix("long") }.sorted()
        let names = speedFiles.map { $0.split(separator: ",").map(String.init) } ?? all
        return names.map { folder.appending(path: $0) }
    }

    private func reference(for url: URL) throws -> String {
        try String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ object: Any) throws {
        guard let speedReport else { return }
        let out = URL(fileURLWithPath: speedReport)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appending(path: "\(speedRun)-\(stamp).json"))
    }

    private func english() async throws -> Locale {
        try #require(await TranscriptionService.resolvedLocale(for: Locale(identifier: "en-US")))
    }

    /// One take through the coordinator: key down at t0, held until the
    /// recording has played, then released, as hold-to-talk does.
    private func take(_ url: URL, session real: DictationSession, capture: FileCapture, live: LiveTextMode,
                      index: Int) async throws -> [String: Any] {
        let session = TimedSession(real)
        let hud = TimedHUD()
        let injector = TimedInjector()
        let coordinator = RecordingCoordinator(
            session: session, injector: injector, history: FakeHistory(), hud: hud, sounds: FakeSounds(),
            cleaner: FakeCleaner(), cleanupEnabled: { false }, vocabulary: { [] }, deviceName: { nil },
            liveTextMode: { live })
        var keys = RightCommandActivation()
        let selfCPU = cpuSeconds(RUSAGE_SELF), childCPU = cpuSeconds(RUSAGE_CHILDREN)
        let key = now()
        keys.press(at: key).forEach(coordinator.handle)
        // The same capture can serve several takes: wait for this take's playback.
        while (capture.startedAt ?? 0) < key || !capture.finished { try await Task.sleep(for: .milliseconds(5)) }
        let audioEnd = capture.endedAt
        let release = now()
        keys.release(at: release).forEach(coordinator.handle)
        while coordinator.state != .idle { try await Task.sleep(for: .milliseconds(5)) }
        let delivered = injector.delivered.first
        let reference = try reference(for: url)
        let visible = hud.partials.filter { !$0.text.isEmpty }
        let beforeEnd = visible.filter { $0.at <= (audioEnd ?? 0) }
        let gaps = zip(beforeEnd.dropFirst(), beforeEnd).map { ($0.at - $1.at) * 1000 }.sorted()
        let finalText = delivered?.text ?? ""
        return [
            "file": url.lastPathComponent,
            "take": index,
            "live": live.rawValue,
            "audioSeconds": (audioEnd ?? 0) - (capture.startedAt ?? 0),
            "keyToCaptureStartMs": ms(key, capture.startedAt),
            "keyToEngineReadyMs": ms(key, session.ready),
            "audioStartToFirstWordsMs": ms(capture.startedAt, visible.first?.at),
            "updatesBeforeAudioEnd": beforeEnd.count,
            "medianGapMs": gaps.isEmpty ? -1 : gaps[gaps.count / 2].rounded(),
            "stopToFinalRecognitionMs": ms(release, session.stopped),
            "sessionStopMs": ms(session.stopCalled, session.stopped),
            "stopToDeliveredMs": ms(release, delivered?.at),
            "cpuSeconds": cpuSeconds(RUSAGE_SELF) - selfCPU + cpuSeconds(RUSAGE_CHILDREN) - childCPU,
            "final": finalText,
            "wordErrorRate": wordErrorRate(finalText, reference: reference),
            "lastWordKept": speedWords(finalText).last == speedWords(reference).last,
        ]
    }

    @Test(.enabled(if: speedAudio != nil))
    func measure() async throws {
        let run = speedRun
        var report: [String: Any] = ["run": run, "takesPerFile": speedTakes]
        switch run {
        case "apple", "apple-fast", "apple-off":
            let locale = try await english()
            let started = now()
            await DictationSession.prewarm(locale: locale)
            report["prewarmMs"] = ms(started, now())
            var takes: [[String: Any]] = []
            for url in try recordings() {
                for index in 1...speedTakes {
                    let capture = FileCapture(url: url)
                    let fast = run == "apple-fast"
                    let session = DictationSession(locale: locale, capture: capture,
                                                   appleEngine: { TranscriptionService(fastResults: fast) })
                    session.selectedEngine = { .apple }
                    takes.append(try await take(url, session: session, capture: capture,
                                                live: run == "apple-off" ? .off : .typeInApp, index: index))
                }
            }
            report["takes"] = takes
            #expect(takes.allSatisfy { ($0["final"] as? String)?.isEmpty == false })
        case "whisper-on", "whisper-off":
            let model = URL(fileURLWithPath: try #require(speedModel))
            var takes: [[String: Any]] = []
            for url in try recordings() {
                for index in 1...speedTakes {
                    let capture = FileCapture(url: url)
                    let session = DictationSession(locale: Locale(identifier: "en-US"),
                                                   capture: capture, whisperModel: model)
                    session.selectedEngine = { .whisper }
                    takes.append(try await take(url, session: session, capture: capture,
                                                live: run == "whisper-on" ? .typeInApp : .off, index: index))
                }
            }
            report["takes"] = takes
            #expect(takes.allSatisfy { ($0["final"] as? String)?.isEmpty == false })
        case "whisper-identity":
            report["identity"] = try await measureIdentity()
        case "locale":
            report.merge(try await measureLocales()) { $1 }
        case "cleanup":
            var rows: [[String: Any]] = []
            let cleaner = TranscriptCleanupService()
            report["available"] = cleaner.isAvailable
            for url in try recordings() {
                let text = try reference(for: url)
                for index in 1...speedTakes {
                    let started = now()
                    // On device only: never the cloud, whatever the owner chose.
                    let cleaned = await cleaner.process(text, cleanup: true, vocabulary: [], using: .onDevice)
                    rows.append(["file": url.lastPathComponent, "take": index, "cleanupMs": ms(started, now()),
                                 "changed": cleaned != text, "wordErrorRate": wordErrorRate(cleaned, reference: text)])
                }
            }
            report["cleanup"] = rows
        default:
            Issue.record("unknown PFLOW_SPEED_RUN \(run)")
        }
        try write(report)
    }

    /// The live helper's finished-text pass against whisper-cli on the same
    /// recording, after the helper has already run live windows on it.
    private func measureIdentity() async throws -> [[String: Any]] {
        let model = URL(fileURLWithPath: try #require(speedModel))
        let cli = Bundle.main.bundleURL.appending(path: "Contents/Helpers/whisper-cli")
        let scratch = FileManager.default.temporaryDirectory.appending(path: "pflow-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var rows: [[String: Any]] = []
        let files = try recordings() + [folder.appending(path: "long.aiff")]
        for url in files {
            let wav = scratch.appending(path: url.deletingPathExtension().lastPathComponent + ".wav")
            let samples = try takeRecording(from: url, to: wav, keep: 15 * 16_000)
            let worker = WhisperLiveProcess(model: model)
            try worker.load()
            // Dirty the helper first, as a take does.
            for end in stride(from: 16_000, through: min(samples.count, 15 * 16_000), by: 4 * 16_000) {
                _ = try worker.recognize(Array(samples[0..<end]), language: "en")
            }
            var started = now()
            let helper = WhisperTranscriber.finishedText(try worker.finishTake(recording: wav, language: "en",
                                                                               threads: WhisperTranscriber.finalThreads))
            let helperMs = ms(started, now())
            worker.stop()
            started = now()
            let whole = try await WhisperTranscriber.transcribe(audio: wav, model: model, executable: cli,
                                                                output: scratch.appending(path: "result"),
                                                                locale: Locale(identifier: "en-US"))
            let cliMs = ms(started, now())
            rows.append(["file": url.lastPathComponent, "identical": helper == whole, "helperMs": helperMs,
                         "cliMs": cliMs, "helper": helper, "cli": whole])
            #expect(helper == whole, "\(url.lastPathComponent)")
        }
        return rows
    }

    /// Locale resolution as DictationSession does it, plus the start of a take
    /// before and after a language change. Only installed languages are used,
    /// so nothing is downloaded.
    private func measureLocales() async throws -> [String: Any] {
        var out: [String: Any] = [:]
        var started = now()
        _ = await TranscriptionService.resolvedLocale(for: Locale(identifier: "en-US"))
        out["firstResolveMs"] = ms(started, now())
        var repeats: [Double] = []
        for _ in 1...5 {
            started = now()
            _ = await TranscriptionService.resolvedLocale(for: Locale(identifier: "en-US"))
            repeats.append(ms(started, now()))
        }
        out["repeatResolveMs"] = repeats
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }.sorted()
        out["installedLocales"] = installed
        let english = try await english()
        let other = installed.first { !$0.hasPrefix("en") }.map { Locale(identifier: $0) }
        out["otherLocale"] = other?.identifier(.bcp47) ?? "none installed"
        guard let url = try recordings().first else { return out }
        var takes: [[String: Any]] = []
        let capture = FileCapture(url: url)
        let session = DictationSession(locale: english, capture: capture)
        session.selectedEngine = { .apple }
        // The same session across a language change, as the app keeps one.
        for (label, locale) in [("first", english), ("again", english), ("changed", other), ("back", english)] {
            guard let locale else { continue }
            if label == "changed" || label == "back" { session.setLocale(locale) }
            var row = try await take(url, session: session, capture: capture, live: .typeInApp, index: takes.count + 1)
            row["step"] = label
            row["locale"] = locale.identifier(.bcp47)
            takes.append(row)
        }
        out["takes"] = takes
        return out
    }
}
