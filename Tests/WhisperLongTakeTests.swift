@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Yap

// The whole-recording pass must keep every word of a long take. With `-nt`
// whisper.cpp jumped 30 s after each window, so a 198 s narration kept 378 of
// 652 words. The live test speaks the fictional fixtures/speed/long.txt with
// the system voice (as fixtures/speed/README.md says) and runs both finished-
// text paths on it. It needs the pinned model: PFLOW_WHISPER_MODEL=<ggml-small.bin>.

private let longTakeModel = ProcessInfo.processInfo.environment["PFLOW_WHISPER_MODEL"]

@Suite struct WhisperFinishedTextTests {
    @Test func wholeRecordingPassKeepsTimestampsSoLongTakesKeepTheirWords() {
        let arguments = WhisperTranscriber.arguments(audio: URL(fileURLWithPath: "/tmp/fictional/audio.wav"),
                                                     model: URL(fileURLWithPath: "/tmp/fictional/model.bin"),
                                                     output: URL(fileURLWithPath: "/tmp/fictional/result"), language: "en")
        #expect(!arguments.contains("-nt") && !arguments.contains("--no-timestamps"))
        #expect(arguments == ["-m", "/tmp/fictional/model.bin", "-f", "/tmp/fictional/audio.wav", "-l", "en",
                              "-t", "4", "-otxt", "-of", "/tmp/fictional/result", "-np"])
    }

    @Test func segmentLinesBecomeOneParagraph() {
        let output = "The ferry left at dawn.\nGulls followed it out.\n\n  The harbor went quiet.  \n"
        #expect(WhisperTranscriber.finishedText(output) == "The ferry left at dawn. Gulls followed it out. The harbor went quiet.")
        // whisper-cli writes each segment with a leading space; the join must not keep it ("this  brown").
        #expect(WhisperTranscriber.finishedText(" there was this\n brown little fox\n and he stunk\n like all sin.\n") == "there was this brown little fox and he stunk like all sin.")
        #expect(WhisperTranscriber.finishedText("Only one line.\n") == "Only one line.")
        #expect(WhisperTranscriber.finishedText("\n \n") == "")
    }
}

@Suite(.serialized) struct WhisperLongTakeTests {
    /// Reference words found in order in the result (longest common subsequence).
    private func keptWords(_ hypothesis: String, reference: String) -> (kept: Int, total: Int) {
        let h = speedWords(hypothesis), r = speedWords(reference)
        var row = [Int](repeating: 0, count: h.count + 1)
        for word in r {
            var diagonal = 0
            for j in h.indices {
                let above = row[j + 1]
                row[j + 1] = word == h[j] ? diagonal + 1 : max(above, row[j])
                diagonal = above
            }
        }
        return (row[h.count], r.count)
    }

    @Test(.enabled(if: longTakeModel != nil, "needs PFLOW_WHISPER_MODEL"))
    func longTakeKeepsItsWordsOnBothFinishedTextPaths() async throws {
        let model = URL(fileURLWithPath: try #require(longTakeModel))
        let reference = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../fixtures/speed/long.txt").standardizedFileURL
        let text = try String(contentsOf: reference, encoding: .utf8)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "pflow-long-take-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let spoken = scratch.appending(path: "long.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "--file-format=AIFF", "--data-format=BEI16@16000",
                         "-o", spoken.path, "-f", reference.path]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0, "say could not speak the fixture")
        let wav = scratch.appending(path: "audio.wav")
        _ = try takeRecording(from: spoken, to: wav)
        #expect(try AVAudioFile(forReading: wav).length > 150 * 16_000, "the narration should run past two 30 s windows many times")

        let cli = try await WhisperTranscriber.transcribe(audio: wav, model: model,
                                                          executable: Bundle.main.bundleURL.appending(path: "Contents/Helpers/whisper-cli"),
                                                          output: scratch.appending(path: "result"), locale: Locale(identifier: "en-US"))
        let worker = WhisperLiveProcess(model: model)
        try worker.load()
        defer { worker.stop() }
        let helper = WhisperTranscriber.finishedText(try worker.finishTake(recording: wav, language: "en",
                                                                           threads: WhisperTranscriber.finalThreads))
        let last = speedWords(text).suffix(6)
        for (name, result) in [("whisper-cli", cli), ("live helper", helper)] {
            let (kept, total) = keptWords(result, reference: text)
            #expect(Double(kept) >= 0.97 * Double(total), "\(name) kept \(kept) of \(total) words")
            #expect(speedWords(result).suffix(6) == last, "\(name) lost the last words")
        }
        #expect(helper == cli)
    }
}

/// A recording exactly as a take writes it: 16 kHz mono 16-bit WAV. Returns
/// the first `keep` samples as floats, for live windows.
func takeRecording(from source: URL, to wav: URL, keep: Int = 0) throws -> [Float] {
    let input = try AVAudioFile(forReading: source)
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let converter = BufferConverter()
    var samples: [Float] = []
    let writer = try AVAudioFile(forWriting: wav, settings: format.settings)
    while input.framePosition < input.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
        try input.read(into: buffer, frameCount: 4096)
        let converted = try converter.convertBuffer(buffer, to: writer.processingFormat)
        try writer.write(from: converted)
        if let data = converted.floatChannelData, samples.count < keep {
            samples += UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength))
        }
    }
    return samples
}
