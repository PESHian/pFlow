@preconcurrency import AVFoundation
import AppKit
import Darwin
import Testing
@testable import Yap

// Live proof on a Mac: a fictional recording goes through the real Whisper path
// (bundled whisper-cli and pflow-whisper-live, Metal) instead of the microphone.
// Right Command presses go through the real activation state machine with chosen
// timestamps; no key events are posted. Runs only when PFLOW_WHISPER_AUDIO names
// a folder of recordings and PFLOW_WHISPER_MODEL a Whisper model file.

private let audioFolder = ProcessInfo.processInfo.environment["PFLOW_WHISPER_AUDIO"]
private let modelPath = ProcessInfo.processInfo.environment["PFLOW_WHISPER_MODEL"]
private let reportFolder = ProcessInfo.processInfo.environment["PFLOW_LIVE_REPORT"]
private let enabled = audioFolder != nil && modelPath != nil

/// Plays a recording into the real Whisper engine at real-time pace.
@MainActor
private final class FileFedWhisperSession: DictationSessioning {
    var onLevel: ((Float) -> Void)?
    var onTranscript: ((TranscriptUpdate) -> Void)?
    var onLiveStopped: (() -> Void)?
    var onAudioEnd: (() -> Void)?
    private let url: URL
    private let model: URL
    private var engine: WhisperTranscriber?
    private var feed: LiveTranscriptFeed?
    private var player: Task<Void, Never>?

    init(url: URL, model: URL) {
        self.url = url
        self.model = model
    }

    func setCapturePaused(_ paused: Bool) throws {}

