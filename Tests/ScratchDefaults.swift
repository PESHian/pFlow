import Foundation
import Testing
@testable import Yap

/// A throwaway preferences domain for one test. Its name is a file path in a
/// temporary folder, so it never lands in ~/Library/Preferences (a removed
/// named domain still leaves an empty plist there); the folder is deleted when
/// the test lets go of it. Tests never use the app's own domain.
final class ScratchDefaults {
    let folder: URL
    /// The suite name: an absolute path, so the preferences file is <name>.plist in `folder`.
    let name: String
    let defaults: UserDefaults

    init(_ prefix: String) {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-test-defaults-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        name = folder.appendingPathComponent(prefix).path
        defaults = UserDefaults(suiteName: name)!
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }

    static var preferencesFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences", isDirectory: true)
    }
}

struct ScratchDefaultsTests {
    /// What the tests write never lands in ~/Library/Preferences, and is gone once they finish.
    @Test func aScratchDomainLeavesNothingBehind() async throws {
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: ScratchDefaults.preferencesFolder.path)) ?? [])
        var folder: URL?
        do {
            let scratch = ScratchDefaults("pflow.im.tests")
            folder = scratch.folder
            scratch.defaults.set("com.apple.keylayout.ABC", forKey: InputMethodLink.restoreKey)
            scratch.defaults.synchronize()
            #expect(UserDefaults(suiteName: scratch.name)?.string(forKey: InputMethodLink.restoreKey) == "com.apple.keylayout.ABC")
        }
        try await Task.sleep(for: .seconds(1))
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: ScratchDefaults.preferencesFolder.path)) ?? [])
        #expect(after.subtracting(before).filter { $0.hasPrefix("pflow.im.") }.isEmpty, "no pflow.im.* domain in ~/Library/Preferences")
        #expect(!FileManager.default.fileExists(atPath: folder!.path), "the scratch folder is gone")
    }

    /// The test host is a Debug build: its own app ID and input source, never pFlow's.
    @Test func theTestHostIsNotTheRealApp() throws {
        #expect(Bundle.main.bundleIdentifier == "com.pesh.Yap.debug")
        #expect(InputMethodWire.appIdentifier == "com.pesh.Yap.debug")
        #expect(InputMethodWire.sourceID == "com.pesh.inputmethod.pFlow.debug")
        #expect(InputMethodWire.bundleName == "pFlow Dictation Debug.app", "never installed over the real pFlow Dictation.app")
        #expect(FileManager.default.fileExists(atPath: InputMethodWire.embedded(in: Bundle.main.bundleURL).path))
        #expect(InputMethodWire.folder.lastPathComponent == "Input Debug", "never replaces the real pFlow's socket")
        let im = try #require(Bundle(url: InputMethodWire.embedded(in: Bundle.main.bundleURL))?.infoDictionary)
        #expect(im["CFBundleIdentifier"] as? String == "com.pesh.inputmethod.pFlow.debug")
        #expect(im["TISInputSourceID"] as? String == "com.pesh.inputmethod.pFlow.debug")
        #expect(im["InputMethodConnectionName"] as? String == "com.pesh.inputmethod.pFlow.debug_Connection")
        #expect(im["CFBundleDisplayName"] as? String == "pFlow Dictation (Debug)")
    }
}
