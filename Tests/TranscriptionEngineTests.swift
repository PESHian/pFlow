import Foundation
import CryptoKit
import Testing
import AVFoundation
import Darwin
@testable import Yap

@MainActor
struct TranscriptionEngineTests {
    @Test func appleIsDefaultAndSavedWhisperSurvivesRelaunch() {
        let name = "pflow.engine.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TranscriptionEngine.saved(in: defaults) == .apple)
        TranscriptionEngine.whisper.save(in: defaults)
        #expect(TranscriptionEngine.saved(in: UserDefaults(suiteName: name)!) == .whisper)
        TranscriptionEngine.apple.save(in: defaults)
        #expect(TranscriptionEngine.saved(in: defaults) == .apple)
        defaults.set("unknown", forKey: TranscriptionEngine.defaultsKey)
        #expect(TranscriptionEngine.saved(in: defaults) == .apple)
    }

    @Test func modelValidationRejectsCorruptionAndIncompleteDownloads() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("known model fixture".utf8)
        try bytes.write(to: file)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try WhisperModelStore.validate(file, bytes: Int64(bytes.count), sha256: hash)
        #expect(throws: (any Error).self) {
            try WhisperModelStore.validate(file, bytes: Int64(bytes.count + 1), sha256: hash)
        }
        #expect(throws: (any Error).self) {
            try WhisperModelStore.validate(file, bytes: Int64(bytes.count), sha256: "wrong")
        }
        #expect(!WhisperModelStore.hasModel(at: file))
    }

    @Test func whisperDoesNotRequireAppleSpeechPermission() {
        let permissions = PermissionsManager()
        permissions.microphone = .granted
        permissions.accessibility = true
        permissions.automation = .granted
        permissions.speech = .denied
        #expect(!permissions.allGranted)
        permissions.requiresSpeechRecognition = false
        #expect(permissions.allGranted)
        permissions.microphone = .denied
        #expect(!permissions.allGranted)
    }

    @Test func missingModelFailsWithoutCreatingRecordingOrRunningProcess() async {
        let missing = URL(filePath: "/tmp/pflow-missing-\(UUID().uuidString)")
        let transcriber = WhisperTranscriber(modelURL: missing)
        await #expect(throws: (any Error).self) {
            try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        }
        await transcriber.cancel()
    }

    @Test func languageAliasesAndUnknownLocalesAreSafe() {
        for (identifier, expected) in [("nb-NO", "no"), ("nn-NO", "nn"), ("fil-PH", "tl"),
                                       ("jv-ID", "jw"), ("en-US", "en"), ("zh-Hant", "zh"), ("xx-ZZ", "auto")] {
            #expect(WhisperTranscriber.language(for: Locale(identifier: identifier)) == expected)
        }
    }

    @Test func cancelledDownloadLeavesNoModelAndAllowsRetry() async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let store = WhisperModelStore(destination: destination)
        #expect(!store.isDownloading)
        store.download()
        try await Task.sleep(for: .milliseconds(30))
        store.cancelDownload()
        for _ in 0..<150 where store.isDownloading { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.isDownloading)
        #expect(!store.isReady)
        #expect(store.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancellationTerminatesRunningHelper() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appending(path: "helper")
        try "#!/bin/sh\necho $$ > \"$(dirname \"$0\")/pid\"\nexec /bin/sleep 30\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let task = Task { try await WhisperTranscriber.transcribe(audio: root, model: root, executable: helper,
            output: root.appending(path: "result"), locale: .current) }
        let pidFile = root.appending(path: "pid")
        for _ in 0..<150 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        #expect(kill(pid, 0) == 0)
        task.cancel()
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let stoppedPromptly = kill(pid, 0) == -1
        if !stoppedPromptly { kill(pid, SIGKILL) }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(stoppedPromptly, "Cancellation must stop the running helper within two seconds")
    }

    @Test func recordingErrorDeletesAudioAfterConversion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appending(path: "recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: false)
        let model = root.appending(path: "model")
        FileManager.default.createFile(atPath: model.path, contents: nil)
        let handle = try FileHandle(forWritingTo: model)
        try handle.truncate(atOffset: UInt64(WhisperModelStore.expectedBytes))
        try handle.close()
        let helper = root.appending(path: "helper")
        try "#!/bin/sh\n/bin/cp \"$4\" \"$(dirname \"$0\")/captured.wav\"\nexit 17\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let transcriber = WhisperTranscriber(modelURL: model, executableURL: helper, temporaryDirectory: recordings)
        try await transcriber.begin(locale: .current, contextualStrings: [])
        for rate in [44_100.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
            buffer.frameLength = 2048
            memset(buffer.floatChannelData![0], 0, 2048 * MemoryLayout<Float>.size)
            transcriber.feed(buffer)
        }
        await #expect(throws: (any Error).self) { try await transcriber.finish() }
        let captured = try AVAudioFile(forReading: root.appending(path: "captured.wav"))
        #expect(captured.fileFormat.sampleRate == 16_000)
        #expect(captured.fileFormat.channelCount == 1)
        #expect(captured.length > 1000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: recordings.path).isEmpty)
    }
}
