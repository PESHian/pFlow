import AppKit
import Carbon.HIToolbox
import Testing
@testable import Yap

/// The activation key: which keys can be chosen, how it is saved, what the
/// event tap takes, and how Settings → Shortcut → Press a key learns one.
struct ActivationKeyTests {
    // MARK: Saved

    @Test func nothingSavedIsRightCommand() {
        let scratch = ScratchDefaults("pflow.activation-key")
        #expect(ActivationKey.saved(scratch.defaults) == .rightCommand)
        #expect(ActivationKey.presets.first == .rightCommand)
    }

    @Test func aChosenKeyIsSavedAndReadBack() {
        let scratch = ScratchDefaults("pflow.activation-key")
        for key in ActivationKey.presets + [ActivationKey(keyCode: UInt16(kVK_F8)), ActivationKey(keyCode: 0xB0)] {
            key.save(scratch.defaults)
            #expect(ActivationKey.saved(scratch.defaults) == key, "\(key.name)")
        }
    }

    /// A key that can't be chosen today (Escape, a letter), or something that is not a key code, reads as Right Command.
    @Test func aSavedKeyThatCannotBeChosenIsRightCommand() {
        let scratch = ScratchDefaults("pflow.activation-key")
        for value in [kVK_Escape, kVK_ANSI_A, kVK_Space, kVK_Shift, -1, 70_000, "F8"] as [Any] {
            scratch.defaults.set(value, forKey: ActivationKey.defaultsKey)
            #expect(ActivationKey.saved(scratch.defaults) == .rightCommand, "\(value)")
        }
    }

    // MARK: Which keys

    @Test func thePresetsAndOtherKeysThatDoNotTypeCanBeChosen() {
        let keys = ActivationKey.presets.map(\.keyCode) + [kVK_Control, kVK_F1, kVK_F8, kVK_F12, kVK_F13, kVK_F20, kVK_Help, ActivationKey.menuKey, 0xB0].map(UInt16.init)
        for code in keys {
            #expect(ActivationKey.refusal(for: code) == nil, "\(ActivationKey(keyCode: code).name)")
        }
    }

    @Test func keysThatTypeMoveOrBelongToMacOSAreRefused() {
        let keys = [kVK_Escape, kVK_CapsLock, kVK_Function, kVK_Command, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
                    kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_1, kVK_ANSI_Slash, kVK_Space, kVK_Return, kVK_Tab, kVK_Delete,
                    kVK_ForwardDelete, kVK_LeftArrow, kVK_UpArrow, kVK_Home, kVK_PageDown,
                    kVK_ANSI_Keypad0, kVK_ANSI_Keypad9, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadClear,
                    kVK_VolumeUp, kVK_Mute, kVK_JIS_Eisu, kVK_JIS_Kana, kVK_ISO_Section]
        for code in keys {
            #expect(ActivationKey.refusal(for: UInt16(code)) != nil, "key \(code)")
        }
    }

    @Test func namesArePlain() {
        #expect(ActivationKey.rightCommand.name == "Right ⌘ Command")
        #expect(ActivationKey.rightControl.name == "Right ⌃ Control")
        #expect(ActivationKey.leftControl.name == "Left ⌃ Control")
        #expect(ActivationKey(keyCode: UInt16(kVK_F8)).name == "F8")
        #expect(ActivationKey(keyCode: UInt16(kVK_F19)).name == "F19")
        #expect(ActivationKey(keyCode: 0xB0).name == "🎤 Dictation key")
        #expect(ActivationKey(keyCode: 0x80).name == "Key 128")
        #expect(Set(ActivationKey.presets.map(\.name)).count == ActivationKey.presets.count)
    }

    // MARK: Modifier keys

    /// Each side has its own bit: the other side moving never counts.
    @Test func aModifierKeyReadsOnlyItsOwnSide() {
        let rightControl = ActivationKey.rightControl, leftControl = ActivationKey.leftControl
        #expect(rightControl.transition(keyCode: 62, flags: 0x42000) == true)
        #expect(rightControl.transition(keyCode: 62, flags: 0x40001) == false, "up while Left Control is still held")
        #expect(rightControl.transition(keyCode: 59, flags: 0x42001) == nil)
        #expect(leftControl.transition(keyCode: 59, flags: 0x40001) == true)
        #expect(leftControl.transition(keyCode: 59, flags: 0x42000) == false)
        #expect(ActivationKey(keyCode: UInt16(kVK_F8)).transition(keyCode: Int64(kVK_F8), flags: 0) == nil)
        #expect(ActivationKey.presets.allSatisfy { $0.isModifier })
    }

    // MARK: The tap, for a key that is not a modifier

    private let f8 = ActivationKey(keyCode: UInt16(kVK_F8))

