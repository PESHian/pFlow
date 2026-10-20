import AppKit
import XCTest
@testable import Yap

@MainActor
final class ModifierHotkeyMonitorTests: XCTestCase {
    private func event(_ down: Bool, at time: TimeInterval, key: UInt16 = 54) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0x100010 : 0),
            timestamp: time, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
    }

    func testDelayedDeliveryStillUsesPhysicalDoubleTapTimes() throws {
        let monitor = ModifierHotkeyMonitor()
        defer { monitor.stop() }
        var effects: [RightCommandActivation.Effect] = []
        monitor.recordingIsBusy = { !effects.isEmpty }
        monitor.onRightCommand = { effects.append($0) }
        let start = ProcessInfo.processInfo.systemUptime
        monitor.rightCommand(try event(true, at: start))
        // Audio startup stalls the UI while the user releases and taps again.
        Thread.sleep(forTimeInterval: 0.35)
        monitor.rightCommand(try event(false, at: start + 0.10))
        monitor.rightCommand(try event(true, at: start + 0.25))
        monitor.rightCommand(try event(false, at: start + 0.30))
        XCTAssertEqual(effects, [.start, .pause, .resume])
        monitor.rightCommand(try event(true, at: start + 1))
        monitor.rightCommand(try event(false, at: start + 1.10))
        XCTAssertEqual(effects, [.start, .pause, .resume, .finish])
    }

    func testQueuedLongHoldIsNotMistakenForDoubleTap() throws {
        let monitor = ModifierHotkeyMonitor()
        defer { monitor.stop() }
        var effects: [RightCommandActivation.Effect] = []
        monitor.recordingIsBusy = { !effects.isEmpty }
        monitor.onRightCommand = { effects.append($0) }
        let start = ProcessInfo.processInfo.systemUptime - 2
        // These arrive together after a busy main thread, but the key was held.
        monitor.rightCommand(try event(true, at: start))
        monitor.rightCommand(try event(false, at: start + 1))
        monitor.rightCommand(try event(true, at: start + 1.1))
        monitor.rightCommand(try event(false, at: start + 1.2))
        XCTAssertEqual(effects, [.start, .finish])
    }

    func testLeftCommandDoesNotRecord() throws {
        let monitor = ModifierHotkeyMonitor()
        defer { monitor.stop() }
        var effects: [RightCommandActivation.Effect] = []
        monitor.onRightCommand = { effects.append($0) }
        monitor.rightCommand(try event(true, at: 1, key: 55))
        monitor.rightCommand(try event(false, at: 1.1, key: 55))
        monitor.rightCommand(try event(true, at: 1.2, key: 55))
        monitor.rightCommand(try event(false, at: 1.3, key: 55))
        XCTAssertTrue(effects.isEmpty)
    }
}
