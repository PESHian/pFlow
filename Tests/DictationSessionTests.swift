@preconcurrency import AVFoundation
import Testing
@testable import Yap

/// Stands in for the microphone; no audio is opened or produced.
private final class SilentCapture: AudioCapturing {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onLost: (() -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    func start() throws { starts += 1 }
    func stop() { stops += 1 }
    func pause() {}
    func resume() throws {}
}

/// A microphone that gives `early` buffers the moment it starts (before recognition is ready),
/// and can stop giving audio partway (a headset going away).
private final class ScriptedCapture: AudioCapturing {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onLost: (() -> Void)?
    var early = 0
    func start() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for _ in 0..<early {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
            buffer.frameLength = 2048
            onBuffer?(buffer)
        }
    }
    func stop() {}
    func pause() {}
    func resume() throws {}
}

/// Finishes with fixed words and counts what it was fed.
private final class FixedEngine: StreamingTranscriber {
    var onTranscript: ((String) -> Void)?
    var fed = 0
    let words: String
    init(_ words: String) { self.words = words }
    func begin(locale: Locale, contextualStrings: [String]) async throws {}
    func feed(_ buffer: AVAudioPCMBuffer) { fed += 1 }
    func finish() async throws -> String { words }
}

/// Records which language a take's engine was started with. No recognition runs.
private final class RecordingEngine: StreamingTranscriber {
    var onTranscript: ((String) -> Void)?
    private(set) var locales: [Locale] = []
    func begin(locale: Locale, contextualStrings: [String]) async throws { locales.append(locale) }
    func feed(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> String { "" }
}

@MainActor
@Suite(.serialized)
struct DictationSessionTests {
    private func language(_ locale: Locale?) -> String? { locale?.language.languageCode?.identifier }

    /// A launch prewarm for the old language can finish after the person
    /// picked a new one. The next take must still use the new language.
    @Test func aLateOldPrewarmNeverStartsATakeInTheOldLanguage() async throws {
        let engine = RecordingEngine()
        let capture = SilentCapture()
        let session = DictationSession(locale: Locale(identifier: "en-US"), capture: capture,
                                       appleEngine: { engine }, appleLiveEngine: nil)
        session.selectedEngine = { .apple }
        await DictationSession.prewarm(locale: Locale(identifier: "en-US"))
        session.setLocale(Locale(identifier: "fr-FR"))
        // The earlier prewarm, for English, completing late.
        await DictationSession.prewarm(locale: Locale(identifier: "en-US"))
        try await session.start(take: "fr-take", live: false)
        _ = try await session.stop()
        #expect(language(engine.locales.last) == "fr")

        session.setLocale(Locale(identifier: "en-US"))
        try await session.start(take: "en-take", live: false)
        _ = try await session.stop()
        #expect(engine.locales.map(language) == ["fr", "en"])
        #expect(capture.starts == 2 && capture.stops >= 2)
    }

    /// Audio held while recognition gets ready (a first take while the speech model downloads) is
    /// kept up to about a minute; past that, the take never pretends it heard everything: it ends
    /// with what was heard and says audio was missed (hunt H5).
    @Test func audioPastWhatIsHeldIsNeverDroppedSilently() async throws {
        let relay = AudioBufferRelay(maximumPending: 3)
        let capture = ScriptedCapture()
        capture.early = 5
        let engine = FixedEngine("the harbor opens")
        let session = DictationSession(locale: Locale(identifier: "en-US"), capture: capture,
                                       appleEngine: { engine }, appleLiveEngine: nil, relay: relay)
        DictationSession.assumeSupported(Locale(identifier: "en-US"))
        try await session.start(take: "t", live: false)
        #expect(engine.fed == 3)
        do {
            _ = try await session.stop()
            Issue.record("a take with dropped audio must not end as if whole")
        } catch TranscriptionError.audioDropped(let kept) {
            #expect(kept == "the harbor opens")
        }
        // Within what is held: a normal take.
        capture.early = 3
        try await session.start(take: "t2", live: false)
        #expect(try await session.stop().text == "the harbor opens")
        #expect(AudioBufferRelay().maximumPendingForTesting >= 1400, "about a minute at 48 kHz")
    }

    /// The microphone stops partway (AirPods out of range): the words so far are kept and the take
    /// says so, never "Listening" over nothing (hunt H6).
    @Test func aMicrophoneLostMidTakeIsNeverSilent() async throws {
        let capture = ScriptedCapture()
        let engine = FixedEngine("the harbor")
        let session = DictationSession(locale: Locale(identifier: "en-US"), capture: capture,
                                       appleEngine: { engine }, appleLiveEngine: nil)
        DictationSession.assumeSupported(Locale(identifier: "en-US"))
        var stopped = 0
        session.onLiveStopped = { stopped += 1 }
        try await session.start(take: "t", live: false)
        capture.onLost?()
        for _ in 0..<20 where stopped == 0 { await Task.yield() }
        #expect(stopped == 1, "said during the take")
        do {
            _ = try await session.stop()
            Issue.record("a take whose microphone stopped must not end as if whole")
        } catch TranscriptionError.microphoneLost(let kept) {
            #expect(kept == "the harbor")
        }
        try await session.start(take: "t2", live: false)
        #expect(try await session.stop().text == "the harbor", "the next take is a normal one")
    }
}

/// Live words come from the fast recognizer, the finished text from the accurate one.
@MainActor
struct DualTranscriberTests {
    final class Scripted: StreamingTranscriber {
        var onTranscript: ((String) -> Void)?
        let posts: [String]
        let final: String
        var fed = 0
        init(posts: [String], final: String) { self.posts = posts; self.final = final }
        func begin(locale: Locale, contextualStrings: [String]) async throws { posts.forEach { onTranscript?($0) } }
        func feed(_ buffer: AVAudioPCMBuffer) { fed += 1 }
        func finish() async throws -> String { final }
    }

    @Test func theFastOneShowsTheAccurateOneFinishes() async throws {
        let fast = Scripted(posts: ["the harbour", "the harbour lights"], final: "The harbour lights glow.")
        let accurate = Scripted(posts: ["the harbor"], final: "The harbor lights glow softly.")
        let dual = DualTranscriber(live: fast, final: accurate)
        var shown: [String] = []
        dual.onTranscript = { shown.append($0) }
        try await dual.begin(locale: Locale(identifier: "en-US"), contextualStrings: [])
        #expect(shown == ["the harbour", "the harbour lights"], "only the fast recognizer's words show")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        dual.feed(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!)
        #expect(fast.fed == 1 && accurate.fed == 1, "both hear the same audio")
        #expect(try await dual.finish() == "The harbor lights glow softly.", "the finished text is the accurate one's")
    }
}
