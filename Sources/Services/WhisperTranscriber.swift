@preconcurrency import AVFoundation
import Foundation

/// Only the optional Whisper path writes audio. Files stay in a private,
/// short-lived directory and the existing capture/level pipeline is shared.
final class WhisperTranscriber: StreamingTranscriber {
    var onTranscript: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.pesh.whisper.audio", qos: .userInitiated)
    private var writer: AVAudioFile?
    private var converter = BufferConverter()
    private var inputFormat: AVAudioFormat?
    private var recordingError: Error?
    private var directory: URL?
    private var locale = Locale.current
    private let modelURL: URL
    private let executableURL: URL
    private let temporaryDirectory: URL

    init(modelURL: URL = WhisperModelStore.modelURL,
         executableURL: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/whisper-cli"),
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.modelURL = modelURL
        self.executableURL = executableURL
        self.temporaryDirectory = temporaryDirectory
    }

    func begin(locale: Locale, contextualStrings: [String]) async throws {
        guard WhisperModelStore.hasModel(at: modelURL) else { throw WhisperError.modelNeeded }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw WhisperError.engineMissing }
        self.locale = locale
        let directory = temporaryDirectory.appending(path: "pflow-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        self.directory = directory
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                       channels: 1, interleaved: true)!
            writer = try AVAudioFile(forWriting: directory.appending(path: "audio.wav"), settings: format.settings)
            recordingError = nil
        } catch {
            removeRecording()
            throw error
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // AVAudioEngine owns/reuses its tap memory. Copy before leaving that callback.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, target) {
            if let from = src.mData, let to = dst.mData { memcpy(to, from, Int(src.mDataByteSize)) }
        }
        queue.async { [self] in
            guard let writer, recordingError == nil else { return }
            do {
                if inputFormat != copy.format {
                    converter = BufferConverter()
                    inputFormat = copy.format
                }
                try writer.write(from: converter.convertBuffer(copy, to: writer.processingFormat))
            } catch { recordingError = error }
        }
    }

    func finish() async throws -> String {
        defer { removeRecording() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                writer = nil
                if let recordingError { continuation.resume(throwing: recordingError) }
                else { continuation.resume() }
            }
        }
        guard let directory else { return "" }
        try Task.checkCancellation()
        return try await Self.transcribe(audio: directory.appending(path: "audio.wav"), model: modelURL,
            executable: executableURL, output: directory.appending(path: "result"), locale: locale)
    }

    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in writer = nil; continuation.resume() }
        }
        removeRecording()
    }

    private func removeRecording() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    static func transcribe(audio: URL, model: URL, executable: URL, output: URL, locale: Locale) async throws -> String {
        let runner = WhisperProcess()
        try await runner.run(executable: executable, arguments: [
            "-m", model.path, "-f", audio.path, "-l", language(for: locale),
            "-t", "4", "-otxt", "-of", output.path, "-np", "-nt"
        ])
        try Task.checkCancellation()
        return try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func language(for locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? "auto"
        let aliases = ["nb": "no", "fil": "tl", "jv": "jw", "iw": "he", "in": "id", "ji": "yi"]
        let normalized = aliases[code] ?? code
        // Language IDs supported by the pinned whisper.cpp 1.9.5 engine.
        let supported = Set("""
        en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt
        la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc
        ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue
        """.split(whereSeparator: \.isWhitespace).map(String.init))
        return supported.contains(normalized) ? normalized : "auto"
    }
}

private final class WhisperProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(executable: URL, arguments: [String]) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                // Never log microphone audio or transcript output.
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { process in
                    if process.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: WhisperError.failed) }
                }
                lock.lock()
                defer { lock.unlock() }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.process = process
                do { try process.run() }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            if let process = self.process, process.isRunning { process.terminate() }
            self.lock.unlock()
        }
    }
}
