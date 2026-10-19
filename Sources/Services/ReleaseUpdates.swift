import Foundation
import CryptoKit
import AppKit
import SwiftUI

struct ReleaseOffer: Codable, Equatable {
    let version: String
    let url: String
    let bytes: Int64
    let sha256: String
}
enum ReleaseCatalog {
    static let feedURL = URL(string: "https://raw.githubusercontent.com/PESHian/pFlow/main/updates/feed.json")!
    static let publicKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDVaJOvypkrygYKjZvGPzgLbHLa/eB3jkV34eeROTV076LiQrRX7T8YD7JH0P15YXeZPaC998aq/1Vw7RV/aK1g=="
    static func version(_ value: String) throws -> [Int] {
        guard value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { throw UpdateError.invalid }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 <= Int32.max }) else { throw UpdateError.invalid }
        return parts
    }
    static func read(_ data: Data, signature: String, current: String) throws -> ReleaseOffer? {
        guard data.count <= 65536, let der = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw UpdateError.invalid }
        let key = try P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: publicKey)!)
        guard key.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der), for: data) else { throw UpdateError.invalid }
        struct Feed: Decodable { let schema: Int; let targets: [String: ReleaseOffer] }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard feed.schema == 1 else { throw UpdateError.invalid }
        guard let offer = feed.targets["mac-arm64"] else { return nil }
        let next = try version(offer.version), previous = try version(current)
        guard let url = URL(string: offer.url), url.scheme == "https", url.host == "github.com", url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: #"^/PESHian/pFlow/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              url.lastPathComponent == "pFlow-Mac-\(offer.version)-testing.dmg", offer.bytes > 0, offer.bytes <= 536870912,
              offer.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { throw UpdateError.invalid }
        return previous.lexicographicallyPrecedes(next) ? offer : nil
    }
    static func hash(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 131072), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
enum UpdateError: Error { case invalid, busy, location, failed }
final class UpdateNetwork: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    static func allowed(_ url: URL) -> Bool { url.scheme == "https" && url.port == nil && url.user == nil && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "raw.githubusercontent.com"].contains(url.host ?? "") }
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 1800; config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "pFlow-update/1", "Cache-Control": "no-cache"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(request.url.map(Self.allowed) == true ? request : nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { if totalBytesWritten > 536870912 { downloadTask.cancel() } }
    func small(_ url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.failed }
        var result = Data()
        for try await byte in bytes { guard result.count < 65536 else { throw UpdateError.invalid }; result.append(byte) }
        return result
    }
    func check(current: String) async throws -> ReleaseOffer? {
        let data = try await small(ReleaseCatalog.feedURL)
        let signature = try await small(URL(string: ReleaseCatalog.feedURL.absoluteString + ".sig")!)
        return try ReleaseCatalog.read(data, signature: String(decoding: signature, as: UTF8.self), current: current)
    }
    func download(_ offer: ReleaseOffer, to destination: URL) async throws {
        let (temp, response) = try await session.download(from: URL(string: offer.url)!)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == offer.bytes,
              try ReleaseCatalog.hash(temp) == offer.sha256 else { throw UpdateError.invalid }
        try FileManager.default.moveItem(at: temp, to: destination)
    }
    func close() { session.invalidateAndCancel() }
}

struct MacUpdatePlan: Codable {
    let source: URL; let destination: URL; let version: String; let pid: Int32; let started: TimeInterval
}
enum MacUpdateInstaller {
    static func run(_ executable: String, _ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw UpdateError.failed }
    }
    static func verify(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.pesh.Yap", bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else { throw UpdateError.invalid }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/bin/lipo", ["-verify_arch", "arm64", app.appendingPathComponent("Contents/MacOS/Yap").path])
    }
    // The previous application is retained, including when launch fails.
    static func replace(source: URL, destination: URL, launch: () throws -> Void) throws {
        let fm = FileManager.default
        let backup = destination.deletingLastPathComponent().appendingPathComponent("pFlow.previous-\(UUID().uuidString).app")
        try fm.moveItem(at: destination, to: backup)
        do { try fm.moveItem(at: source, to: destination) }
        catch { try fm.moveItem(at: backup, to: destination); throw error }
        do { try launch() }
        catch {
            try fm.moveItem(at: destination, to: source)
            try fm.moveItem(at: backup, to: destination)
            throw error
        }
    }
    static func apply(_ file: URL) -> Int32 {
        let fm = FileManager.default, job = file.deletingLastPathComponent()
        do {
            let plan = try JSONDecoder().decode(MacUpdatePlan.self, from: Data(contentsOf: file))
            guard plan.source.lastPathComponent == "pFlow.app", plan.source.deletingLastPathComponent().lastPathComponent.hasPrefix(".pflow-update-"), plan.source.deletingLastPathComponent().deletingLastPathComponent() == plan.destination.deletingLastPathComponent(),
                  let old = NSRunningApplication(processIdentifier: plan.pid), old.bundleURL?.resolvingSymlinksInPath() == plan.destination,
                  let date = old.launchDate, abs(date.timeIntervalSince1970 - plan.started) < 0.01 else { throw UpdateError.invalid }
            try verify(plan.source, version: plan.version)
            try Data("ready".utf8).write(to: job.appendingPathComponent("ready"), options: .atomic)
            let deadline = Date().addingTimeInterval(120)
            while kill(plan.pid, 0) == 0 {
                guard Date() < deadline, !fm.fileExists(atPath: job.appendingPathComponent("cancel").path) else { throw UpdateError.failed }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard !fm.fileExists(atPath: job.appendingPathComponent("cancel").path), !NSRunningApplication.runningApplications(withBundleIdentifier: "com.pesh.Yap").contains(where: { $0.processIdentifier != getpid() && $0.bundleURL?.resolvingSymlinksInPath() == plan.destination }) else { throw UpdateError.busy }
            try replace(source: plan.source, destination: plan.destination) { try run("/usr/bin/open", ["-n", plan.destination.path]) }
            try Data("installed".utf8).write(to: job.appendingPathComponent("result"), options: .atomic)
            try? fm.removeItem(at: plan.source.deletingLastPathComponent())
            return 0
        } catch {
            try? Data("Update failed. The previous application was kept.".utf8).write(to: job.appendingPathComponent("result"), options: .atomic)
            return 1
        }
    }
}

