import AppKit
import CryptoKit
import Foundation
import os
import SwiftUI

/// The newest public pFlow for Mac on GitHub, for builds that cannot install
/// themselves (every build without a Developer ID team signature). pFlow asks
/// GitHub only when the person presses the button, downloads the DMG into
/// Downloads, checks it against GitHub's own SHA-256 before keeping it, and
/// opens it. The person drags the app to Applications; an unsigned build
/// never replaces itself.
struct GitHubRelease: Equatable {
    let version: String
    /// The release page, for the person to open.
    let page: URL
    let dmg: URL
    let bytes: Int64
    /// From the asset's "digest" field (sha256:…), lowercase hex.
    let sha256: String
    /// The release's pFlow-Mac-<version>.dmg.sha256 asset, when there is one.
    let checksumFile: URL?
}

enum GitHubReleases {
    static let latest = URL(string: "https://api.github.com/repos/PESHian/pFlow/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/PESHian/pFlow/releases/latest")!

    enum Answer: Equatable {
        case newer(GitHubRelease)
        case upToDate
    }

    enum Problem: Error, Equatable {
        case offline, rateLimited, noMacAsset, noChecksum, disk, mismatch
    }

    /// Reads the releases/latest answer. Only a published (not draft, not
    /// prerelease) release counts, and only its asset named exactly
    /// pFlow-Mac-<x.y.z>.dmg; it is offered only when newer than `current`.
    static func read(_ data: Data, current: String) throws -> Answer {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int64; let digest: String? }
        struct Release: Decodable { let html_url: String?; let draft: Bool?; let prerelease: Bool?; let assets: [Asset] }
        guard data.count <= 1_048_576, let release = try? JSONDecoder().decode(Release.self, from: data) else { throw Problem.noMacAsset }
        guard release.draft == false, release.prerelease == false else { throw Problem.noMacAsset }
        let named = release.assets.compactMap { asset -> (String, Asset)? in
            guard let version = dmgVersion(asset.name) else { return nil }
            return (version, asset)
        }
        guard let (version, asset) = named.max(by: { newer(than: $0.0, $1.0) }),
              let dmg = URL(string: asset.browser_download_url), downloadable(dmg, name: asset.name),
              asset.size > 0, asset.size <= 536_870_912 else { throw Problem.noMacAsset }
        guard newer(than: current, version) else { return .upToDate }
        guard let sha = asset.digest.flatMap(sha256(fromDigest:)) else { throw Problem.noChecksum }
        let checksum = release.assets.first { $0.name == asset.name + ".sha256" }
            .flatMap { URL(string: $0.browser_download_url) }
            .flatMap { downloadable($0, name: asset.name + ".sha256") ? $0 : nil }
        let page = release.html_url.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "github.com" ? $0 : nil } ?? releasesPage
        return .newer(GitHubRelease(version: version, page: page, dmg: dmg, bytes: asset.size, sha256: sha, checksumFile: checksum))
    }

    /// pFlow-Mac-<x.y.z>.dmg exactly: no -testing, -live-text-test or other suffix.
    static func dmgVersion(_ name: String) -> String? {
        guard let match = name.wholeMatch(of: /pFlow-Mac-((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))\.dmg/) else { return nil }
        return String(match.1)
    }

    /// True when `candidate` is a later version than `current`, part by part as numbers.
    static func newer(than current: String, _ candidate: String) -> Bool {
        guard let a = try? ReleaseCatalog.version(current), let b = try? ReleaseCatalog.version(candidate) else { return false }
        return a.lexicographicallyPrecedes(b)
    }

    /// sha256:<64 hex> → the hex, lowercase.
    static func sha256(fromDigest digest: String) -> String? {
        guard let match = digest.wholeMatch(of: /sha256:([0-9a-fA-F]{64})/) else { return nil }
        return match.1.lowercased()
    }

    /// The first 64-hex word of a .sha256 file.
    static func sha256(fromChecksumFile text: String) -> String? {
        guard let word = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first,
              word.wholeMatch(of: /[0-9a-fA-F]{64}/) != nil else { return nil }
        return word.lowercased()
    }

    /// A pFlow release download on github.com, over HTTPS only.
    static func downloadable(_ url: URL, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil && url.query == nil && url.fragment == nil
            && url.path.range(of: #"^/PESHian/pFlow/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            && url.lastPathComponent == name
    }

    /// Where the download goes: pFlow-Mac-<version>.dmg in `folder`; a file
    /// already there with other contents is never overwritten, a numbered name
    /// is used instead; the same file already there is used as it is.
    static func destination(in folder: URL, version: String, sha256: String, hashOf: (URL) -> String?, exists: (URL) -> Bool) -> (url: URL, alreadyThere: Bool) {
        for n in 1...99 {
            let name = n == 1 ? "pFlow-Mac-\(version).dmg" : "pFlow-Mac-\(version) (\(n)).dmg"
            let url = folder.appendingPathComponent(name)
            guard exists(url) else { return (url, false) }
            if hashOf(url) == sha256 { return (url, true) }
        }
        return (folder.appendingPathComponent("pFlow-Mac-\(version) (\(UUID().uuidString.prefix(6))).dmg"), false)
    }

    static func problem(status: Int) -> Problem? {
        switch status {
        case 200: return nil
        case 403, 429: return .rateLimited
        case 404: return .noMacAsset
        default: return .offline
        }
    }

    static func problem(_ error: Error) -> Problem {
        if let problem = error as? Problem { return problem }
        if let url = error as? URLError {
            switch url.code {
            case .cannotCreateFile, .cannotWriteToFile, .cannotMoveFile, .cannotOpenFile: return .disk
            default: return .offline
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteOutOfSpaceError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError,
                                             NSFileWriteUnknownError, NSFileNoSuchFileError].contains(ns.code) { return .disk }
        if ns.domain == NSPOSIXErrorDomain, [Int(ENOSPC), Int(EACCES), Int(EPERM), Int(EROFS)].contains(ns.code) { return .disk }
        return .offline
    }
}

/// The steps of the update window. Each state shows only what applies to it.
enum GitHubUpdateState: Equatable {
    case idle
    case checking
    case newer(GitHubRelease)
    case upToDate(String)
    case downloading(GitHubRelease, received: Int64, total: Int64)
    case verifying(GitHubRelease)
    case ready(GitHubRelease, file: URL)
    case failed(GitHubReleases.Problem, retry: GitHubRelease?)
}

/// The network side, replaceable in tests.
struct GitHubUpdateNetwork {
    /// The releases/latest answer: data and HTTP status.
    var latest: () async throws -> (Data, Int)
    /// Downloads `url` to a temporary file, reporting bytes received.
    var download: (URL, @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
    /// A small text file (the .sha256 asset).
    var text: (URL) async throws -> String

    static let live: GitHubUpdateNetwork = {
        let client = GitHubClient()
        return GitHubUpdateNetwork(latest: { try await client.latest() },
                                   download: { try await client.download($0, progress: $1) },
                                   text: { try await client.text($0) })
    }()
}

/// The one HTTPS client: api.github.com once per check, then GitHub's
/// release download (following its redirect to GitHub's own hosts only).
final class GitHubClient: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static func allowed(_ url: URL) -> Bool { url.host == "api.github.com" ? url.scheme == "https" && url.port == nil : UpdateNetwork.allowed(url) }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 1800
        config.httpAdditionalHeaders = ["User-Agent": "pFlow-update/1", "Accept": "application/vnd.github+json"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private var waiters: [Int: (CheckedContinuation<URL, Error>, @Sendable (Int64, Int64) -> Void)] = [:]
    private var finished: [Int: URL] = [:]
    private let lock = NSLock()

    func latest() async throws -> (Data, Int) {
        let (data, response) = try await session.data(from: GitHubReleases.latest)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func text(_ url: URL) async throws -> String {
        guard Self.allowed(url) else { throw GitHubReleases.Problem.mismatch }
        let (data, response) = try await session.data(from: url)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GitHubReleases.Problem.offline }
        if let problem = GitHubReleases.problem(status: status) { throw problem }
        return String(decoding: data.prefix(4096), as: UTF8.self)
    }

    func download(_ url: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard Self.allowed(url) else { throw GitHubReleases.Problem.mismatch }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { waiters[task.taskIdentifier] = (continuation, progress) }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allowed) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 536_870_912 { downloadTask.cancel(); return }
        let report = lock.withLock { waiters[downloadTask.taskIdentifier]?.1 }
        report?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system removes `location` when this returns: keep it under a name of our own.
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-download-\(UUID().uuidString).dmg")
        if (try? FileManager.default.moveItem(at: location, to: kept)) != nil {
            lock.withLock { finished[downloadTask.taskIdentifier] = kept }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiter, file) = lock.withLock { (waiters.removeValue(forKey: task.taskIdentifier), finished.removeValue(forKey: task.taskIdentifier)) }
        guard let (continuation, _) = waiter else { if let file { try? FileManager.default.removeItem(at: file) }; return }
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation.resume(throwing: error)
        } else if let file {
            continuation.resume(returning: file)
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            continuation.resume(throwing: GitHubReleases.problem(status: status) ?? .offline)
        }
    }
}

