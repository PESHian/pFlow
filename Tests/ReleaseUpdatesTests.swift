import Foundation
import Testing
@testable import Yap

private final class UpdateTestBundle: NSObject { }
struct ReleaseUpdatesTests {
    @Test func productionTrustRejectsAdHocAppAndInvalidTeams() throws {
        for team in ["", "$(PFLOW_DEVELOPER_TEAM)", "SHORT", "TEAM\" or true"] {
            #expect(throws: (any Error).self) { try MacUpdateInstaller.developerRequirement(team: team) }
        }
        // The test host is ad-hoc signed. Use a syntactically valid team so this
        // exercises Apple's certificate policy, not the input validator.
        #expect(throws: (any Error).self) { try MacUpdateInstaller.verifyDeveloperID(Bundle.main.bundleURL, team: "PFLOWTEST1") }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PFLOW_TRUST_FIXTURE_APP"] != nil, "Requires an independently valid Developer ID app and its real team ID."))
    func realDeveloperIDTeamPolicy() throws {
        let env = ProcessInfo.processInfo.environment
        let app = URL(fileURLWithPath: try #require(env["PFLOW_TRUST_FIXTURE_APP"]))
        let team = try #require(env["PFLOW_TRUST_FIXTURE_TEAM"])
        #expect(team != "PFLOWTEST1")
        try MacUpdateInstaller.verifyDeveloperID(app, team: team)
        #expect(throws: (any Error).self) { try MacUpdateInstaller.verifyDeveloperID(app, team: "PFLOWTEST1") }
    }
    @Test func helperCopyKeepsItsSealAndRejectsModification() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("pflow-helper-fictional-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false); defer { try? fm.removeItem(at: root) }
        let original = Bundle.main.bundleURL, helper = root.appendingPathComponent("helper.app")
        let version = try #require(MacUpdateInstaller.metadata(original)["CFBundleShortVersionString"] as? String)
        func integrityOnly(_ app: URL, _ version: String) throws {
            try MacUpdateInstaller.verifyBundle(app, version: version)
            try MacUpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        }
        try MacUpdateInstaller.copyHelper(from: original, to: helper, version: version, validate: integrityOnly)
        for file in ["Contents/Info.plist", "Contents/MacOS/pFlow", "Contents/_CodeSignature/CodeResources"] {
            #expect(try Data(contentsOf: original.appendingPathComponent(file)) == Data(contentsOf: helper.appendingPathComponent(file)))
        }
        #expect(try MacUpdateInstaller.executable(helper) == helper.appendingPathComponent("Contents/MacOS/pFlow"))
        let tampered = root.appendingPathComponent("tampered.app")
        try fm.copyItem(at: helper, to: tampered)
        let program = try FileHandle(forWritingTo: tampered.appendingPathComponent("Contents/MacOS/pFlow"))
        try program.seek(toOffset: 4096); try program.write(contentsOf: Data([0, 1, 2, 3])); try program.close()
        #expect(throws: (any Error).self) { try integrityOnly(tampered, version) }
        let plist = helper.appendingPathComponent("Contents/Info.plist")
        var info = try MacUpdateInstaller.metadata(helper); info["CFBundleIdentifier"] = "com.pesh.Yap.UpdateHelper"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        #expect(throws: (any Error).self) { try integrityOnly(helper, version) }
    }
    @Test func executableMustBePermittedRegularAndInsideTheBundle() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("pflow-executable-fictional-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false); defer { try? fm.removeItem(at: root) }
        let real = try MacUpdateInstaller.executable(Bundle.main.bundleURL)
        #expect(real.lastPathComponent == "pFlow")
        // Each fixture declares `name` and places a real arm64 program at `file`
        // (relative to Contents), so only the rule under test can reject it.
        func fixture(_ name: String, file: String, link: URL? = nil, program: URL? = nil) throws -> URL {
            let app = root.appendingPathComponent("\(UUID().uuidString).app"), target = app.appendingPathComponent("Contents/" + file)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "com.pesh.Yap", "CFBundleExecutable": name, "CFBundleShortVersionString": "0.3.6"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            if let link { try fm.createSymbolicLink(at: target, withDestinationURL: link) } else { try fm.copyItem(at: program ?? real, to: target) }
            return app
        }
        let accepted = try fixture("pFlow", file: "MacOS/pFlow")
        #expect(try MacUpdateInstaller.executable(accepted) == accepted.appendingPathComponent("Contents/MacOS/pFlow"))
        try MacUpdateInstaller.verifyBundle(accepted, version: "0.3.6")
        for (name, file) in [("Yap", "MacOS/Yap"), ("Other", "MacOS/Other"), ("../pFlow", "pFlow"), ("../../pFlow", "../pFlow"), ("pFlow ", "MacOS/pFlow ")] {
            let app = try fixture(name, file: file)
            #expect(throws: (any Error).self, "\(name)") { try MacUpdateInstaller.executable(app) }
            #expect(throws: (any Error).self, "\(name)") { try MacUpdateInstaller.verifyBundle(app, version: "0.3.6") }
        }
        let outside = root.appendingPathComponent("outside"); try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.copyItem(at: real, to: outside.appendingPathComponent("pFlow"))
        let linkedFile = try fixture("pFlow", file: "MacOS/pFlow", link: outside.appendingPathComponent("pFlow"))
        let linkedFolder = try fixture("pFlow", file: "MacOS", link: outside)
        for app in [linkedFile, linkedFolder] {
            #expect(throws: (any Error).self) { try MacUpdateInstaller.executable(app) }
        }
        let source = root.appendingPathComponent("intel.c"), intel = root.appendingPathComponent("intel")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try MacUpdateInstaller.run("/usr/bin/xcrun", ["clang", "-arch", "x86_64", "-mmacosx-version-min=27.0", source.path, "-o", intel.path])
        let text = root.appendingPathComponent("not-a-program"); try Data("Fictional text, not a program.".utf8).write(to: text)
        for program in [intel, text] {
            let app = try fixture("pFlow", file: "MacOS/pFlow", program: program)
            #expect(try MacUpdateInstaller.executable(app).lastPathComponent == "pFlow")
            #expect(throws: (any Error).self) { try MacUpdateInstaller.verifyBundle(app, version: "0.3.6") }
        }
    }
    @Test func signedFeedAndVersionRules() throws {
        struct Vector: Decodable { let name: String; let data: String; let signature: String }
        let url = try #require(Bundle(for: UpdateTestBundle.self).url(forResource: "test-vectors", withExtension: "json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        for vector in vectors {
            let data = try #require(Data(base64Encoded: vector.data))
            if vector.name == "unknown schema" || vector.name == "Mac foreign host" {
                #expect(throws: (any Error).self) { try ReleaseCatalog.read(data, signature: vector.signature, current: "0.3.4") }
            } else {
                #expect(try ReleaseCatalog.read(data, signature: vector.signature, current: "0.3.4")?.version == "0.3.5")
                #expect(try ReleaseCatalog.read(data, signature: vector.signature, current: "0.3.5") == nil)
                #expect(try ReleaseCatalog.read(data, signature: vector.signature, current: "0.4.0") == nil)
                var changed = data; changed[0] ^= 1
                #expect(throws: (any Error).self) { try ReleaseCatalog.read(changed, signature: vector.signature, current: "0.3.4") }
            }
        }
        for value in ["0.3", "1.02.3", "-1.2.3", "1.2.3-testing", "1.2.3.4", "2147483648.0.0"] {
            #expect(throws: (any Error).self) { try ReleaseCatalog.version(value) }
        }
        #expect(try ReleaseCatalog.version("0.3.9").lexicographicallyPrecedes(ReleaseCatalog.version("0.3.12")))
        #expect(UpdateNetwork.allowed(URL(string: "https://release-assets.githubusercontent.com/fixture")!))
        #expect(!UpdateNetwork.allowed(URL(string: "http://github.com/fixture")!))
        #expect(!UpdateNetwork.allowed(URL(string: "https://github.com.attacker.example/fixture")!))
    }
    @Test func replacementKeepsDataAndRollsBackFailedLaunch() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("pflow-update-fictional-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false); defer { try? fm.removeItem(at: root) }
        let current = root.appendingPathComponent("current.app"), source = root.appendingPathComponent("candidate.app"), history = root.appendingPathComponent("fictional-history.txt")
        try Data("Fictional history.".utf8).write(to: history)
        func bundle(_ url: URL, _ text: String) throws { try fm.createDirectory(at: url, withIntermediateDirectories: false); try Data(text.utf8).write(to: url.appendingPathComponent("version")) }
        try bundle(current, "old"); try bundle(source, "new")
        #expect(throws: (any Error).self) { try MacUpdateInstaller.replace(source: source, destination: current) { throw UpdateError.failed } }
        #expect(try String(contentsOf: current.appendingPathComponent("version"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: source.appendingPathComponent("version"), encoding: .utf8) == "new")
        var launched = false
        try MacUpdateInstaller.replace(source: source, destination: current) { launched = true }
        #expect(launched)
        #expect(try String(contentsOf: current.appendingPathComponent("version"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: history, encoding: .utf8) == "Fictional history.")
        #expect(try fm.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix("pFlow.previous-") }))
    }
}
