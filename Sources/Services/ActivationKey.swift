import AppKit
import Carbon.HIToolbox

/// The key the person holds to dictate (double-tap for continuous recording).
/// Right Command unless they chose another in Settings → Shortcut, from the
/// list or by pressing it. Saved as its virtual key code.
struct ActivationKey: Hashable, Identifiable {
    let keyCode: UInt16

    var id: UInt16 { keyCode }

    static let rightCommand = ActivationKey(keyCode: UInt16(kVK_RightCommand))
    static let rightControl = ActivationKey(keyCode: UInt16(kVK_RightControl))
    static let leftControl = ActivationKey(keyCode: UInt16(kVK_Control))

    /// The list in Settings. A learned key is added to it while chosen. Left
    /// Control can be learned, but it is in shortcuts all the time: each one
    /// would start a take and cancel it.
    static let presets: [ActivationKey] = [.rightCommand, .rightControl]

    static let defaultsKey = "activationKey"

    /// The saved key; Right Command when nothing is saved, or what is saved
    /// could not be chosen today.
    static func saved(_ defaults: UserDefaults = .standard) -> ActivationKey {
        guard let code = defaults.object(forKey: defaultsKey) as? Int, (0...Int(UInt16.max)).contains(code) else { return .rightCommand }
        let key = ActivationKey(keyCode: UInt16(code))
        return refusal(for: key.keyCode) == nil ? key : .rightCommand
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: Self.defaultsKey)
    }

    // MARK: Modifier keys

    /// `NX_DEVICE…KEYMASK`: which side of a modifier is down, in a
    /// flagsChanged event's flags. Every modifier with a side, chosen or not.
    static let deviceBits: [UInt16: UInt64] = [
        UInt16(kVK_Control): 0x0001, UInt16(kVK_Shift): 0x0002, UInt16(kVK_RightShift): 0x0004,
        UInt16(kVK_Command): 0x0008, UInt16(kVK_RightCommand): 0x0010,
        UInt16(kVK_Option): 0x0020, UInt16(kVK_RightOption): 0x0040, UInt16(kVK_RightControl): 0x2000,
    ]

    /// A modifier (seen through flagsChanged); any other key comes as key down and up.
    var isModifier: Bool { Self.deviceBits[keyCode] != nil }

    /// Command, Option or Control on either side, for reading the held flags.
    var flag: CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand: return .maskCommand
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_Shift, kVK_RightShift: return .maskShift
        default: return nil
        }
    }

    /// For a flagsChanged event: true when this key went down, false when it
    /// went up, nil when the event is another key's. The other side of the
    /// same modifier never counts.
    func transition(keyCode: Int64, flags: UInt64) -> Bool? {
        guard keyCode == Int64(self.keyCode), let bit = Self.deviceBits[self.keyCode] else { return nil }
        return flags & bit != 0
    }

    // MARK: Names

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]

    /// The PC keyboard's Menu key (kVK_ContextualMenu, not in older SDKs).
    static let menuKey = 0x6E

    var name: String {
        switch Int(keyCode) {
        case kVK_RightCommand: return "Right ⌘ Command"
        case kVK_Control: return "Left ⌃ Control"
        case kVK_RightControl: return "Right ⌃ Control"
        case kVK_Help: return "Help"
        case Self.menuKey: return "Menu"
        case 0xB0: return "🎤 Dictation key"
        case let code where Self.functionKeys[code] != nil: return "F\(Self.functionKeys[code]!)"
        default: return "Key \(keyCode)"
        }
    }

    // MARK: Which keys can be chosen

    /// Why `keyCode` can't be the activation key, said plainly; nil when it can.
    /// Escape is not here: it stops a recording, and while a key is being
    /// learned it cancels, so it is never learned.
    static func refusal(for keyCode: UInt16) -> String? {
        let code = Int(keyCode)
        switch code {
        case kVK_Escape:
            return "Escape stops a recording, so it can't start one. Press another key."
        case kVK_CapsLock:
            return "Caps Lock turns capitals on and off. Press another key."
        case kVK_Function:
            return "macOS uses the fn key itself. Press another key."
        case kVK_Command, kVK_Shift, kVK_RightShift:
            return "That key is used for shortcuts and capitals all the time. Press another key."
        case kVK_Option, kVK_RightOption:
            // Each press starts a recording and the next key cancels it, which
            // loses an accent typed with Option (⌥E then E gave "e", VM).
            return "Option types accents and symbols, like é. Press another key."
        case kVK_VolumeUp, kVK_VolumeDown, kVK_Mute:
            return "That key controls the sound. Press another key."
        case kVK_JIS_Eisu, kVK_JIS_Kana:
            return "That key switches the typing language. Press another key."
        case kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            return "That key moves around or deletes text. Press another key."
        case 0...0x34, kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear,
             kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
             kVK_ANSI_Keypad0...kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
             kVK_JIS_Yen, kVK_JIS_Underscore, kVK_JIS_KeypadComma:
            return "That key types. Press one that doesn't, like Right Control or an F key."
        default:
            return nil
        }
    }
}

