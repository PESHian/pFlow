@preconcurrency import AVFoundation
import Testing
@testable import Yap

/// Stands in for the microphone; no audio is opened or produced.
private final class SilentCapture: AudioCapturing {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0
    func start() throws { starts += 1 }
    func stop() { stops += 1 }
    func pause() {}
    func resume() throws {}
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