    func start(take: String, live: Bool) async throws {
        let feed = LiveTranscriptFeed(session: take) { [weak self] in self?.onTranscript?($0) }
        self.feed = feed
        let model = self.model
        let engine = WhisperTranscriber(modelURL: model,
                                        liveWorker: live ? { WhisperLiveProcess(model: model) } : nil)
        engine.onTranscript = { feed.post($0) }
        engine.onLiveStopped = { [weak self] in Task { @MainActor in self?.onLiveStopped?() } }
        try await engine.begin(locale: Locale(identifier: "en-US"), contextualStrings: [])
        self.engine = engine
        let url = self.url
        player = Task.detached { [weak self] in
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            let began = ProcessInfo.processInfo.systemUptime
            var played = 0.0
            while file.framePosition < file.length, !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                engine.feed(buffer)
                played += Double(buffer.frameLength) / file.processingFormat.sampleRate
                // Real time, without drift: wait until the audio played so far is "spoken".
                let ahead = played - (ProcessInfo.processInfo.systemUptime - began)
                if ahead > 0 { try? await Task.sleep(for: .seconds(ahead)) }
            }
            await MainActor.run { self?.onAudioEnd?() }
        }
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

@MainActor
private final class TimedWhisperHUD: HUDControlling {
    let real = HUDController()
    let started = ProcessInfo.processInfo.systemUptime
    var partials: [(seconds: Double, text: String)] = []
    var notes: [String?] = []
    func show(device: String?, livePreview: Bool) { real.show(device: device, livePreview: livePreview) }
    func setPhase(_ phase: HUDPhase) { real.setPhase(phase) }
    func setLevel(_ level: Float) {}
    func setPartial(_ text: String) {
        partials.append((ProcessInfo.processInfo.systemUptime - started, text))
        real.setPartial(text)
    }
    func setLiveNote(_ note: String?) { notes.append(note); real.setLiveNote(note) }
    func hide(after seconds: Double) { real.hide(after: seconds) }
    func setActions(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {}
    func offerCopy(_ text: String) {}
}

private func cpuSeconds(_ who: Int32) -> Double {
    var usage = rusage()
    getrusage(who, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

@MainActor
@Suite(.serialized)
struct WhisperLiveHarnessTests {
    private func writeReport(_ name: String, _ object: Any) throws {
        guard let reportFolder else { return }
        let folder = URL(fileURLWithPath: reportFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appending(path: "\(name).json"))
    }

    @Test(.enabled(if: enabled),
          arguments: ["hold-short", "continuous-short", "continuous-long", "continuous-long-off"])
    func whisperPreviewUpdatesBeforeRecordingStops(run: String) async throws {
        let style = run.hasPrefix("hold") ? "hold" : "continuous"
        let live = !run.hasSuffix("-off")
        let file = run.contains("long") ? "whisper-long.aiff" : "whisper-short.aiff"
        let lastWord = run.contains("long") ? "pelicans" : "lanterns"
        let session = FileFedWhisperSession(url: URL(fileURLWithPath: audioFolder!).appending(path: file),
                                            model: URL(fileURLWithPath: modelPath!))
        let hud = TimedWhisperHUD()
        let injector = FakeInjector()
        let history = FakeHistory()
        let coordinator = RecordingCoordinator(
            session: session, injector: injector, history: history, hud: hud, sounds: FakeSounds(),
            cleaner: FakeCleaner(), cleanupEnabled: { false }, vocabulary: { [] }, deviceName: { nil },
            liveTextMode: { live ? .preview : .off })
        var keys = RightCommandActivation()
        var effects: [RightCommandActivation.Effect] = []
        func send(_ produced: [RightCommandActivation.Effect]) {
            effects += produced
            produced.forEach(coordinator.handle)
        }
        var audioEnd: Double?
        session.onAudioEnd = { audioEnd = ProcessInfo.processInfo.systemUptime - hud.started }

        let wallStart = Date().timeIntervalSince1970
        let selfCPU = cpuSeconds(RUSAGE_SELF), childCPU = cpuSeconds(RUSAGE_CHILDREN)
        let t0 = ProcessInfo.processInfo.systemUptime
        send(keys.press(at: t0))
        if style == "continuous" {
            send(keys.release(at: t0 + 0.10))
            send(keys.press(at: t0 + 0.20))
            send(keys.release(at: t0 + 0.25))
        }
        while coordinator.state == .recording, audioEnd == nil { try await Task.sleep(for: .milliseconds(20)) }
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
        let finalSeconds = ProcessInfo.processInfo.systemUptime - t1
        // Let Foundation reap the helpers so their CPU time is counted.
        try await Task.sleep(for: .milliseconds(800))
        let wall = Date().timeIntervalSince1970 - wallStart
        let appCPU = cpuSeconds(RUSAGE_SELF) - selfCPU
        let helperCPU = cpuSeconds(RUSAGE_CHILDREN) - childCPU

        let gaps = zip(partialsBeforeEnd.dropFirst(), partialsBeforeEnd).map { $0.seconds - $1.seconds }
        try writeReport("whisper-\(run)", [
            "style": style, "live": live, "file": file,
            "effects": effects.map { "\($0)" },
            "wallStartEpoch": wallStart, "wallSeconds": wall,
            "audioEndSeconds": audioEnd ?? -1, "stoppedSeconds": stopped, "finalSecondsAfterStop": finalSeconds,
            "firstPartialSeconds": partialsBeforeEnd.first?.seconds ?? -1,
            "medianSecondsBetweenUpdates": gaps.sorted().dropFirst(gaps.count / 2).first ?? -1,
            "partialsBeforeAudioEnd": partialsBeforeEnd.count,
            "partials": hud.partials.map { ["seconds": $0.seconds, "text": $0.text] },
            "hudPreviewAtAudioEnd": previewAtAudioEnd,
            "notes": hud.notes.map { $0 ?? "" },
            "delivered": injector.delivered, "historyEntries": history.saved.count,
            "hudPreviewAfterStop": hud.real.model.partial,
            "appCPUSeconds": appCPU, "helperCPUSeconds": helperCPU,
            "averageCPUPercent": (appCPU + helperCPU) / wall * 100,
        ])
        #expect(effects == (style == "hold" ? [.start, .finish] : [.start, .pause, .resume, .finish]))
        if live {
            #expect(partialsBeforeEnd.count >= 3)
            #expect(!previewAtAudioEnd.isEmpty)
            #expect(hud.notes.isEmpty)
        } else {
            #expect(hud.partials.isEmpty)
        }
        #expect(injector.delivered.count == 1)
        #expect(injector.delivered.first?.lowercased().contains(lastWord) == true)
        #expect(history.saved == injector.delivered)
        #expect(hud.real.model.partial.isEmpty)
    }
}
