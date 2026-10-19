import AVFoundation

enum AudioLevel {
    static func smoothWaveform(previous: Float, input: Float) -> Float {
        let coefficient: Float = input > previous ? 0.9 : 0.65
        return previous + (input - previous) * coefficient
    }

    /// Emphasize syllables against the recent speech peak without boosting room
    /// noise to full height. All points still come from actual microphone input.
    static func waveformLevels(_ levels: [Float]) -> [Float] {
        let peak = max(0.25, levels.max() ?? 0)
        return levels.map { pow(max(0, min(1, $0 / peak)), 1.6) * 0.9 }
    }

    static func normalized(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        let samples = channelData[0]
        var sumSquares: Float = 0
        for i in 0..<frames {
            let sample = samples[i]
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        return normalized(rms: rms)
    }

    /// Keep headroom through digital full scale. Capping at -10 dB flattens
    /// louder microphone input into identical full-height bars. A gentle curve
    /// keeps room noise low while preserving differences between syllables.
    static func normalized(rms: Float) -> Float {
        let clampedRms = max(rms, 1e-7)
        let db = 20 * log10(clampedRms)
        let floor: Float = -45
        let ceiling: Float = 0
        let clamped = max(floor, min(ceiling, db))
        let linear = (clamped - floor) / (ceiling - floor)
        return pow(linear, 1.5)
    }
}
