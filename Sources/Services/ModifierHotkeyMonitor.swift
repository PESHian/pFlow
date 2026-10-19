import AppKit
import Carbon.HIToolbox

/// Carbon hotkeys always require a real key alongside modifiers, so a bare
/// modifier can't be one — we watch `flagsChanged` for a clean tap instead.
enum ModifierTrigger: String, CaseIterable, Identifiable {
    case none
    case rightShift, leftShift
    case rightCommand, leftCommand
    case rightOption, leftOption
    case rightControl, leftControl
    case function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Off"
        case .rightShift: return "Right ⇧ Shift"
        case .leftShift: return "Left ⇧ Shift"
        case .rightCommand: return "Right ⌘ Command"
        case .leftCommand: return "Left ⌘ Command"
        case .rightOption: return "Right ⌥ Option"
        case .leftOption: return "Left ⌥ Option"
        case .rightControl: return "Right ⌃ Control"
        case .leftControl: return "Left ⌃ Control"
        case .function: return "fn"
        }
    }

    /// `flagsChanged` reports which key changed — the only way to tell left from right.
    var keyCode: UInt16? {
        switch self {
        case .none: return nil
        case .leftShift: return UInt16(kVK_Shift)
        case .rightShift: return UInt16(kVK_RightShift)
        case .leftCommand: return UInt16(kVK_Command)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .leftOption: return UInt16(kVK_Option)
        case .rightOption: return UInt16(kVK_RightOption)
        case .leftControl: return UInt16(kVK_Control)
        case .rightControl: return UInt16(kVK_RightControl)
        case .function: return UInt16(kVK_Function)
        }
    }

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .none: return nil
        case .leftShift, .rightShift: return .shift
        case .leftCommand, .rightCommand: return .command
        case .leftOption, .rightOption: return .option
        case .leftControl, .rightControl: return .control
        case .function: return .function
        }
    }
}

/// "Clean tap" means pressed and released quickly on its own — so holding
/// Right Shift to type a capital letter never fires the trigger.
@MainActor
final class ModifierHotkeyMonitor {
    var trigger: ModifierTrigger = .none {
        didSet { reset() }
    }
    var onTap: (() -> Void)?
    var onRightCommand: ((RightCommandActivation.Effect) -> Void)?
    var recordingIsBusy: () -> Bool = { false }
    private var activation = RightCommandActivation()
    private var tapTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?

    private func emit(_ effects: [RightCommandActivation.Effect]) {
        for effect in effects {
            onRightCommand?(effect)
            if effect == .pause {
                tapTask?.cancel()
                tapTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(310)) } catch { return }
                    guard let self else { return }
                    self.emit(self.activation.expireTap(at: ProcessInfo.processInfo.systemUptime))
                }
            } else { tapTask?.cancel() }
        }
    }

    private func combination() {
        usedInCombination = true
        if activation.isDown {
            NSLog("Yap: Right Command recording cancelled by a shortcut or click")
            emit(activation.interrupt())
        }
    }

    private func rightCommand(_ event: NSEvent) {
        guard let down = CommandKey.rightCommandTransition(keyCode: Int64(event.keyCode), flags: UInt64(event.modifierFlags.rawValue)) else { return }
        NSLog("Yap: Right Command \(down ? "down" : "up"), flags=\(event.modifierFlags.rawValue)")
        let now = ProcessInfo.processInfo.systemUptime
        if down {
            activation.reconcileIdle(isBusy: recordingIsBusy())
            guard activation.state != .idle || !recordingIsBusy() else { return }
            emit(activation.press(at: now))
            releaseTask?.cancel()
            releaseTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                    guard let self, self.activation.isDown else { return }
                    let commandIsDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
                    let effects = self.activation.recoverRelease(
                        commandIsDown: commandIsDown, at: ProcessInfo.processInfo.systemUptime)
                    if !self.activation.isDown {
                        NSLog("Yap: Right Command release recovered from modifier state")
                        self.emit(effects)
                        return
                    }
                }
            }
        } else {
            releaseTask?.cancel()
            emit(activation.release(at: now))
        }
    }

    /// Longer than this and it was a hold, not a tap.
    private let maximumTapDuration: TimeInterval = 0.6

    private var monitors: [Any] = []
    private var isHolding = false
    private var usedInCombination = false
    private var pressedAt: Date?

    func start() {
        stop()

        // Global monitors observe other apps; local ones cover Yap's own windows.
        addGlobal(matching: .flagsChanged) { [weak self] event in self?.handleFlags(event) }
        addGlobal(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.combination()
        }
        addLocal(matching: .flagsChanged) { [weak self] event in self?.handleFlags(event) }
        addLocal(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.combination()
        }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        tapTask?.cancel()
        releaseTask?.cancel()
        activation.reset()
        reset()
    }

    private func addGlobal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in handler(event) }
        }) {
            monitors.append(monitor)
        }
    }

    private func addLocal(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in handler(event) }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func reset() {
        isHolding = false
        usedInCombination = false
        pressedAt = nil
    }

    private func handleFlags(_ event: NSEvent) {
        if trigger == .rightCommand { rightCommand(event); return }
        guard let keyCode = trigger.keyCode, let flag = trigger.flag else { return }

        guard event.keyCode == keyCode else {
            // A different modifier moved while ours was held — that's a combo.
            if isHolding { usedInCombination = true }
            return
        }

        let isDown = event.modifierFlags.contains(flag)
        if isDown {
            isHolding = true
            usedInCombination = false
            pressedAt = Date()
            return
        }

        guard isHolding else { return }
        isHolding = false
        let heldFor = pressedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        pressedAt = nil

        let noModifiersRemain = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .isEmpty

        if !usedInCombination, heldFor < maximumTapDuration, noModifiersRemain {
            onTap?()
        }
    }
}
