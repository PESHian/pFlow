// Native integration probe. Uses only the upstream public JFK sample, never user audio.
// swiftc <the five service/support sources> Tools/WhisperSmokeTest.swift -o /tmp/pflow-whisper-smoke
import AVFoundation
import Foundation

@main struct WhisperSmokeTest {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fatalError("Expected helper path and public sample WAV path") }
        let model = WhisperModelStore()
        if !model.isReady {
            model.download()
            while model.isDownloading { try await Task.sleep(for: .milliseconds(200)) }
            guard model.isReady else { fatalError(model.errorMessage ?? "Model download failed") }
        }
        try WhisperModelStore.validate(WhisperModelStore.modelURL)
        let root = FileManager.default.temporaryDirectory.appending(path: "pflow-whisper-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = WhisperTranscriber(executableURL: URL(filePath: arguments[1]), temporaryDirectory: root)
        try await transcriber.begin(locale: Locale(identifier: "en-US"), contextualStrings: [])
        let file = try AVAudioFile(forReading: URL(filePath: arguments[2]))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048)!
        let microphoneFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                              channels: 1, interleaved: false)!
        let conversion = BufferConverter()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            transcriber.feed(try conversion.convertBuffer(buffer, to: microphoneFormat))
        }
        let text = try await transcriber.finish()
        let normalized = text.lowercased()
        guard normalized.contains("ask not what your country can do for you"),
              normalized.contains("what you can do for your country") else {
            fatalError("Whisper public speech fixture mismatch")
        }
        print("WHISPER_NATIVE_CAPTURE_CONVERSION_INFERENCE_PASS characters=\(text.count)")
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { fatalError("Audio retained after finish") }
        let cancelled = WhisperTranscriber(executableURL: URL(filePath: arguments[1]), temporaryDirectory: root)
        try await cancelled.begin(locale: .current, contextualStrings: [])
        cancelled.feed(buffer)
        await cancelled.cancel()
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { fatalError("Audio retained after cancel") }
        print("WHISPER_CANCEL_PASS")
    }
}
