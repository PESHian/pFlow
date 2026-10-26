import Foundation
import Testing
@testable import Yap

/// The real update client (its own URLSession and delegate) against a stubbed
/// URLProtocol: redirects off GitHub or to http are refused, the size cap
/// stops a download with a plain problem, a non-2xx answer keeps nothing, and
/// nothing is left behind on cancel or error. Fictional bytes only.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitHubClientTests {
    /// What the stub does for a URL path.
    enum Behaviour {
        case body(status: Int, data: Data, chunks: Int)
        case redirect(to: URL)
        /// Answers 200 and some bytes, then never finishes.
        case hang(Data)
        /// Answers 200 and some bytes, then fails.
        case fail(Data, URLError)
    }

    final class Stub: URLProtocol {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var routes: [String: Behaviour] = [:]
        nonisolated(unsafe) private static var requested: [URL] = []

        static func route(_ path: String, _ behaviour: Behaviour) { lock.withLock { routes[path] = behaviour } }
        static func wasRequested(host: String) -> Bool { lock.withLock { requested.contains { $0.host == host } } }
        static func wasRequested(_ url: URL) -> Bool { lock.withLock { requested.contains(url) } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        private var stopped = false

        override func startLoading() {
            guard let url = request.url else { return }
            let behaviour = Self.lock.withLock { () -> Behaviour? in
                Self.requested.append(url)
                return Self.routes[url.path]
            }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            switch behaviour {
            case .body(let status, let data, let chunks)?:
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                                     headerFields: ["Content-Length": "\(data.count)"])!,
                                    cacheStoragePolicy: .notAllowed)
                let size = max(1, data.count / max(chunks, 1))
                var offset = 0
                while offset < data.count, !stopped {
                    let end = min(data.count, offset + size)
                    client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                    offset = end
                    if chunks > 1 { Thread.sleep(forTimeInterval: 0.02) }
                }
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let target)?:
                let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case .hang(let data)?:
                client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
            case .fail(let data, let error)?:
                client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocol(self, didFailWithError: error)
            case nil:
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            }
        }

        override func stopLoading() { stopped = true }
    }

    private func paths() -> (url: URL, path: String) {
        let tag = "fictional-\(UUID().uuidString.prefix(8))"
        let url = URL(string: "https://github.com/PESHian/pFlow/releases/download/\(tag)/pFlow-Mac-0.3.17.dmg")!
        return (url, url.path)
    }

    private func client(cap: Int64 = 536_870_912) throws -> (GitHubClient, URL) {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-client-fictional-\(UUID().uuidString)")
        return (GitHubClient(cap: cap, workFolder: work, protocols: [Stub.self]), work)
    }

    private func leftovers(_ work: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
    }

    @Test func aWholeDownloadIsKeptForChecking() async throws {
        let (client, work) = try client()
        let (url, path) = paths()
        let payload = Data(repeating: 7, count: 3000)
        Stub.route(path, .body(status: 200, data: payload, chunks: 3))
        let file = try await client.download(url) { _, _ in }
        #expect(try Data(contentsOf: file) == payload)
        #expect(file.deletingLastPathComponent().standardizedFileURL == work.standardizedFileURL)
    }

    @Test func aRedirectOffGitHubIsRefused() async throws {
        let (client, work) = try client()
        let (url, path) = paths()
        let elsewhere = URL(string: "https://downloads.example.net/fictional/pFlow-Mac-0.3.17.dmg")!
        Stub.route(path, .redirect(to: elsewhere))
        Stub.route(elsewhere.path, .body(status: 200, data: Data(repeating: 1, count: 100), chunks: 1))
        await #expect(throws: (any Error).self) { try await client.download(url) { _, _ in } }
        #expect(!Stub.wasRequested(host: "downloads.example.net"), "never fetched from the other host")
        #expect(leftovers(work).isEmpty)
    }

    @Test func aRedirectToPlainHTTPIsRefused() async throws {
        let (client, work) = try client()
        let (url, path) = paths()
        let plain = URL(string: "http://release-assets.githubusercontent.com/fictional-\(UUID().uuidString.prefix(6))/pFlow-Mac-0.3.17.dmg")!
        Stub.route(path, .redirect(to: plain))
        Stub.route(plain.path, .body(status: 200, data: Data(repeating: 1, count: 100), chunks: 1))
        await #expect(throws: (any Error).self) { try await client.download(url) { _, _ in } }
        #expect(!Stub.wasRequested(plain), "never fetched over http")
        #expect(leftovers(work).isEmpty)
    }

    @Test func theSizeCapStopsTheDownloadWithAPlainProblem() async throws {
        let (client, work) = try client(cap: 1000)
        let (url, path) = paths()
        Stub.route(path, .body(status: 200, data: Data(repeating: 2, count: 8000), chunks: 8))
        await #expect(throws: GitHubReleases.Problem.tooLarge) { try await client.download(url) { _, _ in } }
        #expect(leftovers(work).isEmpty)
    }

    @Test func aNon2xxAnswerKeepsNothing() async throws {
        let (client, work) = try client()
        let (url, path) = paths()
        Stub.route(path, .body(status: 500, data: Data("fictional error page".utf8), chunks: 1))
        await #expect(throws: (any Error).self) { try await client.download(url) { _, _ in } }
        #expect(leftovers(work).isEmpty)
        let (other, otherPath) = paths()
        Stub.route(otherPath, .body(status: 429, data: Data(), chunks: 1))
        await #expect(throws: GitHubReleases.Problem.rateLimited) { try await client.download(other) { _, _ in } }
    }

    @Test func aFailureMidwayLeavesNothing() async throws {
        let (client, work) = try client()
        let (url, path) = paths()
        Stub.route(path, .fail(Data(repeating: 3, count: 500), URLError(.networkConnectionLost)))
        let error = await #expect(throws: URLError.self) { try await client.download(url) { _, _ in } }
        #expect(error?.code == .networkConnectionLost, "the transfer's own error is passed on")
        #expect(leftovers(work).isEmpty)
    }

    @Test func cancellingMidwayLeavesNothing() async throws {
        let (client, work) = try client()
        let (url, path) = paths()
        Stub.route(path, .hang(Data(repeating: 4, count: 500)))
        let started = Task { try await client.download(url) { _, _ in } }
        try await Task.sleep(for: .milliseconds(300))
        started.cancel()
        let error = await #expect(throws: URLError.self) { try await started.value }
        #expect(error?.code == .cancelled, "the window treats this as a cancel, not a problem")
        #expect(leftovers(work).isEmpty)
    }

    /// Through the window's logic with the real client: a download that fails its check is
    /// deleted from the work folder too, and so is one cancelled while being checked.
    @Test func checkedDownloadsLeaveNothingBehindOnMismatchOrCancel() async throws {
        let (client, work) = try client()
        let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("pflow-dl-fictional-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let updates = GitHubUpdates(network: GitHubUpdateNetwork(client: client))
        updates.downloads = { downloads }
        var opened: [URL] = []
        updates.open = { opened.append($0) }

        let (url, path) = paths()
        Stub.route(path, .body(status: 200, data: Data(repeating: 5, count: 2000), chunks: 2))
        let wrong = GitHubRelease(version: "0.3.17", page: GitHubReleases.releasesPage, dmg: url, bytes: 2000,
                                  sha256: String(repeating: "0", count: 64), checksumFile: nil)
        updates.download(wrong)
        for _ in 0..<300 { if case .failed = updates.state { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(updates.state == .failed(.mismatch, retry: wrong))
        #expect(leftovers(work).isEmpty && opened.isEmpty)

        let (url2, path2) = paths()
        let payload = Data(repeating: 6, count: 2000)
        Stub.route(path2, .body(status: 200, data: payload, chunks: 2))
        let checksum = URL(string: url2.absoluteString + ".sha256")!
        Stub.route(checksum.path, .hang(Data()))
        let right = GitHubRelease(version: "0.3.17", page: GitHubReleases.releasesPage, dmg: url2, bytes: 2000,
                                  sha256: SHA256Hex.of(payload), checksumFile: checksum)
        updates.download(right)
        for _ in 0..<300 { if case .verifying = updates.state { break }; try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        updates.cancel()
        for _ in 0..<300 { if case .newer = updates.state { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(updates.state == .newer(right))
        #expect(leftovers(work).isEmpty, "the downloaded file is removed when the check is cancelled")
        #expect(opened.isEmpty)
    }
}