/// The update window's logic for builds that cannot install themselves.
@MainActor
final class GitHubUpdates: ObservableObject {
    @Published private(set) var state: GitHubUpdateState = .idle
    private var task: Task<Void, Never>?
    private static let log = Logger(subsystem: ReasonLog.subsystem, category: "updates")

    var network: GitHubUpdateNetwork
    var downloads: () -> URL? = { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var current: () -> String = { GitHubUpdates.runningVersion }

    init(network: GitHubUpdateNetwork = .live) { self.network = network }

    /// The version this app reports (Debug builds can pretend to be older, to try an update end to end).
    static var runningVersion: String {
        #if DEBUG
        if let pretend = UserDefaults.standard.string(forKey: "pflow.debug.reportVersion"), (try? ReleaseCatalog.version(pretend)) != nil { return pretend }
        #endif
        return MacUpdates.current
    }

    func check() {
        task?.cancel()
        state = .checking
        Self.log.notice("update check: asking GitHub for the latest release")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, status) = try await network.latest()
                try Task.checkCancellation()
                if let problem = GitHubReleases.problem(status: status) { throw problem }
                switch try GitHubReleases.read(data, current: current()) {
                case .newer(let release):
                    Self.log.notice("update check: a newer release is on GitHub")
                    state = .newer(release)
                case .upToDate:
                    Self.log.notice("update check: this is the newest release")
                    state = .upToDate(current())
                }
            } catch is CancellationError {
                state = .idle
            } catch {
                fail(GitHubReleases.problem(error), retry: nil)
            }
        }
    }

    func download(_ release: GitHubRelease) {
        task?.cancel()
        state = .downloading(release, received: 0, total: release.bytes)
        Self.log.notice("update download: started")
        task = Task { [weak self] in
            guard let self else { return }
            var temporary: URL?
            do {
                guard let folder = downloads(), FileManager.default.isWritableFile(atPath: folder.path) else { throw GitHubReleases.Problem.disk }
                let file = try await network.download(release.dmg) { received, total in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(release, received: received, total: total > 0 ? total : release.bytes)
                    }
                }
                temporary = file
                try Task.checkCancellation()
                state = .verifying(release)
                try await verify(file, release: release)
                try Task.checkCancellation()
                let place = GitHubReleases.destination(in: folder, version: release.version, sha256: release.sha256,
                                                       hashOf: { try? ReleaseCatalog.hash($0) },
                                                       exists: { FileManager.default.fileExists(atPath: $0.path) })
                if place.alreadyThere {
                    try? FileManager.default.removeItem(at: file)
                } else {
                    try FileManager.default.moveItem(at: file, to: place.url)
                }
                temporary = nil
                Self.log.notice("update download: checked against GitHub's checksum and kept")
                state = .ready(release, file: place.url)
                open(place.url)
            } catch is CancellationError {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                Self.log.notice("update download: cancelled")
                state = .newer(release)
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                if (error as? URLError)?.code == .cancelled { state = .newer(release); return }
                fail(GitHubReleases.problem(error), retry: release)
            }
        }
    }

    /// The download matches GitHub's digest for the asset, and the release's
    /// .sha256 file when there is one; otherwise it is deleted.
    private func verify(_ file: URL, release: GitHubRelease) async throws {
        let actual = try await Task.detached { try ReleaseCatalog.hash(file) }.value
        var expected = [release.sha256]
        if let checksumFile = release.checksumFile {
            guard let listed = GitHubReleases.sha256(fromChecksumFile: try await network.text(checksumFile)) else {
                try? FileManager.default.removeItem(at: file)
                throw GitHubReleases.Problem.mismatch
            }
            expected.append(listed)
        }
        guard !expected.isEmpty, expected.allSatisfy({ $0 == actual }) else {
            try? FileManager.default.removeItem(at: file)
            throw GitHubReleases.Problem.mismatch
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    #if DEBUG
    /// The Debug harness renders each step of the window.
    func showForRendering(_ state: GitHubUpdateState) { task?.cancel(); self.state = state }
    #endif

    private func fail(_ problem: GitHubReleases.Problem, retry: GitHubRelease?) {
        Self.log.notice("update: stopped (\(String(describing: problem), privacy: .public))")
        state = .failed(problem, retry: retry)
    }

    func retry() {
        if case .failed(_, let release?) = state { download(release) } else { check() }
    }

    func openReleasePage() {
        let page: URL
        switch state {
        case .newer(let r), .verifying(let r), .downloading(let r, _, _), .ready(let r, _): page = r.page
        case .failed(_, let r?): page = r.page
        default: page = GitHubReleases.releasesPage
        }
        NSWorkspace.shared.open(page)
    }
}

extension GitHubReleases.Problem {
    /// The one plain line for each problem.
    var message: String {
        switch self {
        case .offline: return "pFlow couldn't reach GitHub. Check your internet connection."
        case .rateLimited: return "GitHub is limiting requests right now. Try again in a few minutes."
        case .noMacAsset: return "The latest release on GitHub has no Mac download yet."
        case .noChecksum: return "GitHub didn't list a checksum for this download, so pFlow won't download it."
        case .disk: return "pFlow couldn't save to your Downloads folder. Check that there's free space and that it can be written to."
        case .mismatch: return "The download didn't match GitHub's checksum, so pFlow deleted it."
        }
    }
}

/// The update window for builds that cannot install themselves.
struct GitHubUpdateView: View {
    @ObservedObject var updates: GitHubUpdates
    var quit: () -> Void = { NSApp.terminate(nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("pFlow \(GitHubUpdates.runningVersion)").font(.title2.bold())
            content
        }
        .padding(24)
        .frame(width: 400, alignment: .leading)
        .onDisappear { updates.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch updates.state {
        case .idle:
            Text("Check GitHub for a newer version. pFlow checks only when you ask.")
            Button("Check for updates") { updates.check() }.keyboardShortcut(.defaultAction)
        case .checking:
            Text("Checking GitHub…")
            Button("Check for updates") {}.disabled(true)
            ProgressView().controlSize(.small)
        case .newer(let release):
            Text("pFlow \(release.version) is on GitHub.")
            Button("Download") { updates.download(release) }.keyboardShortcut(.defaultAction)
            Text(Self.size(release.bytes)).font(.callout).foregroundStyle(.secondary)
        case .upToDate(let version):
            Text("You have the newest version (\(version)).")
            Button("Check again") { updates.check() }
        case .downloading(let release, let received, let total):
            Text("Downloading pFlow \(release.version)…")
            Button("Cancel") { updates.cancel() }
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("\(Self.size(received)) of \(Self.size(total)) · \(Self.percent(received, total))")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        case .verifying:
            Text("Checking the download against GitHub's checksum…")
            ProgressView().controlSize(.small)
        case .ready(let release, _):
            Text("pFlow \(release.version) is downloaded and checked. Its window is open.")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Quit pFlow.")
                Text("2. Drag pFlow by Pesh to Applications and choose Replace.")
                Text("3. Open it, and press Grant for Accessibility again.")
            }
            Button("Quit pFlow") { quit() }.keyboardShortcut(.defaultAction)
        case .failed(let problem, _):
            Text(problem.message).fixedSize(horizontal: false, vertical: true)
            Button("Try again") { updates.retry() }.keyboardShortcut(.defaultAction)
            Button("Open the release page") { updates.openReleasePage() }.buttonStyle(.link)
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func percent(_ received: Int64, _ total: Int64) -> String {
        guard total > 0 else { return "0%" }
        return "\(min(100, Int(Double(received) / Double(total) * 100)))%"
    }
}