    @Test func theKeyOnItsOwnIsTakenWithItsRepeatsAndUp() {
        var tap = ActivationKeyTap()
        let code = Int64(kVK_F8)
        #expect(tap.handle(keyCode: code, down: true, isRepeat: false, flags: [], key: f8) == (true, .press))
        #expect(tap.handle(keyCode: code, down: true, isRepeat: true, flags: [], key: f8) == (true, nil))
        #expect(tap.handle(keyCode: code, down: false, isRepeat: false, flags: [], key: f8) == (true, .release))
        #expect(!tap.owned)
        // A new press with the last up lost: let go, then pressed again; its own up still taken.
        #expect(tap.handle(keyCode: code, down: true, isRepeat: false, flags: [], key: f8) == (true, .press))
        #expect(tap.handle(keyCode: code, down: true, isRepeat: false, flags: [], key: f8) == (true, .again))
        #expect(tap.handle(keyCode: code, down: false, isRepeat: false, flags: [], key: f8) == (true, .release))
        // fn held is how a laptop types F8: still the key.
        #expect(tap.handle(keyCode: code, down: true, isRepeat: false, flags: .maskSecondaryFn, key: f8) == (true, .press))
    }

    @Test func withAModifierHeldTheKeyIsTheAppsShortcut() {
        for flag in [CGEventFlags.maskCommand, .maskAlternate, .maskControl, .maskShift] {
            var tap = ActivationKeyTap()
            let code = Int64(kVK_F8)
            #expect(tap.handle(keyCode: code, down: true, isRepeat: false, flags: flag, key: f8) == (false, nil))
            // The modifier let go, the key still held: its repeats and its up are the app's too.
            #expect(tap.handle(keyCode: code, down: true, isRepeat: true, flags: [], key: f8) == (false, nil))
            #expect(tap.handle(keyCode: code, down: false, isRepeat: false, flags: [], key: f8) == (false, nil))
        }
    }

    @Test func otherKeysAndModifierKeysAreNeverTaken() {
        var tap = ActivationKeyTap()
        #expect(tap.handle(keyCode: Int64(kVK_F9), down: true, isRepeat: false, flags: [], key: f8) == (false, nil))
        #expect(tap.handle(keyCode: Int64(kVK_ANSI_A), down: true, isRepeat: false, flags: [], key: f8) == (false, nil))
        #expect(tap.handle(keyCode: 62, down: true, isRepeat: false, flags: [], key: .rightControl) == (false, nil))
    }

    /// Paused while a new key is learned: a new press passes through, but a
    /// press already taken keeps its up, so the app never gets an up without a down.
    @Test func pausedPassesNewPressesButKeepsATakenUp() {
        var tap = ActivationKeyTap()
        let code = Int64(kVK_F8)
        #expect(tap.handle(keyCode: code, down: true, isRepeat: false, flags: [], key: f8) == (true, .press))
        tap.paused = true
        #expect(tap.handle(keyCode: code, down: false, isRepeat: false, flags: [], key: f8) == (true, .release))
        #expect(tap.handle(keyCode: code, down: true, isRepeat: false, flags: [], key: f8) == (false, nil))
        #expect(tap.handle(keyCode: code, down: false, isRepeat: false, flags: [], key: f8) == (false, nil))
    }

    // MARK: Held keys

    /// The key the tap takes is not the person acting: holding it doesn't
    /// hold back live words or the paste. Any other key still does.
    @Test func theTakenKeyHeldIsNotSomethingHeld() {
        let f8Code = CGKeyCode(kVK_F8)
        let none: (CGMouseButton) -> Bool = { _ in false }
        #expect(!PersonInput.somethingHeld(ignoring: f8Code, button: none, key: { $0 == f8Code }))
        #expect(PersonInput.somethingHeld(ignoring: nil, button: none, key: { $0 == f8Code }))
        #expect(PersonInput.somethingHeld(ignoring: f8Code, button: none, key: { $0 == f8Code || $0 == CGKeyCode(kVK_ANSI_A) }))
        #expect(PersonInput.somethingHeld(ignoring: f8Code, button: { $0 == .left }, key: { _ in false }))
    }

    // MARK: Learning

    private func flags(_ code: Int, down: Bool) -> UInt64 {
        down ? ActivationKey.deviceBits[UInt16(code)]! : 0
    }

    @Test func aModifierPressedAndLetGoIsLearned() {
        var learner = KeyLearner()
        #expect(learner.flagsChanged(UInt16(kVK_RightControl), flags: 0x42000) == .listening)
        #expect(learner.flagsChanged(UInt16(kVK_RightControl), flags: 0) == .learned(.rightControl))
        #expect(learner.flagsChanged(UInt16(kVK_RightOption), flags: 0x80040) == .listening)
        #expect(learner.flagsChanged(UInt16(kVK_RightOption), flags: 0) == .refused(ActivationKey.refusal(for: UInt16(kVK_RightOption))!))
    }

