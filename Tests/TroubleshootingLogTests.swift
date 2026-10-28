import Foundation
import Testing
@testable import Yap

/// Settings → Troubleshooting log: nothing kept while off, every line from
/// both programs while on, oldest first, and gone when turned off.
@Suite(.serialized)
struct TroubleshootingLogTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pflow-log-test-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func offKeepsNothingAndOnKeepsTheLine() throws {
        let folder = scratch()
        defer { TroubleshootingLog.testing = nil; try? FileManager.default.removeItem(at: folder) }
        TroubleshootingLog.testing = (false, folder)
        ReasonLog.note("troubleshooting test: a line while the log is off")
        TroubleshootingLog.testing = (true, folder)
        ReasonLog.note("troubleshooting test: a line while the log is on")
        let lines = TroubleshootingLog.lines(in: folder)
        #expect(lines.contains { $0.hasSuffix("pFlow  troubleshooting test: a line while the log is on") })
        #expect(!lines.contains { $0.contains("a line while the log is off") })
    }

    @Test func bothProgramsLinesComeOutOldestFirst() {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        TroubleshootingLog.append("input source switched for the take", by: .app, now: start, in: folder)
        TroubleshootingLog.append("bound to a client activated for this take", by: .inputMethod, now: start + 0.2, in: folder)
        TroubleshootingLog.append("insertion result: pasted", by: .app, now: start + 1, in: folder)
        let lines = TroubleshootingLog.lines(in: folder)
        #expect(lines.map { $0.dropFirst(25) } == ["pFlow  input source switched for the take",
                                                   "pFlow Dictation  bound to a client activated for this take",
                                                   "pFlow  insertion result: pasted"])
    }

    /// A full file becomes the one older file; both are still saved.
    @Test func aFullFileRollsOverAndBothAreKept() throws {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        TroubleshootingLog.append(String(repeating: "x", count: TroubleshootingLog.maxBytes), by: .app, now: start, in: folder)
        TroubleshootingLog.append("insertion result: pasted", by: .app, now: start + 1, in: folder)
        TroubleshootingLog.flush()
        #expect(FileManager.default.fileExists(atPath: TroubleshootingLog.older(.app, in: folder).path))
        let lines = TroubleshootingLog.lines(in: folder)
        #expect(lines.count == 2)
        #expect(lines.last?.hasSuffix("insertion result: pasted") == true)
        let size = try FileManager.default.attributesOfItem(atPath: TroubleshootingLog.current(.app, in: folder).path)[.size] as? Int
        #expect((size ?? .max) < 100)
    }

    @Test func turningItOffDeletesTheLog() {
        let folder = scratch()
        TroubleshootingLog.append("insertion result: pasted", by: .inputMethod, in: folder)
        TroubleshootingLog.clear(in: folder)
        TroubleshootingLog.flush()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(TroubleshootingLog.lines(in: folder).isEmpty)
    }

    @Test func theSavedFileSaysWhatItIs() {
        let text = TroubleshootingLog.report(lines: ["2027-01-15 08:00:00.000  pFlow  insertion result: pasted"],
                                             version: "0.3.19 (48)", system: "27.0.0", saved: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(text.hasPrefix("pFlow troubleshooting log\npFlow 0.3.19 (48) · macOS 27.0.0 · saved "))
        #expect(text.contains("never your words"))
        #expect(text.hasSuffix("pFlow  insertion result: pasted\n"))
        #expect(TroubleshootingLog.report(lines: [], version: "0.3.19 (48)", system: "27.0.0").hasSuffix("(no lines yet)\n"))
    }
}
