import Foundation

/// Recognizes short live windows with a model that stays loaded for the take.
/// Calls block; the recognizer makes them one at a time off the audio thread.
protocol WhisperLiveWorking: AnyObject, Sendable {
    /// Starts the worker and loads the model once.
    func load() throws
    /// 16 kHz mono samples in, Whisper segments out.
    func recognize(_ samples: [Float], language: String) throws -> [WhisperWindowSegment]
    /// Safe from any thread. A call that is waiting fails promptly.
    func stop()
}

/// The bundled `pflow-whisper-live` helper (Metal). It talks over a private
/// pipe: no files, no listener, no logs. One helper per take, ended with it.
/// Protocol PFL1, all numbers little-endian:
///   hello:    u32 "PFL1", u32 threads, u32 length + UTF-8 model path
///   ready:    u32 1, f64 load ms        | failed: u32 3, u32 length + message
///   request:  u32 "PLQ1", u32 id, u32 length + language, u32 count + count f32 samples
///   result:   u32 2, u32 id, u32 n, n × (i32 from ms, i32 to ms, f32 no-speech, u32 length + text), f64 ms
///   error:    u32 3, u32 id, u32 length + message
final class WhisperLiveProcess: WhisperLiveWorking, @unchecked Sendable {
    static let hello: UInt32 = 0x314C_4650
    static let request: UInt32 = 0x3151_4C50
    static let maximumSamples = 30 * 16_000

    private let executable: URL
    private let model: URL
    private let threads: UInt32
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var stopped = false
    private var nextID: UInt32 = 0

    init(executable: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/pflow-whisper-live"),
         model: URL = WhisperModelStore.modelURL, threads: UInt32 = 4) {
        self.executable = executable
        self.model = model
        self.threads = threads
    }

    deinit { process?.terminate() }

    func load() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw WhisperError.engineMissing }
        let process = Process()
        let request = Pipe()
        let reply = Pipe()
        process.executableURL = executable
        process.standardInput = request
        process.standardOutput = reply
        // Never log microphone audio or transcript output.
        process.standardError = FileHandle.nullDevice
        // A helper that dies mid-write must fail the call, not end pFlow.
        _ = fcntl(request.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            try process.run()
            self.process = process
            input = request.fileHandleForWriting
            output = reply.fileHandleForReading
        }
        var message = Data()
        message.put(Self.hello)
        message.put(threads)
        message.put(text: model.path)
        try write(message)
        switch try readNumber() {
        case 1: _ = try read(8)
        case 3: _ = try readText(limit: 4096); throw WhisperError.failed
        default: throw WhisperError.failed
        }
    }

    func recognize(_ samples: [Float], language: String) throws -> [WhisperWindowSegment] {
        guard !samples.isEmpty, samples.count <= Self.maximumSamples else { throw WhisperError.failed }
        let id = lock.withLock { nextID &+= 1; return nextID }
        var message = Data(capacity: samples.count * 4 + 64)
        message.put(Self.request)
        message.put(id)
        message.put(text: language)
        message.put(UInt32(samples.count))
        samples.withUnsafeBytes { message.append(contentsOf: $0) }
        try write(message)
        let status = try readNumber()
        guard try readNumber() == id else { throw WhisperError.failed }
        guard status == 2 else { _ = try? readText(limit: 4096); throw WhisperError.failed }
        let count = try readNumber()
        guard count <= 512 else { throw WhisperError.failed }
        var segments: [WhisperWindowSegment] = []
        for _ in 0..<count {
            let from = Int(Int32(bitPattern: try readNumber()))
            let to = Int(Int32(bitPattern: try readNumber()))
            let noSpeech = Double(Float(bitPattern: try readNumber()))
            segments.append(WhisperWindowSegment(fromMs: from, toMs: to, text: try readText(limit: 65_536),
                                                 noSpeechProbability: noSpeech))
        }
        _ = try read(8)
        return segments
    }

    func stop() {
        let process = lock.withLock { stopped = true; return self.process }
        // Ending the helper makes a waiting read or write fail; nothing is left running.
        if let process, process.isRunning { process.terminate() }
    }

    private func write(_ data: Data) throws {
        guard let input = lock.withLock({ stopped ? nil : self.input }) else { throw CancellationError() }
        try input.write(contentsOf: data)
    }

    private func read(_ count: Int) throws -> Data {
        guard let output = lock.withLock({ stopped ? nil : self.output }) else { throw CancellationError() }
        var data = Data()
        while data.count < count {
            guard let chunk = try output.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw WhisperError.failed
            }
            data.append(chunk)
        }
        return data
    }

    private func readNumber() throws -> UInt32 {
        try read(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    private func readText(limit: Int) throws -> String {
        let length = Int(try readNumber())
        guard length <= limit else { throw WhisperError.failed }
        return length == 0 ? "" : String(decoding: try read(length), as: UTF8.self)
    }
}

private extension Data {
    mutating func put(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func put(text: String) {
        let bytes = Data(text.utf8)
        put(UInt32(bytes.count))
        append(bytes)
    }
}
