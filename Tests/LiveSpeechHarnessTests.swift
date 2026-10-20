@preconcurrency import AVFoundation
import AppKit
import Testing
@testable import Yap

// Live proof on a Mac: a fictional recording goes through the real Apple
// Speech path (TranscriptionService) instead of the microphone, and Right
// Command presses go through the real activation state machine with chosen
// timestamps. No key events are posted to the system. Runs only when PFLOW_LIVE_AUDIO names a folder
// of recordings; PFLOW_LIVE_REPORT receives the timestamped results.

private let audioFolder = ProcessInfo.processInfo.environment["PFLOW_LIVE_AUDIO"]
private let reportFolder = ProcessInfo.processInfo.environment["PFLOW_LIVE_REPORT"]

private struct Narration {
    let file: String
    let lastWord: String
}

private let narrations = [
    Narration(file: "narration-short.aiff", lastWord: "pelicans"),
    Narration(file: "narration-long.aiff", lastWord: "lanterns"),
]

private final class PauseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ paused: Bool) { lock.withLock { value = paused } }
    var isPaused: Bool { lock.withLock { value } }
}

/// Plays a recording into the real Apple Speech engine at real-time pace.
@MainActor
private final class FileFedSession: DictationSessioning {
    var onLevel: ((Float) -> Void)?
    var onTranscript: ((TranscriptUpdate) -> Void)?
    var onAudioStart: (() -> Void)?
    var onAudioEnd: (() -> Void)?
    private let url: URL
    private let locale: Locale
    private let paced: Bool
    private var engine: TranscriptionService?
    private var feed: LiveTranscriptFeed?
    private var player: Task<Void, Never>?
    private let paused = PauseFlag()

    init(url: URL, locale: Locale, paced: Bool = true) {
        self.url = url
        self.locale = locale
        self.paced = paced
    }

    func setCapturePaused(_ isPaused: Bool) throws { paused.set(isPaused) }

    func start(take: String) async throws {
        let feed = LiveTranscriptFeed(session: take) { [weak self] in self?.onTranscript?($0) }
        self.feed = feed
        let engine = TranscriptionService()
        engine.onTranscript = { feed.post($0) }
        try await engine.begin(locale: locale, contextualStrings: [])
        self.engine = engine
        let url = self.url, paced = self.paced, paused = self.paused
        player = Task.detached { [weak self] in
            guard let file = try? AVAudioFile(forReading: url) else { return }
            await MainActor.run { self?.onAudioStart?() }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            while file.framePosition < file.length, !Task.isCancelled {
                if paused.isPaused { try? await Task.sleep(for: .milliseconds(20)); continue }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                engine.feed(buffer)
                if paced { try? await Task.sleep(for: .milliseconds(100)) }
            }
            await MainActor.run { self?.onAudioEnd?() }
        }
    }

    func waitForAudioEnd() async {
        await player?.value
    }

    func stop() async throws -> TranscriptUpdate {
        player?.cancel()
        await player?.value
        let feed = self.feed ?? LiveTranscriptFeed(session: "", deliver: { _ in })
        let text = try await engine?.finish() ?? ""
        engine = nil
        return feed.finish(text)
    }
}

/// The real HUD, with every live update timestamped.
@MainActor
private final class TimedHUD: HUDControlling {
    let real = HUDController()
    let started = ProcessInfo.processInfo.systemUptime
    var partials: [(seconds: Double, text: String)] = []
    var previewShown: [Bool] = []
    func show(device: String?, livePreview: Bool) { previewShown.append(livePreview); real.show(device: device, livePreview: livePreview) }
    func setPhase(_ phase: HUDPhase) { real.setPhase(phase) }
    func setLevel(_ level: Float) { real.setLevel(level) }
    func setPartial(_ text: String) {
        partials.append((ProcessInfo.processInfo.systemUptime - started, text))
        real.setPartial(text)
    }
    func hide(after seconds: Double) { real.hide(after: seconds) }
    func setActions(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {}
}

@MainActor
struct LiveSpeechHarnessTests {
    private func englishLocale() async throws -> Locale {
        try #require(await TranscriptionService.resolvedLocale(for: Locale(identifier: "en-US")))
    }

    private func writeReport(_ name: String, _ object: Any) throws {
        guard let reportFolder else { return }
        let folder = URL(fileURLWithPath: reportFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appending(path: "\(name).json"))
    }

