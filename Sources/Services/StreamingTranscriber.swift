import AVFoundation

protocol StreamingTranscriber: AnyObject {
    /// The whole transcript so far, each time the engine revises it. Engines
    /// may call this from any thread and must not call it from the audio
    /// callback. An engine that only recognizes at the end never calls it.
    var onTranscript: ((String) -> Void)? { get set }
    /// Live words stopped partway through a take (the engine still finishes
    /// the take normally). Any thread. Engines that cannot stop early ignore it.
    var onLiveStopped: (() -> Void)? { get set }
    func begin(locale: Locale, contextualStrings: [String]) async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel() async
}

extension StreamingTranscriber {
    func cancel() async { _ = try? await finish() }
    var onLiveStopped: (() -> Void)? {
        get { nil }
        set {}
    }
}

enum TranscriptionError: Error {
    case setupFailed
    case invalidFormat
    case unsupportedLocale
    /// Live recognition stopped partway through a take. `kept` is the text
    /// recognized before it stopped, after trying to finish the take normally.
    case interrupted(kept: String)
    /// Audio was dropped before recognition could take it (the speech model was still getting
    /// ready for longer than pFlow holds audio). `kept` is what was recognized.
    case audioDropped(kept: String)
    /// The speech model for the language is not on this Mac and could not be fetched now.
    case modelNotReady
    /// The microphone stopped giving audio partway through (a device change). `kept` is what was
    /// recognized before.
    case microphoneLost(kept: String)
}
