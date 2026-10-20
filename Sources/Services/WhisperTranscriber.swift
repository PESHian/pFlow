@preconcurrency import AVFoundation
import Foundation

/// Only the optional Whisper path writes audio. Files stay in a private,
/// short-lived directory and the existing capture/level pipeline is shared.
final class WhisperTranscriber: StreamingTranscriber {
    var onTranscript: ((String) -> Void)?
    var onLiveStopped: (() -> Void)?
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
    /// Live text only. Off starts no live worker and runs no extra inference.
    private let liveWorker: (() -> WhisperLiveWorking)?
    /// Touched only on `queue` once recording starts.
    private var live: WhisperLiveRecognizer?

    init(modelURL: URL = WhisperModelStore.modelURL,
         executableURL: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/whisper-cli"),
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         liveWorker: (() -> WhisperLiveWorking)? = nil) {
        self.modelURL = modelURL
        self.executableURL = executableURL
        self.temporaryDirectory = temporaryDirectory
        self.liveWorker = liveWorker
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
        if let liveWorker {
            // The take's own language, every window. The helper keeps no text
            // between windows, so nothing carries over from another take.
            let recognizer = WhisperLiveRecognizer(worker: liveWorker(), language: Self.language(for: locale),
                onText: { [weak self] in self?.onTranscript?($0) },
                onFailure: { [weak self] in self?.onLiveStopped?() })
            queue.sync { live = recognizer }
            recognizer.start()
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
                let converted = try converter.convertBuffer(copy, to: writer.processingFormat)
                try writer.write(from: converted)
                if let live, let samples = converted.floatChannelData {
                    live.append(UnsafeBufferPointer(start: samples[0], count: Int(converted.frameLength)))
                }
            } catch { recordingError = error }
        }
    }

    /// The finished text always comes from one pass over the whole recording,
    /// the same as with Live text Off, so it includes the last words. Live
    /// windows only feed the preview; their words are kept if that pass fails.
    /// With Live text on, the live helper already holds the model, so it runs
    /// that pass itself with whisper-cli's exact decoding; if it cannot,
    /// whisper-cli runs as usual.
    func finish() async throws -> String {
        defer { removeRecording() }
        let (shown, worker, failure) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(String, WhisperLiveWorking?, Error?), Never>) in
            queue.async { [self] in
                writer = nil
                let (shown, worker) = live?.stopKeepingWorker() ?? ("", nil)
                live = nil
                continuation.resume(returning: (shown, worker, recordingError))
            }
        }
        defer { worker?.stop() }
        do {
            if let failure { throw failure }
            guard let directory else { return "" }
            try Task.checkCancellation()
            let audio = directory.appending(path: "audio.wav")
            let language = Self.language(for: locale)
            if let worker, let text = try await Self.finishWithHelper(worker, audio: audio, language: language) {
                return text
            }
            return try await Self.transcribe(audio: audio, model: modelURL,
                executable: executableURL, output: directory.appending(path: "result"), locale: locale)
        } catch {
            let kept = shown.trimmingCharacters(in: .whitespacesAndNewlines)
            if kept.isEmpty || error is CancellationError { throw error }
            throw TranscriptionError.interrupted(kept: kept)
        }
    }

    /// The helper's finished text, or nil when it could not make it (whisper-cli
    /// then runs). Cancelling ends the helper and throws.
    private static func finishWithHelper(_ worker: WhisperLiveWorking, audio: URL, language: String) async throws -> String? {
        let text: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: try? worker.finishTake(recording: audio, language: language,
                                                                          threads: finalThreads))
                }
            }
        } onCancel: {
            worker.stop()
        }
        try Task.checkCancellation()
        return text.map(finishedText)
    }

    func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                writer = nil
                live?.stop()
                live = nil
                continuation.resume()
            }
        }
        removeRecording()
    }

    private func removeRecording() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    static func transcribe(audio: URL, model: URL, executable: URL, output: URL, locale: Locale) async throws -> String {
        let runner = WhisperProcess()
        try await runner.run(executable: executable, arguments: arguments(audio: audio, model: model, output: output,
                                                                      language: language(for: locale)))
        try Task.checkCancellation()
        return finishedText(try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8))
    }

    /// whisper-cli's options for the whole-recording pass. Timestamps stay on:
    /// with `-nt` whisper.cpp jumps a full 30 s after each window instead of
    /// resuming at the last finished sentence, so words at a window's edge, or
    /// after a window it ended early, were lost on takes over about a minute.
    /// The text file never contains the timestamps.
    static func arguments(audio: URL, model: URL, output: URL, language: String) -> [String] {
        ["-m", model.path, "-f", audio.path, "-l", language,
         "-t", "\(finalThreads)", "-otxt", "-of", output.path, "-np"]
    }

    /// Threads for the whole-recording pass, whichever process runs it.
    static let finalThreads = 4

    /// whisper-cli's text output (one line per segment) as the take's finished
    /// text: the segments joined by single spaces, as one paragraph.
    static func finishedText(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
