import AppKit
import Testing
@testable import Yap

struct SoundCueTests {
    @Test func shortCuesAreBundledAndPlayable() throws {
        for name in ["dictation-start", "dictation-stop"] {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "wav"))
            let sound = try #require(NSSound(contentsOf: url, byReference: false))
            #expect(sound.duration >= 0.05)
            #expect(sound.duration <= 0.12)
        }
    }
}
