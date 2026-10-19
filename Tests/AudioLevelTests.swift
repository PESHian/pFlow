import Testing
import AVFoundation
@testable import Yap

struct AudioLevelTests {
    @Test func waveformFollowsSyllablesWithoutHoldingPeaks() {
        #expect(AudioLevel.smoothWaveform(previous: 0, input: 0.8) > 0.65)
        let afterDip = AudioLevel.smoothWaveform(previous: 0.8, input: 0.2)
        #expect(afterDip < 0.45)
        #expect(afterDip >= 0.2)
    }

    @Test func subtleSpeechChangesHaveVisibleContrast() {
        let levels = AudioLevel.waveformLevels([0.28, 0.3, 0.34])
        #expect(levels[0] < levels[1] && levels[1] < levels[2])
        #expect(levels[2] - levels[0] > 0.15)
        #expect(levels[2] < 1)
    }

    @Test func waveformKeepsNoiseLowAndSilenceFlat() {
        #expect(AudioLevel.waveformLevels([0, 0, 0]) == [0, 0, 0])
        #expect(AudioLevel.waveformLevels([0, 0.01, 0.02]).allSatisfy { $0 < 0.1 })
    }

    @Test func louderMicrophonesRetainHeadroomAndDynamics() {
        let levels = [Float(0.32), 0.5, 0.8].map { AudioLevel.normalized(rms: $0) }
        #expect(levels[0] < levels[1])
        #expect(levels[1] < levels[2])
        #expect(levels[2] < 0.98)
        #expect(levels[2] - levels[0] > 0.2)
    }

    @Test func microphoneBuffersFollowSpeechAndReturnToSilence() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = try #require(buffer.floatChannelData?[0])
        let levels = [Float(0.02), 0.45, 0.75, 0].map { amplitude in
            for i in 0..<1024 { samples[i] = i.isMultiple(of: 2) ? amplitude : -amplitude }
            return AudioLevel.normalized(from: buffer)
        }
        #expect(levels[0] < levels[1])
        #expect(levels[1] < levels[2])
        #expect(levels[2] < 1)
        #expect(levels[3] == 0)
    }
    @Test func silenceIsZero() {
        #expect(AudioLevel.normalized(rms: 0) == 0)
    }

    @Test func fullScaleIsOne() {
        #expect(AudioLevel.normalized(rms: 1) == 1)
    }

    @Test func isMonotonicAndBounded() {
        let quiet = AudioLevel.normalized(rms: 0.01)
        let mid = AudioLevel.normalized(rms: 0.1)
        let loud = AudioLevel.normalized(rms: 0.5)
        #expect(quiet < mid)
        #expect(mid < loud)
        for value in [quiet, mid, loud] {
            #expect(value >= 0 && value <= 1)
        }
    }

    @Test func flooredBelowNoiseFloor() {
        // Anything below the -45 dB floor reads as silence.
        #expect(AudioLevel.normalized(rms: 0.0001) == 0)
    }

    @Test func speechRangeUsesMostOfTheTravel() {
        // Quiet speech (~-30 dB) and loud speech (~-14 dB) should be far apart,
        // otherwise the meter looks static while talking.
        let quietSpeech = AudioLevel.normalized(rms: 0.0316) // -30 dB
        let loudSpeech = AudioLevel.normalized(rms: 0.2)     // -14 dB
        #expect(loudSpeech - quietSpeech > 0.3)
    }
}
