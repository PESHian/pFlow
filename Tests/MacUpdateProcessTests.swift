import Foundation
import AppKit
import Testing
@testable import Yap

struct MacUpdateProcessTests {
    @Test func controlledProcessHandoffAndCancellation() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("pflow-update-process-fictional-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let code = #"""
        import AppKit
        @main enum Fixture {
            @MainActor static func main() {
                let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
                let path = Bundle.main.object(forInfoDictionaryKey: "PFLOWFixtureRoot") as! String
                let root = URL(fileURLWithPath: path)
                try! String(getpid()).write(to: root.appendingPathComponent("started-" + version), atomically: true, encoding: .utf8)
                _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                    let stop = root.appendingPathComponent("stop-" + version)
                    if FileManager.default.fileExists(atPath: stop.path) {
                        try? FileManager.default.removeItem(at: stop)
                        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                    }
                }
                app.run()
            }
        }
        """#
        let swift = root.appendingPathComponent("fixture.swift"), executable = root.appendingPathComponent("fixture")
        try code.write(to: swift, atomically: true, encoding: .utf8)
        try MacUpdateInstaller.run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-parse-as-library", swift.path, "-o", executable.path])
        func bundle(_ path: URL, version: String, control: URL) throws {
            let macos = path.appendingPathComponent("Contents/MacOS")
            try fm.createDirectory(at: macos, withIntermediateDirectories: true)
            try fm.copyItem(at: executable, to: macos.appendingPathComponent("Yap"))
            let info: [String: Any] = ["CFBundleIdentifier":"com.pesh.Yap", "CFBundleExecutable":"Yap", "CFBundleName":"pFlow fictional update fixture", "CFBundlePackageType":"APPL", "CFBundleShortVersionString":version, "CFBundleVersion":"1", "LSUIElement":true, "PFLOWFixtureRoot":control.path]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path.appendingPathComponent("Contents/Info.plist"))
            try MacUpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", path.path])
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(predicate())
            if !predicate() { throw UpdateError.failed }
        }
        for scenario in ["success", "cancel", "corrupt"] {
            let directory = root.appendingPathComponent(scenario), destination = directory.appendingPathComponent("installed.app")
            let job = directory.appendingPathComponent("job"), stage = directory.appendingPathComponent(".pflow-update-\(UUID().uuidString)")
            try fm.createDirectory(at: job, withIntermediateDirectories: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            let source = stage.appendingPathComponent("pFlow.app")
            try bundle(destination, version: "0.3.4", control: directory); try bundle(source, version: "0.3.5", control: directory)
            let history = directory.appendingPathComponent("fictional-history.txt")
            try Data("Private fictional history.".utf8).write(to: history)
            if scenario == "corrupt" { let handle = try FileHandle(forWritingTo: source.appendingPathComponent("Contents/MacOS/Yap")); try handle.seek(toOffset: 1024); try handle.write(contentsOf: Data([0,1,2,3])); try handle.close() }
            try MacUpdateInstaller.run("/usr/bin/open", ["-n", destination.path])
            let started = directory.appendingPathComponent("started-0.3.4")
            try await wait { fm.fileExists(atPath: started.path) }
            let pid = try #require(Int32(String(contentsOf: started, encoding: .utf8)))
            let original = try #require(NSRunningApplication(processIdentifier: pid))
            let date = try #require(original.launchDate)
            let plan = MacUpdatePlan(source: source, destination: destination.resolvingSymlinksInPath(), version: "0.3.5", pid: pid, started: date.timeIntervalSince1970)
            let file = job.appendingPathComponent("plan.json"); try JSONEncoder().encode(plan).write(to: file)
            let helper = Process(); helper.executableURL = Bundle.main.executableURL; helper.arguments = ["--apply-update",file.path]
            helper.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("XCInject") && !$0.key.hasPrefix("DYLD_") }
            helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run()
            do {
                if scenario != "corrupt" {
                    try await wait { fm.fileExists(atPath: job.appendingPathComponent("ready").path) }
                    #expect(kill(pid, 0) == 0)
                    if scenario == "cancel" { try Data("cancel".utf8).write(to: job.appendingPathComponent("cancel")) }
                    else { try Data("stop".utf8).write(to: directory.appendingPathComponent("stop-0.3.4")) }
                }
                try await wait { !helper.isRunning }
                if scenario == "success" {
                    #expect(helper.terminationStatus == 0)
                    try await wait { fm.fileExists(atPath: directory.appendingPathComponent("started-0.3.5").path) }
                    #expect(Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.3.5")
                    #expect(try fm.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix("pFlow.previous-") }))
                } else {
                    #expect(helper.terminationStatus != 0)
                    #expect(kill(pid,0) == 0)
                    #expect(Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.3.4")
                }
                #expect(try String(contentsOf: history, encoding: .utf8) == "Private fictional history.")
            } catch {
                try? Data("cancel".utf8).write(to: job.appendingPathComponent("cancel"))
                for v in ["0.3.4","0.3.5"] { try? Data("stop".utf8).write(to: directory.appendingPathComponent("stop-"+v)) }
                throw error
            }
            for v in ["0.3.4","0.3.5"] { try Data("stop".utf8).write(to: directory.appendingPathComponent("stop-"+v)) }
            for v in ["0.3.4","0.3.5"] {
                let signal = directory.appendingPathComponent("started-"+v)
                if fm.fileExists(atPath: signal.path), let child = Int32(try String(contentsOf: signal, encoding: .utf8)) { try await wait { kill(child,0) != 0 } }
            }
        }
    }
}
