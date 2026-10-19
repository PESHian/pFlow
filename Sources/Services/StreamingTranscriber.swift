import AVFoundation

protocol StreamingTranscriber: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    func begin(locale: Locale, contextualStrings: [String]) async throws
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel() async
}

extension StreamingTranscriber {
    func cancel() async { _ = try? await finish() }
}

enum TranscriptionError: Error {
    case setupFailed
    case invalidFormat
    case unsupportedLocale
}