/// What the event tap does with one key event while a key that is not a
/// modifier is the activation key. The key on its own starts and stops
/// dictation and never reaches the app; with Command, Option, Control or
/// Shift already held it is a shortcut and passes through untouched.
struct ActivationKeyTap {
    /// `again`: a new press while the last one's up never came (Secure Input
    /// or a stalled tap can lose it): that press lets go, then presses again.
    enum Effect: Equatable { case press, release, again }

    /// The key's down was taken, so its repeats and its up are taken too.
    private(set) var owned = false
    /// While a new key is being learned the key starts nothing.
    var paused = false

    static let shortcutFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Returns whether to take the event (the app never sees it) and what it does.
    mutating func handle(keyCode: Int64, down: Bool, isRepeat: Bool, flags: CGEventFlags, key: ActivationKey) -> (take: Bool, effect: Effect?) {
        guard keyCode == Int64(key.keyCode), !key.isModifier else { return (false, nil) }
        if down {
            if owned { return (true, isRepeat ? nil : .again) }
            // A repeat of a down that went through belongs to the app, as does its up.
            guard !isRepeat, !paused, flags.intersection(Self.shortcutFlags).isEmpty else { return (false, nil) }
            owned = true
            return (true, .press)
        }
        guard owned else { return (false, nil) }
        owned = false
        return (true, .release)
    }

    mutating func reset() { owned = false }
}

/// Settings → Shortcut → Press a key: one key, pressed and let go on its own,
/// becomes the activation key. Keys held when learning began are ignored
/// until let go; a second key while the first is down is a chord, refused.
struct KeyLearner {
    enum Outcome: Equatable { case listening, learned(ActivationKey), refused(String), cancelled }

    static let chordNote = "Press one key on its own."

    /// `NX_SECONDARYFNMASK`, fn held.
    static let fnBit: UInt64 = 0x80_0000

    private var down: UInt16?
    private var chord = false
    private var fnAlone = false

    init() {}

    mutating func keyDown(_ keyCode: UInt16, isRepeat: Bool, flags: CGEventFlags) -> Outcome {
        if Int(keyCode) == kVK_Escape { return .cancelled }
        guard !isRepeat else { return .listening }
        pressed(keyCode, othersHeld: !flags.intersection(ActivationKeyTap.shortcutFlags).isEmpty)
        return .listening
    }

    mutating func keyUp(_ keyCode: UInt16) -> Outcome { released(keyCode) }

    /// A modifier moved: down or up, read from its own side's bit.
    mutating func flagsChanged(_ keyCode: UInt16, flags: UInt64) -> Outcome {
        switch Int(keyCode) {
        case kVK_CapsLock:
            // One event per press, a toggle: refused at once.
            if down != nil { chord = true; return .listening }
            return .refused(ActivationKey.refusal(for: keyCode)!)
        case kVK_Function:
            // Held to type an F key on a laptop keyboard: only fn on its own is refused.
            if flags & Self.fnBit != 0 {
                fnAlone = down == nil
            } else if fnAlone {
                fnAlone = false
                return .refused(ActivationKey.refusal(for: keyCode)!)
            }
            return .listening
        default:
            break
        }
        guard let bit = ActivationKey.deviceBits[keyCode] else { return .listening }
        if flags & bit != 0 {
            let all = ActivationKey.deviceBits.values.reduce(0, |)
            pressed(keyCode, othersHeld: flags & all & ~bit != 0)
            return .listening
        }
        return released(keyCode)
    }

    private mutating func pressed(_ keyCode: UInt16, othersHeld: Bool) {
        fnAlone = false
        if let down {
            if down != keyCode { chord = true }
            return
        }
        down = keyCode
        chord = othersHeld
    }

    private mutating func released(_ keyCode: UInt16) -> Outcome {
        guard keyCode == down else { return .listening }
        let wasChord = chord
        down = nil
        chord = false
        if wasChord { return .refused(Self.chordNote) }
        if let reason = ActivationKey.refusal(for: keyCode) { return .refused(reason) }
        return .learned(ActivationKey(keyCode: keyCode))
    }
}
