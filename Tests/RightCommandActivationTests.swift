import XCTest
@testable import Yap

final class RightCommandActivationTests: XCTestCase {
    func testReleaseRecoveryKeepsRecordingWhileCommandIsHeld() {
        var a = RightCommandActivation()
        XCTAssertEqual(a.press(at: 0), [.start])
        for time in [0.08, 0.3, 1.0, 3.0] {
            XCTAssertEqual(a.recoverRelease(keyIsDown: true, at: time), [])
            XCTAssertEqual(a.state, .recording)
            XCTAssertTrue(a.isDown)
        }
        XCTAssertEqual(a.release(at: 3.1), [.finish])
    }
    func testReleaseRecoveryFinishesWhenAllCommandsAreReleased() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        XCTAssertEqual(a.recoverRelease(keyIsDown: false, at: 2), [.finish])
        XCTAssertFalse(a.isDown)
        XCTAssertEqual(a.recoverRelease(keyIsDown: false, at: 2.1), [])
        XCTAssertEqual(a.release(at: 2.2), [])
    }
    func testRightReleaseFinishesWhenLeftCommandRemainsDown() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        XCTAssertEqual(a.recoverRelease(keyIsDown: true, at: 2), [])
        XCTAssertEqual(a.release(at: 2.1), [.finish])
    }
    func testExternalContinuousStopAllowsNextHold() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        _ = a.release(at: 0.1)
        _ = a.press(at: 0.2)
        _ = a.release(at: 0.3)
        a.reconcileIdle(isBusy: false)
        XCTAssertEqual(a.press(at: 1), [.start])
    }
    func testReconciliationKeepsPhysicalKeyLatch() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        _ = a.interrupt()
        a.reconcileIdle(isBusy: false)
        XCTAssertEqual(a.press(at: 0.1), [])
        _ = a.release(at: 0.2)
        XCTAssertEqual(a.press(at: 1), [.start])
    }
    func testRightCommandPress() {
        XCTAssertEqual(ActivationKey.rightCommand.transition(keyCode: 54, flags: 0x100010), true)
    }
    func testRightReleaseWhileLeftRemainsHeld() {
        XCTAssertEqual(ActivationKey.rightCommand.transition(keyCode: 54, flags: 0x100008), false)
    }
    func testLeftCommandNeverActivates() {
        XCTAssertNil(ActivationKey.rightCommand.transition(keyCode: 55, flags: 0x100008))
        XCTAssertNil(ActivationKey.rightCommand.transition(keyCode: 55, flags: 0x100018))
    }
    func testRightWithBothCommandsHeld() {
        XCTAssertEqual(ActivationKey.rightCommand.transition(keyCode: 54, flags: 0x100018), true)
    }
    func testHoldRelease() {
        var a = RightCommandActivation()
        XCTAssertEqual(a.press(at: 0), [.start])
        XCTAssertEqual(a.state, .recording)
        XCTAssertEqual(a.release(at: 2), [.finish])
        XCTAssertEqual(a.state, .processing)
        a.beginInsertion()
        XCTAssertEqual(a.state, .inserting)
        a.complete()
        XCTAssertEqual(a.state, .idle)
    }
    func testDoubleTapAndStop() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        XCTAssertEqual(a.release(at: 0.1), [.pause])
        XCTAssertEqual(a.press(at: 0.25), [.resume])
        XCTAssertEqual(a.state, .continuous)
        XCTAssertEqual(a.release(at: 0.3), [])
        XCTAssertEqual(a.expireTap(at: 1), [])
        XCTAssertEqual(a.press(at: 2), [.finish])
        XCTAssertEqual(a.release(at: 2.1), [])
    }
    func testTwoDeliberateTapsEnterContinuousMode() {
        var a = RightCommandActivation()
        XCTAssertEqual(a.press(at: 1), [.start])
        XCTAssertEqual(a.release(at: 1.25), [.pause])
        XCTAssertEqual(a.press(at: 1.50), [.resume])
        XCTAssertEqual(a.release(at: 1.75), [])
        XCTAssertEqual(a.state, .continuous)
    }
    func testSingleTapCommitsOnce() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        _ = a.release(at: 0.05)
        XCTAssertEqual(a.expireTap(at: 0.2), [])
        XCTAssertEqual(a.expireTap(at: 0.36), [.finish])
        XCTAssertEqual(a.expireTap(at: 0.9), [])
    }
    func testRepeatedPressAndReleaseDoNotDuplicate() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        XCTAssertEqual(a.press(at: 0.1), [])
        _ = a.release(at: 1)
        XCTAssertEqual(a.release(at: 1.1), [])
        XCTAssertEqual(a.press(at: 1.2), [])
        XCTAssertEqual(a.state, .processing)
    }
    func testShortcutCancelsAndCannotRestartBeforeRelease() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        XCTAssertEqual(a.interrupt(), [.cancel])
        XCTAssertEqual(a.press(at: 0.1), [])
        XCTAssertEqual(a.release(at: 0.2), [])
        XCTAssertEqual(a.press(at: 1), [.start])
    }
    func testLongHoldCannotBecomeDoubleTap() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        XCTAssertEqual(a.release(at: 2), [.finish])
        XCTAssertEqual(a.press(at: 2.1), [])
        XCTAssertEqual(a.state, .processing)
    }
    func testLostReleaseReset() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        a.reset()
        XCTAssertFalse(a.isDown)
        XCTAssertEqual(a.state, .idle)
        XCTAssertEqual(a.press(at: 2), [.start])
    }
    func testStaleDoubleTapCannotResume() {
        var a = RightCommandActivation()
        _ = a.press(at: 0)
        _ = a.release(at: 0.1)
        XCTAssertEqual(a.press(at: 0.5), [])
        XCTAssertEqual(a.expireTap(at: 0.5), [.finish])
    }
}
