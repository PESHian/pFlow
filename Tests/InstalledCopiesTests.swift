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
        let unreadable = try bundle(root, "home/Downloads/beta/pFlow by Pesh.app", version: "0.3.10-beta")

        let me = try #require(InstalledCopies.copy(at: running))
        #expect(me.version == "0.3.9")
        let installed = [running, older, olderYap, sameVersion, newer, trashed, built, cached, buildFolder, unreadable].compactMap(InstalledCopies.copy(at:))
            + [InstalledCopies.Copy(url: URL(fileURLWithPath: "/Volumes/Install/pFlow by Pesh.app"), version: "0.0.1")]
        #expect(installed.count == 11)
        let found = InstalledCopies.older(than: me, among: installed)
        #expect(found.map(\.url) == [older, olderYap])
        #expect(found.map(\.version) == ["0.3.4", "0.2.11"])
        #expect(InstalledCopies.copy(at: root.appendingPathComponent("home/Documents/notes.app")) == nil)
    }

    @Test func versionsCompareNumericallyAndUnreadableOnesAreUnknown() {
        #expect(InstalledCopies.compare("0.3.9", "0.3.10") == .orderedAscending)
        #expect(InstalledCopies.compare("0.3", "0.3.0") == .orderedSame)
        #expect(InstalledCopies.compare("1.0", "0.9.9") == .orderedDescending)
        #expect(InstalledCopies.compare("0.3.4", "0.3.9") == .orderedAscending)
        #expect(InstalledCopies.compare("0.3.10-beta", "0.3.9") == nil)
        #expect(InstalledCopies.compare("", "0.3.9") == nil)
        #expect(InstalledCopies.parse("0.3.9") == [0, 3, 9] && InstalledCopies.parse("0..3") == nil)
    }

    private func copy(_ path: String, _ version: String) -> InstalledCopies.Copy {
        InstalledCopies.Copy(url: URL(fileURLWithPath: path), version: version)
    }

    @Test func aScratchCopyNeverActsOnTheRealInstall() {
        #expect(InstalledCopies.actsForInstall(copy("/Applications/pFlow by Pesh.app", "0.3.9")))
        #expect(InstalledCopies.actsForInstall(copy("/Users/someone/Applications/pFlow by Pesh.app", "0.3.9")))
        for scratch in ["/Users/someone/src/pflow/build/Build/Products/Release/pFlow.app",
                        "/Users/someone/Library/Developer/Xcode/DerivedData/Yap-x/Build/Products/Debug/pFlow.app",
                        "/Users/someone/Library/Caches/pFlow-scratch/pFlow.app",
                        "/Volumes/pFlow by Pesh/pFlow by Pesh.app",
                        "/Users/someone/.Trash/pFlow by Pesh.app"] {
            #expect(!InstalledCopies.actsForInstall(copy(scratch, "0.3.9")), Comment(rawValue: scratch))
        }
    }

    @Test func olderInstancesQuitNewerOnesWinAndUnknownOnesAreLeftAlone() {
        let me = copy("/Applications/pFlow by Pesh.app", "0.3.9")
        let old = copy("/Users/someone/Applications/pFlow by Pesh.app", "0.3.4")
        let previous = copy("/Applications/pFlow by Pesh.app", "0.3.9")
        let newer = copy("/Users/someone/Downloads/pFlow by Pesh.app", "0.3.10")
        let unknown = copy("/Users/someone/Desktop/pFlow by Pesh.app", "0.3.10-beta")
        #expect(InstalledCopies.instancePlan(running: me, others: [old, previous, unknown]) == .init(quit: [old, previous], stepAside: false))
        #expect(InstalledCopies.instancePlan(running: me, others: [old, newer]) == .init(quit: [], stepAside: true))
        #expect(InstalledCopies.instancePlan(running: me, others: []) == .init())
        // A build-folder copy only replaces its own earlier instance.
        let dev = copy("/Users/someone/src/pflow/build/Release/pFlow.app", "0.3.9")
        let devBefore = copy("/Users/someone/src/pflow/build/Release/pFlow.app", "0.3.9")
        #expect(InstalledCopies.instancePlan(running: dev, others: [old, devBefore, newer]) == .init(quit: [devBefore], stepAside: false))
    }

    @Test func loginItemIsNeverUnregisteredAndSettingsAlwaysSeeTheTruth() {
        struct Failed: Error {}
        var registered = 0, refreshed = 0
        #expect(InstalledCopies.pointLoginItemAtThisCopy(status: .enabled, register: { registered += 1 }, refresh: { refreshed += 1 }))
        #expect((registered, refreshed) == (1, 1))
        #expect(!InstalledCopies.pointLoginItemAtThisCopy(status: .enabled, register: { registered += 1; throw Failed() }, refresh: { refreshed += 1 }))
        #expect((registered, refreshed) == (2, 2), "a failed register still refreshes what Settings shows")
        #expect(!InstalledCopies.pointLoginItemAtThisCopy(status: .notRegistered, register: { registered += 1 }, refresh: { refreshed += 1 }))
        #expect(!InstalledCopies.pointLoginItemAtThisCopy(status: .requiresApproval, register: { registered += 1 }, refresh: { refreshed += 1 }))
        #expect((registered, refreshed) == (2, 2), "login off or awaiting approval: nothing touched")
    }
}
