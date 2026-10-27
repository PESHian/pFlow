import AppKit
import XCTest
@testable import Yap

@MainActor
final class ActivationKeyMonitorTests: XCTestCase {
    private func event(_ down: Bool, at time: TimeInterval, key: UInt16 = 54, flags: UInt = 0x100010) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? flags : 0),
            timestamp: time, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
    }

    func testDelayedDeliveryStillUsesPhysicalDoubleTapTimes() throws {
        let monitor = ActivationKeyMonitor()
        defer { monitor.stop() }
        var effects: [RightCommandActivation.Effect] = []
        monitor.recordingIsBusy = { !effects.isEmpty }
        monitor.onActivation = { effects.append($0) }
        let start = ProcessInfo.processInfo.systemUptime
        monitor.modifierChanged(try event(true, at: start))
        // Audio startup stalls the UI while the user releases and taps again.
        Thread.sleep(forTimeInterval: 0.35)
        monitor.modifierChanged(try event(false, at: start + 0.10))
        monitor.modifierChanged(try event(true, at: start + 0.25))
        monitor.modifierChanged(try event(false, at: start + 0.30))
        XCTAssertEqual(effects, [.start, .pause, .resume])
        monitor.modifierChanged(try event(true, at: start + 1))
        monitor.modifierChanged(try event(false, at: start + 1.10))
        XCTAssertEqual(effects, [.start, .pause, .resume, .finish])
    }

    func testQueuedLongHoldIsNotMistakenForDoubleTap() throws {
        let monitor = ActivationKeyMonitor()
        defer { monitor.stop() }
        var effects: [RightCommandActivation.Effect] = []
        monitor.recordingIsBusy = { !effects.isEmpty }
        monitor.onActivation = { effects.append($0) }
        let start = ProcessInfo.processInfo.systemUptime - 2
        // These arrive together after a busy main thread, but the key was held.
        monitor.modifierChanged(try event(true, at: start))
        monitor.modifierChanged(try event(false, at: start + 1))
        monitor.modifierChanged(try event(true, at: start + 1.1))
        monitor.modifierChanged(try event(false, at: start + 1.2))
        XCTAssertEqual(effects, [.start, .finish])
    }

    func testLeftCommandDoesNotRecord() throws {
        let monitor = ActivationKeyMonitor()
        defer { monitor.stop() }
        var effects: [RightCommandActivation.Effect] = []
        monitor.onActivation = { effects.append($0) }
        monitor.modifierChanged(try event(true, at: 1, key: 55))
        monitor.modifierChanged(try event(false, at: 1.1, key: 55))
        monitor.modifierChanged(try event(true, at: 1.2, key: 55))
        monitor.modifierChanged(try event(false, at: 1.3, key: 55))
        XCTAssertTrue(effects.isEmpty)
    }

    /// Right Control as the key: its own side's bit, the same hold and double-tap.
    func testRightControlHoldsAndDoubleTaps() throws {
        let monitor = ActivationKeyMonitor()
        defer { monitor.stop() }
        monitor.key = .rightControl
        var effects: [RightCommandActivation.Effect] = []
        monitor.recordingIsBusy = { false }
        monitor.onActivation = { effects.append($0) }
        let start = ProcessInfo.processInfo.systemUptime
        // Right Command and Left Control do nothing now.
        monitor.modifierChanged(try event(true, at: start, key: 54))
        monitor.modifierChanged(try event(false, at: start + 0.1, key: 54))
        monitor.modifierChanged(try event(true, at: start + 0.2, key: 59, flags: 0x40001))
        monitor.modifierChanged(try event(false, at: start + 0.3, key: 59))
        XCTAssertEqual(effects, [])
        monitor.modifierChanged(try event(true, at: start + 1, key: 62, flags: 0x42000))
        monitor.modifierChanged(try event(false, at: start + 2, key: 62))
        XCTAssertEqual(effects, [.start, .finish])
        effects.removeAll()
        monitor.recordingIsBusy = { !effects.isEmpty && effects.last != .finish }
        monitor.modifierChanged(try event(true, at: start + 5, key: 62, flags: 0x42000))
        monitor.modifierChanged(try event(false, at: start + 5.1, key: 62))
        monitor.modifierChanged(try event(true, at: start + 5.2, key: 62, flags: 0x42000))
        monitor.modifierChanged(try event(false, at: start + 5.3, key: 62))
        XCTAssertEqual(effects, [.start, .pause, .resume])
    }

    private func key(_ code: CGKeyCode, down: Bool, repeating: Bool = false, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return event
    }

    private func drain() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// F8 as the key: taken on its own (so the app never sees it, nor its
    /// repeats), held to dictate; with Command held it is the app's shortcut.
    func testAnFKeyIsTakenAndHeldToDictate() throws {
        let monitor = ActivationKeyMonitor()
        defer { monitor.stop() }
        monitor.key = ActivationKey(keyCode: 0x64)
        var effects: [RightCommandActivation.Effect] = []
        monitor.onActivation = { effects.append($0) }
        XCTAssertTrue(monitor.keyEvent(try key(0x64, down: true), down: true))
        XCTAssertTrue(monitor.keyEvent(try key(0x64, down: true, repeating: true), down: true))
        XCTAssertFalse(monitor.keyEvent(try key(0x65, down: true), down: true), "another key is never taken")
        Thread.sleep(forTimeInterval: 0.7)
        XCTAssertTrue(monitor.keyEvent(try key(0x64, down: false), down: false))
        drain()
        XCTAssertEqual(effects, [.start, .finish])
        effects.removeAll()
        XCTAssertFalse(monitor.keyEvent(try key(0x64, down: true, flags: .maskCommand), down: true), "⌘F8 is the app's")
        XCTAssertFalse(monitor.keyEvent(try key(0x64, down: true, repeating: true), down: true), "its repeats too")
        XCTAssertFalse(monitor.keyEvent(try key(0x64, down: false), down: false), "and its up")
        drain()
        XCTAssertEqual(effects, [])
    }

    /// The tap takes the key before the system records it, so its key state
    /// reads up while it is held: the hold lasts until its own up, never cut at 80 ms.
    func testAnFKeyHoldIsNotCutShortByItsKeyState() throws {
        let monitor = ActivationKeyMonitor()
        defer { monitor.stop() }
        monitor.key = ActivationKey(keyCode: 0x64)
        var effects: [RightCommandActivation.Effect] = []
        monitor.onActivation = { effects.append($0) }
        XCTAssertTrue(monitor.keyEvent(try key(0x64, down: true), down: true))
        let held = expectation(description: "still held")
        held.isInverted = true
        wait(for: [held], timeout: 0.6)
        XCTAssertEqual(effects, [.start])
        XCTAssertTrue(monitor.keyEvent(try key(0x64, down: false), down: false))
        drain()
        XCTAssertEqual(effects, [.start, .finish])
    }

    /// pFlow's own keys (the paste, live words) are never the person's: not taken, no effect.
    func testPFlowsOwnKeysAreIgnored() throws {
        let posted = try key(0x64, down: true)
        XCTAssertFalse(ActivationKeyMonitor.isPFlows(posted))
        posted.setIntegerValueField(.eventSourceUserData, value: SyntheticKeys.marker)
        XCTAssertTrue(ActivationKeyMonitor.isPFlows(posted))
        let monitor = ActivationKeyMonitor()
        defer { monitor.stop() }
        monitor.key = ActivationKey(keyCode: 0x64)
        var effects: [RightCommandActivation.Effect] = []
        monitor.onActivation = { effects.append($0) }
        XCTAssertFalse(monitor.keyEvent(posted, down: true))
        drain()
        XCTAssertEqual(effects, [])
    }

    /// The system turned the tap off while the key was held: its up may have
    /// gone to the app, so the press counts as let go, and the next is a new press.
    func testATapTurnedOffLetsGoOfATakenPress() throws {
        final class Box: @unchecked Sendable { var effects: [ActivationKeyTap.Effect] = [] }
        let box = Box()
        let tap = KeyTap(key: ActivationKey(keyCode: 0x64)) { effect, _ in box.effects.append(effect) }
        XCTAssertTrue(tap.decide(try key(0x64, down: true), down: true))
        _ = tap.handle(.tapDisabledByTimeout, try key(0x64, down: true))
        XCTAssertTrue(tap.decide(try key(0x64, down: true), down: true))
        XCTAssertEqual(box.effects, [.press, .release, .press])
    }

    /// While a new key is being learned the key passes through and starts nothing.
    func testPausedKeyStartsNothing() throws {
        let monitor = ActivationKeyMonitor()
        defer { monitor.stop() }
        monitor.key = ActivationKey(keyCode: 0x64)
        var effects: [RightCommandActivation.Effect] = []
        monitor.onActivation = { effects.append($0) }
        monitor.paused = true
        XCTAssertFalse(monitor.keyEvent(try key(0x64, down: true), down: true))
        XCTAssertFalse(monitor.keyEvent(try key(0x64, down: false), down: false))
        monitor.key = .rightControl
        monitor.modifierChanged(try event(true, at: 1, key: 62, flags: 0x42000))
        monitor.modifierChanged(try event(false, at: 2, key: 62))
        drain()
        XCTAssertEqual(effects, [])
    }
}
