#if DEBUG
import AppKit
import Carbon
import SwiftUI

/// Settings → Shortcut → Press a key with real key events (Debug harness, test
/// VM only): the Shortcut card from the Settings page in a window of its own,
/// the real KeyLearning and activation key monitor, keys posted as the
/// keyboard sends them. Each step records whether it is listening, the note,
/// and the key; the card is drawn to PNG in the listening, refused and learned states.
@MainActor
@Observable
private final class LearnProbeState {
    var key: ActivationKey = .rightCommand
    let learning = KeyLearning()
    let monitor = ActivationKeyMonitor()
}

private struct LearnProbeCard: View {
    let state: LearnProbeState

    var body: some View {
        let learning = state.learning
        let model = SettingsPageModel(
            activationKey: Binding(get: { state.key }, set: { state.key = $0 }),
            learningKey: learning.listening, learningNote: learning.note,
            learnKey: {}, cancelLearning: { learning.stop() },
            liveTextMode: .constant(.typeInApp), engine: .constant(.apple),
            intelligenceMode: .constant(.onDevice), language: .constant(AppState.systemLanguage),
            launchAtLogin: .constant(false), showInDock: .constant(false), showInMenuBar: .constant(true),
            sounds: .constant(true), copyDictation: .constant(false), cleanup: .constant(false))
        let section = SettingsContent(model: model).sections.first { $0.name == "Shortcut" }
        return (section?.view ?? AnyView(EmptyView()))
            .padding(Theme.s5)
            .frame(width: 560)
    }
}

extension TakeHarness {
    func learnKeyProbe() async -> [String: Any] {
        let state = LearnProbeState()
        state.monitor.key = .rightCommand
        state.monitor.start()
        defer { state.monitor.stop() }
        let host = NSHostingView(rootView: LearnProbeCard(state: state).modifier(PeshAppearance()))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Fictional Shortcut card"
        window.contentView = host
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await pause(0.8)

        var steps: [[String: Any]] = []
        func learn() {
            state.monitor.paused = true
            state.learning.start(onLearned: { state.key = $0 }, onEnd: { state.monitor.paused = false })
        }
        func shot(_ name: String) {
            // As tall as the card wants, so every line wraps as it does on the Settings page.
            host.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 560, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                host.appearance = NSAppearance(named: appearance)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("shortcut-\(name)-\(look).png"))
            }
            host.appearance = nil
        }
        func record(_ step: String) async {
            await pause(0.5)
            let entry: [String: Any] = ["step": step, "listening": state.learning.listening,
                                        "note": state.learning.note ?? "", "key": state.key.name,
                                        "paused": state.monitor.paused, "windowKey": window.isKeyWindow]
            steps.append(entry)
            note("  learner saw: \(KeyLearning.trace)")
            KeyLearning.trace.removeAll()
            note("learnkey \(step): listening \(entry["listening"]!), note \"\(entry["note"]!)\", key \(entry["key"]!), paused \(entry["paused"]!), window key \(entry["windowKey"]!)")
        }
        func modifier(_ code: Int, bit: UInt64, flag: CGEventFlags, down: Bool) {
            personModifier(CGKeyCode(code), down: down, flags: down ? CGEventFlags(rawValue: flag.rawValue | bit) : [])
        }

        shot("default")
        learn(); await record("listening"); shot("listening")
        personKey(CGKeyCode(kVK_ANSI_A)); await record("letter A"); shot("refused")
        personKey(CGKeyCode(kVK_Escape)); await record("Escape")
        learn()
        modifier(kVK_RightOption, bit: 0x40, flag: .maskAlternate, down: true)
        personModifier(CGKeyCode(kVK_F8), down: true, flags: .maskAlternate)
        personModifier(CGKeyCode(kVK_F8), down: false, flags: .maskAlternate)
        modifier(kVK_RightOption, bit: 0x40, flag: .maskAlternate, down: false)
        await record("Right Option + F8 together")
        modifier(kVK_RightOption, bit: 0x40, flag: .maskAlternate, down: true)
        modifier(kVK_RightOption, bit: 0x40, flag: .maskAlternate, down: false)
        await record("Right Option alone")
        personKey(CGKeyCode(kVK_F9)); await record("F9"); shot("learned")
        learn()
        modifier(kVK_RightControl, bit: 0x2000, flag: .maskControl, down: true)
        modifier(kVK_RightControl, bit: 0x2000, flag: .maskControl, down: false)
        await record("Right Control")
        learn(); await pause(KeyLearning.timeoutSeconds + 1); await record("nothing for the timeout")
        learn()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.makeKeyAndOrderFront(nil)
        await record("another window in front")
        other.orderOut(nil)
        window.orderOut(nil)
        return ["spec": "learnkey", "steps": steps]
    }
}
#endif
