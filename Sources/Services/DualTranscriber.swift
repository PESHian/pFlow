import AVFoundation

/// Two Apple recognizers on the same audio while live words show: one asked
/// for fast results, only for the live words (first words about 1.1 s after
/// speech starts instead of about 4.0 s), and the default one for the
/// finished text, which is more accurate (host measurement over 16 fictional
/// recordings, 381 words: 29 word errors with the default against 40 with
/// fast results). The finished text always comes from the accurate one.
final class DualTranscriber: StreamingTranscriber {
    var onTranscript: ((String) -> Void)?
    var onLiveStopped: (() -> Void)? {
        get { final.onLiveStopped }
        set { final.onLiveStopped = newValue }
    }
    private let live: StreamingTranscriber
    private let final: StreamingTranscriber

    init(live: StreamingTranscriber, final: StreamingTranscriber) {
        self.live = live
        self.final = final
    }

    func begin(locale: Locale, contextualStrings: [String]) async throws {
        // Only the live recognizer's words are shown; the other one's revisions are not.
        live.onTranscript = { [weak self] text in self?.onTranscript?(text) }
        final.onTranscript = nil
        try await final.begin(locale: locale, contextualStrings: contextualStrings)
        do {
            try await live.begin(locale: locale, contextualStrings: contextualStrings)
        } catch {
            // Live words are a nicety; the finished text does not depend on them.
            live.onTranscript = nil
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        final.feed(buffer)
        live.feed(buffer)
    }

    func finish() async throws -> String {
        async let quick = try? live.finish()
        let text = try await final.finish()
        _ = await quick
        return text
    }

    func cancel() async {
        await live.cancel()
        await final.cancel()
    }
}
