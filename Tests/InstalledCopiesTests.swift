import Foundation
import Testing
@testable import Yap

/// Fixture bundles in a temporary folder stand in for installed copies. No
/// real app, Launch Services record or Trash is touched.
struct InstalledCopiesTests {
    private func bundle(_ root: URL, _ path: String, version: String) throws -> URL {
        let app = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.pesh.Yap", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @Test func olderInstalledCopiesAreFoundAndScratchCopiesIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-copies-fictional-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let running = try bundle(root, "Applications/pFlow by Pesh.app", version: "0.3.9")
        let older = try bundle(root, "home/Applications/pFlow by Pesh.app", version: "0.3.4")
        let olderYap = try bundle(root, "home/Desktop/Yap.app", version: "0.2.11")
        let sameVersion = try bundle(root, "home/Downloads/pFlow by Pesh.app", version: "0.3.9")
        let newer = try bundle(root, "home/Downloads/new/pFlow by Pesh.app", version: "0.3.10")
        let trashed = try bundle(root, "home/.Trash/pFlow by Pesh.app", version: "0.3.4")
        let built = try bundle(root, "home/Library/Developer/Xcode/DerivedData/Yap-abc/Build/Products/Release/pFlow.app", version: "0.1.0")
        let cached = try bundle(root, "home/Library/Caches/pFlow-scratch/build/pFlow.app", version: "0.1.0")
        let buildFolder = try bundle(root, "home/src/build/pFlow.app", version: "0.1.0")

        let me = try #require(InstalledCopies.copy(at: running))
        #expect(me.version == "0.3.9")
        let installed = [running, older, olderYap, sameVersion, newer, trashed, built, cached, buildFolder].compactMap(InstalledCopies.copy(at:))
            + [InstalledCopies.Copy(url: URL(fileURLWithPath: "/Volumes/Install/pFlow by Pesh.app"), version: "0.0.1")]
        #expect(installed.count == 10)
        let found = InstalledCopies.older(than: me, among: installed)
        #expect(found.map(\.url) == [older, olderYap])
        #expect(found.map(\.version) == ["0.3.4", "0.2.11"])
        #expect(InstalledCopies.copy(at: root.appendingPathComponent("home/Documents/notes.app")) == nil)
    }

    @Test func versionsCompareNumerically() {
        #expect(InstalledCopies.compare("0.3.9", "0.3.10") == .orderedAscending)
        #expect(InstalledCopies.compare("0.3", "0.3.0") == .orderedSame)
        #expect(InstalledCopies.compare("1.0", "0.9.9") == .orderedDescending)
        #expect(InstalledCopies.compare("0.3.4", "0.3.9") == .orderedAscending)
    }
}