    @Test func anFKeyIsLearnedOnItsUpAndRepeatsDoNotMatter() {
        var learner = KeyLearner()
        let code = UInt16(kVK_F8)
        #expect(learner.keyDown(code, isRepeat: false, flags: []) == .listening)
        #expect(learner.keyDown(code, isRepeat: true, flags: []) == .listening)
        #expect(learner.keyUp(code) == .learned(ActivationKey(keyCode: code)))
    }

    /// On a laptop keyboard fn is held to type an F key: that is not a chord.
    @Test func fnHeldForAnFKeyLearnsTheFKey() {
        var learner = KeyLearner()
        let code = UInt16(kVK_F8), fn = UInt16(kVK_Function)
        #expect(learner.flagsChanged(fn, flags: KeyLearner.fnBit) == .listening)
        #expect(learner.keyDown(code, isRepeat: false, flags: .maskSecondaryFn) == .listening)
        #expect(learner.keyUp(code) == .learned(ActivationKey(keyCode: code)))
        #expect(learner.flagsChanged(fn, flags: 0) == .listening)
    }

    @Test func fnOnItsOwnIsRefused() {
        var learner = KeyLearner()
        let fn = UInt16(kVK_Function)
        #expect(learner.flagsChanged(fn, flags: KeyLearner.fnBit) == .listening)
        #expect(learner.flagsChanged(fn, flags: 0) == .refused(ActivationKey.refusal(for: fn)!))
    }

    @Test func escapeCancelsAndIsNeverLearned() {
        var learner = KeyLearner()
        #expect(learner.keyDown(UInt16(kVK_Escape), isRepeat: false, flags: []) == .cancelled)
        var holding = KeyLearner()
        _ = holding.keyDown(UInt16(kVK_F8), isRepeat: false, flags: [])
        #expect(holding.keyDown(UInt16(kVK_Escape), isRepeat: false, flags: []) == .cancelled)
    }

    @Test func aKeyThatCannotBeChosenIsRefusedAndListeningGoesOn() {
        var learner = KeyLearner()
        _ = learner.keyDown(UInt16(kVK_ANSI_A), isRepeat: false, flags: [])
        #expect(learner.keyUp(UInt16(kVK_ANSI_A)) == .refused(ActivationKey.refusal(for: UInt16(kVK_ANSI_A))!))
        _ = learner.flagsChanged(UInt16(kVK_Shift), flags: flags(kVK_Shift, down: true))
        #expect(learner.flagsChanged(UInt16(kVK_Shift), flags: 0) == .refused(ActivationKey.refusal(for: UInt16(kVK_Shift))!))
        #expect(learner.flagsChanged(UInt16(kVK_CapsLock), flags: 0x10000) == .refused(ActivationKey.refusal(for: UInt16(kVK_CapsLock))!))
        _ = learner.keyDown(UInt16(kVK_F9), isRepeat: false, flags: [])
        #expect(learner.keyUp(UInt16(kVK_F9)) == .learned(ActivationKey(keyCode: UInt16(kVK_F9))))
    }

    @Test func twoKeysTogetherAreRefused() {
        // Right Option, then F8 while it is down.
        var one = KeyLearner()
        _ = one.flagsChanged(UInt16(kVK_RightOption), flags: 0x80040)
        _ = one.keyDown(UInt16(kVK_F8), isRepeat: false, flags: .maskAlternate)
        #expect(one.keyUp(UInt16(kVK_F8)) == .listening)
        #expect(one.flagsChanged(UInt16(kVK_RightOption), flags: 0) == .refused(KeyLearner.chordNote))
        // F8 with Command already held.
        var two = KeyLearner()
        _ = two.keyDown(UInt16(kVK_F8), isRepeat: false, flags: .maskCommand)
        #expect(two.keyUp(UInt16(kVK_F8)) == .refused(KeyLearner.chordNote))
        // Both Options.
        var three = KeyLearner()
        _ = three.flagsChanged(UInt16(kVK_Option), flags: 0x80020)
        _ = three.flagsChanged(UInt16(kVK_RightOption), flags: 0x80060)
        #expect(three.flagsChanged(UInt16(kVK_RightOption), flags: 0x80020) == .listening)
        #expect(three.flagsChanged(UInt16(kVK_Option), flags: 0) == .refused(KeyLearner.chordNote))
    }

    /// A key already down when listening began is not learned when let go.
    @Test func aKeyHeldFromBeforeIsIgnored() {
        var learner = KeyLearner()
        #expect(learner.flagsChanged(UInt16(kVK_RightOption), flags: 0) == .listening)
        #expect(learner.keyUp(UInt16(kVK_F8)) == .listening)
        #expect(learner.keyDown(UInt16(kVK_F8), isRepeat: true, flags: []) == .listening)
        #expect(learner.keyUp(UInt16(kVK_F8)) == .listening)
    }
}