    @Test(.enabled(if: audioFolder != nil),
          arguments: ["hold-short", "continuous-short", "hold-long", "continuous-long"])
    func appleSpeechPreviewUpdatesBeforeRecordingStops(run: String) async throws {
        let locale = try await englishLocale()
        let style = run.hasPrefix("hold") ? "hold" : "continuous"
        let narration = narrations[run.hasSuffix("long") ? 1 : 0]
        let url = URL(fileURLWithPath: audioFolder!).appending(path: narration.file)
        let session = FileFedSession(url: url, locale: locale)
        let hud = TimedHUD()
        let injector = FakeInjector()
        let history = FakeHistory()
        let coordinator = RecordingCoordinator(
            session: session, injector: injector, history: history, hud: hud, sounds: FakeSounds(),
            cleaner: FakeCleaner(), cleanupEnabled: { false }, vocabulary: { [] }, deviceName: { nil },
            liveTextMode: { .preview })
        var keys = RightCommandActivation()
        var effects: [RightCommandActivation.Effect] = []
        func send(_ produced: [RightCommandActivation.Effect]) {
            effects += produced
            produced.forEach(coordinator.handle)
        }

        var audioStart: Double?
        var audioEnd: Double?
        session.onAudioStart = { audioStart = ProcessInfo.processInfo.systemUptime - hud.started }
        session.onAudioEnd = { audioEnd = ProcessInfo.processInfo.systemUptime - hud.started }
        let t0 = ProcessInfo.processInfo.systemUptime
        send(keys.press(at: t0))
        if style == "continuous" {
            send(keys.release(at: t0 + 0.10))
            send(keys.press(at: t0 + 0.20))
            send(keys.release(at: t0 + 0.25))
        }
        while coordinator.state == .recording, audioEnd == nil { try await Task.sleep(for: .milliseconds(20)) }
        // The person is still "holding" (or latched) at the end of the audio.
        let previewAtAudioEnd = hud.real.model.partial
        let partialsBeforeEnd = hud.partials.filter { $0.seconds <= (audioEnd ?? 0) && !$0.text.isEmpty }
        let t1 = ProcessInfo.processInfo.systemUptime
        if style == "continuous" {
            send(keys.press(at: t1))
            send(keys.release(at: t1 + 0.05))
        } else {
            send(keys.release(at: t1))
        }
        while coordinator.state != .idle { try await Task.sleep(for: .milliseconds(20)) }
        let stopped = ProcessInfo.processInfo.systemUptime - hud.started

        try writeReport("apple-preview-\(run)", [
            "style": style,
            "effects": effects.map { "\($0)" },
            "audioStartSeconds": audioStart ?? -1,
            "audioEndSeconds": audioEnd ?? -1,
            "stoppedSeconds": stopped,
            "partials": hud.partials.map { ["seconds": $0.seconds, "text": $0.text] },
            "partialsBeforeAudioEnd": partialsBeforeEnd.count,
            "hudPreviewAtAudioEnd": previewAtAudioEnd,
            "delivered": injector.delivered,
            "historyEntries": history.saved.count,
            "hudPreviewAfterStop": hud.real.model.partial,
        ])
        #expect(effects == (style == "hold" ? [.start, .finish] : [.start, .pause, .resume, .finish]))
        #expect(hud.previewShown == [true])
        #expect(partialsBeforeEnd.count >= 3)
        #expect(!previewAtAudioEnd.isEmpty)
        #expect(injector.delivered.count == 1)
        #expect(injector.delivered.first?.lowercased().contains(narration.lastWord) == true)
        #expect(history.saved == injector.delivered)
    }

    /// TranscriptionService.finish finalizes, then cancels the results task
    /// without waiting for it. Check whether that ever loses the last words.
    @Test(.enabled(if: audioFolder != nil))
    func finishingRightAtTheEndKeepsTheLastWords() async throws {
        let locale = try await englishLocale()
        var runs: [[String: Any]] = []
        for narration in narrations {
            let url = URL(fileURLWithPath: audioFolder!).appending(path: narration.file)
            for attempt in 1...4 {
                let session = FileFedSession(url: url, locale: locale, paced: false)
                try await session.start(take: "ordering-\(attempt)")
                await session.waitForAudioEnd()
                let started = ProcessInfo.processInfo.systemUptime
                let final = try await session.stop()
                let seconds = ProcessInfo.processInfo.systemUptime - started
                let kept = final.text.lowercased().contains(narration.lastWord)
                runs.append(["file": narration.file, "attempt": attempt, "lastWordKept": kept,
                             "finishSeconds": seconds, "text": final.text])
                #expect(kept, "\(narration.file) attempt \(attempt): \(final.text)")
            }
        }
        try writeReport("apple-final-ordering", ["runs": runs])
    }
}
