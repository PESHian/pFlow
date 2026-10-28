import Foundation
import Testing
@testable import Yap

/// Check for updates on builds that cannot install themselves: the latest
/// public release on GitHub, its exact Mac DMG, GitHub's checksum, and the
/// window's steps. Fictional release data only.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitHubUpdatesTests {
    static let sha = "026e4539fd4bb02d7c8e7ac5050a89aab3f1b53de2b89081941757f15c5b127f"

    static func asset(_ name: String, digest: String? = "sha256:\(sha)", size: Int = 6_601_374, tag: String = "pflow-desktop-2026.10.25.1") -> String {
        let d = digest.map { "\"digest\": \"\($0)\"," } ?? ""
        return """
        {"name": "\(name)", \(d) "size": \(size), "browser_download_url": "https://github.com/PESHian/pFlow/releases/download/\(tag)/\(name)"}
        """
    }

    static func release(_ assets: [String], prerelease: Bool = false, draft: Bool = false) -> Data {
        Data("""
        {"tag_name": "pflow-desktop-2026.10.25.1", "html_url": "https://github.com/PESHian/pFlow/releases/tag/pflow-desktop-2026.10.25.1",
         "draft": \(draft), "prerelease": \(prerelease), "assets": [\(assets.joined(separator: ","))]}
        """.utf8)
    }

    static let normal = release([asset("pFlow-Mac-0.3.17.dmg"), asset("pFlow-Mac-0.3.17-testing.dmg"), asset("pFlow-Windows-x64-0.1.17.zip")])

    // MARK: Reading the release

    @Test func aNewerReleaseIsOffered() throws {
        guard case .newer(let release) = try GitHubReleases.read(Self.normal, current: "0.3.16") else { Issue.record("not offered"); return }
        #expect(release.version == "0.3.17")
        #expect(release.sha256 == Self.sha)
        #expect(release.dmg.lastPathComponent == "pFlow-Mac-0.3.17.dmg", "never the -testing one")
        #expect(release.bytes == 6_601_374)
        #expect(release.page.absoluteString == "https://github.com/PESHian/pFlow/releases/tag/pflow-desktop-2026.10.25.1")
    }

    @Test func anEqualOrOlderReleaseIsNotOffered() throws {
        #expect(try GitHubReleases.read(Self.normal, current: "0.3.17") == .upToDate)
        #expect(try GitHubReleases.read(Self.normal, current: "0.3.18") == .upToDate)
        #expect(try GitHubReleases.read(Self.normal, current: "0.4.0") == .upToDate)
    }

    @Test func aPrereleaseOrDraftNeverCounts() {
        #expect(throws: GitHubReleases.Problem.noMacAsset) {
            try GitHubReleases.read(Self.release([Self.asset("pFlow-Mac-0.9.0.dmg")], prerelease: true), current: "0.3.16")
        }
        #expect(throws: GitHubReleases.Problem.noMacAsset) {
            try GitHubReleases.read(Self.release([Self.asset("pFlow-Mac-0.9.0.dmg")], draft: true), current: "0.3.16")
        }
    }

    @Test func onlyTheExactlyNamedMacDMGCounts() {
        for name in ["pFlow-Mac-0.3.18-testing.dmg", "pFlow-Mac-0.3.18-live-text-test.dmg", "pFlow-Mac-0.3.18.dmg.sha256", "pFlow-Mac-v0.3.18.dmg", "pflow-mac-0.3.18.dmg"] {
            #expect(throws: GitHubReleases.Problem.noMacAsset, "\(name)") {
                try GitHubReleases.read(Self.release([Self.asset(name)]), current: "0.3.16")
            }
        }
    }

    @Test func aReleaseWithNoMacAssetSaysSo() {
        #expect(throws: GitHubReleases.Problem.noMacAsset) {
            try GitHubReleases.read(Self.release([Self.asset("pFlow-Windows-x64-0.1.17.zip")]), current: "0.3.16")
        }
    }

    @Test func aMissingOrMalformedDigestIsNotOffered() {
        #expect(throws: GitHubReleases.Problem.noChecksum) {
            try GitHubReleases.read(Self.release([Self.asset("pFlow-Mac-0.3.17.dmg", digest: nil)]), current: "0.3.16")
        }
        for bad in ["sha256:1234", "md5:\(Self.sha)", "sha256:\(Self.sha)00", "\(Self.sha)"] {
            #expect(throws: GitHubReleases.Problem.noChecksum, "\(bad)") {
                try GitHubReleases.read(Self.release([Self.asset("pFlow-Mac-0.3.17.dmg", digest: bad)]), current: "0.3.16")
            }
        }
    }

    @Test func aDownloadOffGitHubIsRefused() {
        let foreign = """
        {"name": "pFlow-Mac-0.3.17.dmg", "digest": "sha256:\(Self.sha)", "size": 10, "browser_download_url": "http://github.com/PESHian/pFlow/releases/download/t/pFlow-Mac-0.3.17.dmg"}
        """
        #expect(throws: GitHubReleases.Problem.noMacAsset) { try GitHubReleases.read(Self.release([foreign]), current: "0.3.16") }
    }

    @Test func versionsCompareNumberPerNumber() {
        #expect(GitHubReleases.newer(than: "0.3.9", "0.3.10"))
        #expect(GitHubReleases.newer(than: "0.3.17", "0.4.0"))
        #expect(GitHubReleases.newer(than: "0.9.9", "1.0.0"))
        #expect(!GitHubReleases.newer(than: "0.3.17", "0.3.17"))
        #expect(!GitHubReleases.newer(than: "0.3.18", "0.3.17"))
        #expect(!GitHubReleases.newer(than: "0.3.17", "0.3.17.1"), "not a version")
    }

    @Test func theChecksumFileGivesItsFirstWord() {
        #expect(GitHubReleases.sha256(fromChecksumFile: "\(Self.sha.uppercased())  pFlow-Mac-0.3.17.dmg\n") == Self.sha)
        #expect(GitHubReleases.sha256(fromChecksumFile: "not a checksum") == nil)
    }

    // MARK: Where the file goes

    @Test func anExistingFileIsNeverOverwritten() {
        let folder = URL(fileURLWithPath: "/Users/fictional/Downloads")
        func at(_ taken: [String: GitHubReleases.Occupant], hash: String?) -> (url: URL, alreadyThere: Bool) {
            GitHubReleases.destination(in: folder, version: "0.3.17", sha256: Self.sha, hashOf: { _ in hash },
                                       occupant: { taken[$0.lastPathComponent] ?? .nothing })
        }
        let free = at([:], hash: nil)
        #expect(free.url.lastPathComponent == "pFlow-Mac-0.3.17.dmg" && !free.alreadyThere)
        let other = at(["pFlow-Mac-0.3.17.dmg": .regularFile], hash: "0000")
        #expect(other.url.lastPathComponent == "pFlow-Mac-0.3.17 (2).dmg" && !other.alreadyThere)
        let same = at(["pFlow-Mac-0.3.17.dmg": .regularFile], hash: Self.sha)
        #expect(same.url.lastPathComponent == "pFlow-Mac-0.3.17.dmg" && same.alreadyThere, "the same file is used as it is")
        let link = at(["pFlow-Mac-0.3.17.dmg": .other, "pFlow-Mac-0.3.17 (2).dmg": .other], hash: Self.sha)
        #expect(link.url.lastPathComponent == "pFlow-Mac-0.3.17 (3).dmg" && !link.alreadyThere,
                "a symlink or folder at the name is never followed or replaced, even one that would hash the same")
    }

    /// A real symlink (and a broken one) already in Downloads: the file is kept under the next name,
    /// even when the link points at a file with the very same bytes.
    @Test func aSymlinkInDownloadsIsNeverFollowed() async throws {
        let downloads = try folder()
        let payload = Data("fictional dmg bytes".utf8)
        let target = downloads.appendingPathComponent("elsewhere.dmg")
        try payload.write(to: target)
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("pFlow-Mac-0.3.17.dmg"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("pFlow-Mac-0.3.17 (2).dmg"),
                                                   withDestinationURL: downloads.appendingPathComponent("missing"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-fictional-\(UUID().uuidString).dmg")
        try payload.write(to: file)
        let release = GitHubRelease(version: "0.3.17", page: GitHubReleases.releasesPage, dmg: URL(string: "https://github.com/x")!,
                                    bytes: Int64(payload.count), sha256: SHA256Hex.of(payload), checksumFile: nil)
        let kept = try await GitHubReleases.keep(file, in: downloads, release: release)
        #expect(kept.lastPathComponent == "pFlow-Mac-0.3.17 (3).dmg")
        #expect(try Data(contentsOf: target) == payload, "the symlink's target is untouched")
        #expect(try Data(contentsOf: kept) == payload)
        #expect(try FileManager.default.attributesOfItem(atPath: kept.path)[.type] as? FileAttributeType == .typeRegular)
    }

    // MARK: The window's steps

    private final class Fake {
        var status = 200
        var json = GitHubUpdatesTests.normal
        var payload = Data("fictional dmg bytes".utf8)
        var checksumText: String?
        var latestCalls = 0
        var opened: [URL] = []
        var hang = false
        var offline = false
    }

    private func updates(_ fake: Fake, folder: URL) -> GitHubUpdates {
        let network = GitHubUpdateNetwork(
            latest: {
                fake.latestCalls += 1
                if fake.offline { throw URLError(.notConnectedToInternet) }
                return (fake.json, fake.status)
            },
            download: { _, progress in
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-fictional-\(UUID().uuidString).dmg")
                try fake.payload.write(to: file)
                progress(Int64(fake.payload.count) / 2, Int64(fake.payload.count))
                if fake.hang { try await Task.sleep(for: .seconds(30)) }
                return file
            },
            text: { _ in fake.checksumText ?? "" })
        let updates = GitHubUpdates(network: network)
        updates.downloads = { folder }
        updates.open = { fake.opened.append($0) }
        updates.current = { "0.3.16" }
        return updates
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-downloads-fictional-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func settle(_ updates: GitHubUpdates, until done: (GitHubUpdateState) -> Bool) async {
        for _ in 0..<200 where !done(updates.state) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func json(for payload: Data, checksumAsset: Bool = false) -> Data {
        let sha = SHA256Hex.of(payload)
        var assets = [Self.asset("pFlow-Mac-0.3.17.dmg", digest: "sha256:\(sha)", size: payload.count)]
        if checksumAsset { assets.append(Self.asset("pFlow-Mac-0.3.17.dmg.sha256", digest: nil, size: 90)) }
        return Self.release(assets)
    }

    @Test func checkThenDownloadVerifyThenOpen() async throws {
        let fake = Fake(), downloads = try folder()
        fake.json = json(for: fake.payload)
        let updates = updates(fake, folder: downloads)
        #expect(updates.state == .idle)
        updates.check()
        #expect(updates.state == .checking)
        await settle(updates) { if case .newer = $0 { true } else { false } }
        guard case .newer(let release) = updates.state else { Issue.record("\(updates.state)"); return }
        updates.download(release)
        await settle(updates) { if case .ready = $0 { true } else { false } }
        guard case .ready(_, let file) = updates.state else { Issue.record("\(updates.state)"); return }
        #expect(file == downloads.appendingPathComponent("pFlow-Mac-0.3.17.dmg"))
        #expect(try Data(contentsOf: file) == fake.payload)
        #expect(fake.opened == [file], "opened once, after the check")
        #expect(fake.latestCalls == 1, "one request to GitHub's API per press")
    }

    @Test func aMismatchedDownloadIsDeletedAndNeverOpened() async throws {
        let fake = Fake(), downloads = try folder()
        fake.json = json(for: Data("other bytes".utf8))
        let updates = updates(fake, folder: downloads)
        updates.check()
        await settle(updates) { if case .newer = $0 { true } else { false } }
        guard case .newer(let release) = updates.state else { Issue.record("\(updates.state)"); return }
        updates.download(release)
        await settle(updates) { if case .failed = $0 { true } else { false } }
        #expect(updates.state == .failed(.mismatch, retry: release))
        #expect(fake.opened.isEmpty, "never opened")
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty, "nothing kept")
    }

    @Test func theReleaseChecksumFileMustAgreeToo() async throws {
        let fake = Fake(), downloads = try folder()
        fake.json = json(for: fake.payload, checksumAsset: true)
        fake.checksumText = "\(String(repeating: "0", count: 64))  pFlow-Mac-0.3.17.dmg"
        let updates = updates(fake, folder: downloads)
        updates.check()
        await settle(updates) { if case .newer = $0 { true } else { false } }
        guard case .newer(let release) = updates.state else { Issue.record("\(updates.state)"); return }
        #expect(release.checksumFile != nil)
        updates.download(release)
        await settle(updates) { if case .failed = $0 { true } else { false } }
        #expect(updates.state == .failed(.mismatch, retry: release))
        #expect(fake.opened.isEmpty)
        fake.checksumText = "\(SHA256Hex.of(fake.payload))  pFlow-Mac-0.3.17.dmg"
        updates.retry()
        await settle(updates) { if case .ready = $0 { true } else { false } }
        #expect(fake.opened.count == 1)
    }

    @Test func cancelStopsTheDownloadAndKeepsNothing() async throws {
        let fake = Fake(), downloads = try folder()
        fake.json = json(for: fake.payload)
        fake.hang = true
        let updates = updates(fake, folder: downloads)
        updates.check()
        await settle(updates) { if case .newer = $0 { true } else { false } }
        guard case .newer(let release) = updates.state else { Issue.record("\(updates.state)"); return }
        updates.download(release)
        await settle(updates) { if case .downloading(_, let received, _) = $0 { received > 0 } else { false } }
        updates.cancel()
        await settle(updates) { if case .newer = $0 { true } else { false } }
        #expect(updates.state == .newer(release))
        #expect(fake.opened.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
    }

    @Test func eachProblemComesBackWithItsOwnState() async throws {
        let fake = Fake(), downloads = try folder()
        let updates = updates(fake, folder: downloads)
        fake.status = 403
        updates.check()
        await settle(updates) { if case .failed = $0 { true } else { false } }
        #expect(updates.state == .failed(.rateLimited, retry: nil))
        fake.status = 429
        updates.retry()
        await settle(updates) { if case .failed(.rateLimited, _) = $0 { true } else { false } }
        #expect(fake.latestCalls == 2)
        fake.status = 200
        fake.offline = true
        updates.retry()
        await settle(updates) { if case .failed(.offline, _) = $0 { true } else { false } }
        #expect(updates.state == .failed(.offline, retry: nil))
        fake.offline = false
        fake.json = Self.release([Self.asset("pFlow-Windows-x64-0.1.17.zip")])
        updates.retry()
        await settle(updates) { if case .failed(.noMacAsset, _) = $0 { true } else { false } }
        #expect(updates.state == .failed(.noMacAsset, retry: nil))
        fake.json = Self.normal
        updates.current = { "0.3.17" }
        updates.retry()
        await settle(updates) { if case .upToDate = $0 { true } else { false } }
        #expect(updates.state == .upToDate("0.3.17"))
    }

    @Test func noWritableDownloadsFolderIsADiskProblem() async throws {
        let fake = Fake()
        fake.json = json(for: fake.payload)
        let updates = updates(fake, folder: URL(fileURLWithPath: "/nonexistent-fictional-folder"))
        updates.check()
        await settle(updates) { if case .newer = $0 { true } else { false } }
        guard case .newer(let release) = updates.state else { Issue.record("\(updates.state)"); return }
        updates.download(release)
        await settle(updates) { if case .failed = $0 { true } else { false } }
        #expect(updates.state == .failed(.disk, retry: release))
        #expect(fake.opened.isEmpty)
    }

    @Test func everyProblemHasOnePlainLine() {
        for problem in [GitHubReleases.Problem.offline, .rateLimited, .noMacAsset, .noChecksum, .disk, .mismatch, .tooLarge] {
            #expect(!problem.message.isEmpty && problem.message.hasSuffix("."))
        }
        #expect(GitHubReleases.problem(status: 403) == .rateLimited && GitHubReleases.problem(status: 429) == .rateLimited)
        #expect(GitHubReleases.problem(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .disk)
        #expect(GitHubReleases.problem(URLError(.notConnectedToInternet)) == .offline)
        #expect(GitHubReleases.problem(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)) == .disk,
                "a file already at the name is a Downloads problem, not a network one")
    }

    @Test func thisAdHocTestHostCannotInstallItself() {
        #expect(!MacUpdateInstaller.canInstallItself)
    }
}

enum SHA256Hex {
    static func of(_ data: Data) -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-hash-\(UUID().uuidString)")
        try? data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        return (try? ReleaseCatalog.hash(file)) ?? ""
    }
}
