import Foundation
import Testing
@testable import Yap

private final class UpdateTestBundle: NSObject { }
struct ReleaseUpdatesTests {
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
