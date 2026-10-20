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
                                       appleEngine: { engine })
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
