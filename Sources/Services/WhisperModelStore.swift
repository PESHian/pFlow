import Foundation
import CryptoKit
import Observation

enum WhisperError: LocalizedError {
    case modelNeeded, engineMissing, downloadFailed, invalidModel, failed
    var errorDescription: String? {
        switch self {
        case .modelNeeded: return "Download the Whisper model in Settings first."
        case .engineMissing: return "The Whisper engine is missing. Reinstall pFlow."
        case .downloadFailed: return "The model download failed. Try again when connected."
        case .invalidModel: return "The model could not be verified. Please download it again."
        case .failed: return "Whisper could not transcribe this recording."
        }
    }
}

@MainActor @Observable
final class WhisperModelStore {
    static let shared = WhisperModelStore()
    nonisolated static let expectedBytes: Int64 = 487_601_967
    nonisolated static let expectedSHA256 = "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
    nonisolated static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin")!
    nonisolated static var modelURL: URL {
        URL.applicationSupportDirectory.appending(path: "pFlow/Models/ggml-small.bin")
    }
    private(set) var isReady = false
    private(set) var isDownloading = false
    /// Bytes on disk so far while downloading, for the progress line.
    private(set) var receivedBytes: Int64 = 0
    private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let destination: URL

    init(destination: URL = WhisperModelStore.modelURL) {
        self.destination = destination
        isReady = Self.hasModel(at: destination)
    }

    nonisolated static func hasModel(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(expectedBytes)
    }

    nonisolated static func validate(_ url: URL, bytes: Int64 = expectedBytes,
                                    sha256: String = expectedSHA256) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
            try Task.checkCancellation()
            count += Int64(block.count)
            hash.update(data: block)
        }
        guard count == bytes,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw WhisperError.invalidModel
        }
    }

    func download() {
        guard !isDownloading, !isReady else { return }
        errorMessage = nil
        isDownloading = true
        receivedBytes = 0
        task = Task {
            defer { isDownloading = false; task = nil; receivedBytes = 0 }
            do {
                let temporary = FileManager.default.temporaryDirectory
                    .appending(path: "pflow-whisper-\(UUID().uuidString).part")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await Self.fetch(Self.downloadURL, to: temporary) { [weak self] bytes in self?.receivedBytes = bytes }
                let validation = Task.detached(priority: .utility) { try Self.validate(temporary) }
                try await withTaskCancellationHandler {
                    try await validation.value
                } onCancel: { validation.cancel() }
                try Task.checkCancellation()
                let destination = self.destination
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                // A verified download replaces only our own model, never user files.
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                isReady = true
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func cancelDownload() { task?.cancel() }

    /// Streams `url` to `file`, reporting the byte count as it grows (about
    /// every 4 MB), so Settings can show "Downloading… 120 MB of 488 MB".
    nonisolated static func fetch(_ url: URL, to file: URL, session: URLSession = .shared,
                                  progress: @escaping @MainActor (Int64) -> Void) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WhisperError.downloadFailed }
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WhisperError.downloadFailed
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var count: Int64 = 0
        var reported: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                count += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if count - reported >= 4 << 20 {
                    reported = count
                    await progress(count)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            count += Int64(buffer.count)
        }
        await progress(count)
    }
}
