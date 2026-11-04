import AVFoundation
import Foundation

/// Capture starts instantly, but preparing the speech analyzer takes a moment,
/// so buffers captured before a sink attaches are held here and flushed on
/// attach — otherwise the first words of a sentence are lost.
///
/// Receives on the audio thread, so all access is lock-protected.
final class AudioBufferRelay {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var sink: ((AVAudioPCMBuffer) -> Void)?

    /// ~2048 frames each; 1500 is roughly a minute at 48 kHz (a first take can
    /// wait that long while the speech model downloads). A ceiling in case the
    /// transcriber never becomes ready, so we don't grow without bound.
    private let maximumPending: Int
    /// Buffers that came past the ceiling and were not kept. Never silent: the take says so.
    private var droppedCount = 0

    init(maximumPending: Int = 1500) {
        self.maximumPending = maximumPending
    }

    #if DEBUG
    var maximumPendingForTesting: Int { maximumPending }
    #endif

    /// How many buffers were not kept since the last reset.
    var dropped: Int { lock.withLock { droppedCount } }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let sink {
            lock.unlock()
            sink(buffer)
            return
        }
        if pending.count < maximumPending {
            pending.append(buffer)
        } else {
            droppedCount += 1
        }
        lock.unlock()
    }

    func attach(_ sink: @escaping (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        let buffered = pending
        pending.removeAll()
        self.sink = sink
        lock.unlock()

        for buffer in buffered {
            sink(buffer)
        }
    }

    func reset() {
        lock.lock()
        sink = nil
        pending.removeAll()
        droppedCount = 0
        lock.unlock()
    }
}