@MainActor
final class MacUpdates: ObservableObject {
    static let shared = MacUpdates()
    @Published var message = "Check GitHub for a newer release. Checks run only when you ask."
    @Published var working = false
    @Published var offer: ReleaseOffer?
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let view = MacUpdateView(updates: self)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "pFlow updates"; window.contentView = NSHostingView(rootView: view); window.isReleasedWhenClosed = false; window.center(); self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func start() {
        guard !working else { return }; working = true
        task = Task {
            let network = UpdateNetwork(); defer { network.close(); working = false }
            do {
                if let offer { try await install(offer, network: network) }
                else { message = "Checking for updates…"; offer = try await network.check(current: Self.current); message = offer.map { "pFlow \($0.version) is ready. Your settings, history, and models stay on this Mac." } ?? "You have the latest published version." }
            } catch { message = "The update could not finish. Your installed app was kept. Check your connection and try again." }
        }
    }
    func cancel() { task?.cancel() }
    private func install(_ offer: ReleaseOffer, network: UpdateNetwork) async throws {
        let app = AppState.shared, fm = FileManager.default
        guard app.coordinator.state == .idle else { throw UpdateError.busy }
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { message = "Move pFlow into Applications before using in-app updates."; return }
        app.coordinator.updateInProgress = true; defer { app.coordinator.updateInProgress = false }
        let job = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("pFlow Updates/\(UUID().uuidString)")
        try fm.createDirectory(at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".pflow-update-\(UUID().uuidString)")
        var helper: Process?
        do {
            message = "Downloading and checking the update…"
            let disk = job.appendingPathComponent("update.dmg"); try await network.download(offer, to: disk); try Task.checkCancellation()
            let mount = job.appendingPathComponent("mount"); try fm.createDirectory(at: mount, withIntermediateDirectories: false)
            try MacUpdateInstaller.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, disk.path])
            defer { try? MacUpdateInstaller.run("/usr/bin/hdiutil", ["detach", mount.path]) }
            let candidate = mount.appendingPathComponent("pFlow by Pesh.app"); try MacUpdateInstaller.verify(candidate, version: offer.version)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let source = stage.appendingPathComponent("pFlow.app"); try fm.copyItem(at: candidate, to: source)
            try MacUpdateInstaller.run("/usr/bin/hdiutil", ["detach", mount.path])
            let plan = MacUpdatePlan(source: source, destination: destination, version: offer.version, pid: getpid(), started: NSRunningApplication.current.launchDate!.timeIntervalSince1970)
            let file = job.appendingPathComponent("plan.json"); try JSONEncoder().encode(plan).write(to: file, options: .atomic)
            let process = Process(); process.executableURL = Bundle.main.executableURL; process.arguments = ["--apply-update", file.path]; try process.run(); helper = process
            let deadline = Date().addingTimeInterval(60)
            while !fm.fileExists(atPath: job.appendingPathComponent("ready").path) { guard process.isRunning, Date() < deadline else { throw UpdateError.failed }; try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation(); NSApplication.shared.terminate(nil)
        } catch {
            try? Data("cancel".utf8).write(to: job.appendingPathComponent("cancel"))
            if helper == nil || helper?.isRunning == false { try? fm.removeItem(at: stage); try? fm.removeItem(at: job) }
            throw error
        }
    }
}
private struct MacUpdateView: View {
    @ObservedObject var updates: MacUpdates
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("pFlow \(MacUpdates.current)").font(.title2.bold())
            Text(updates.message).fixedSize(horizontal: false, vertical: true)
            if updates.working { ProgressView().controlSize(.small) }
            HStack {
                Button(updates.offer == nil ? "Check for updates" : "Install and restart") { updates.start() }.disabled(updates.working)
                if updates.working { Button("Cancel") { updates.cancel() } }
            }
        }.padding(24).frame(width: 352).onDisappear { updates.cancel() }
    }
}
