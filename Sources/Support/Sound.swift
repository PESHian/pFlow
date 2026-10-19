import AppKit

protocol SoundPlaying {
    func playStart()
    func playStop()
}

final class SystemSoundPlayer: SoundPlaying {
    /// Evaluated at call time so the setting can be toggled live.
    var enabled: () -> Bool = { true }

    // Original, softly enveloped 90 ms cues, preloaded once and played asynchronously.
    private let start = Bundle.main.url(forResource: "dictation-start", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: false) }
    private let stop = Bundle.main.url(forResource: "dictation-stop", withExtension: "wav")
        .flatMap { NSSound(contentsOf: $0, byReference: false) }

    func playStart() {
        guard enabled() else { return }
        start?.volume = 0.18
        start?.stop()
        start?.play()
    }

    func playStop() {
        guard enabled() else { return }
        stop?.volume = 0.18
        stop?.stop()
        stop?.play()
    }
}
