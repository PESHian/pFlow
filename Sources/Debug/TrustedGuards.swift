#if DEBUG
import AppKit
import ApplicationServices
import Carbon

/// The guard checks of the trusted-takes harness: each one does what a
/// person might do while pFlow is about to write, and records that nothing
/// wrong was written.
extension TakeHarness {
    func guardCheck(_ spec: String) async -> [String: Any] {
        let parts = spec.split(separator: ":").map(String.init)
        var result: [String: Any] = ["spec": spec]
        switch parts.first {
        case "guard-switch" where parts.count == 3:
            // Switch to another app after the second update; the other app gets nothing.
            guard let target = await openTarget(parts[1]), let other = await openTarget(parts[2]) else { result["error"] = "could not open"; return result }
            let otherBefore = await other.readBack() ?? ""
            result["take"] = await take(target, mode: .typeInApp, label: spec, during: { [self] in
                _ = await activate(other.app)
                await pause(0.3)
            })
            let otherAfter = await other.readBack() ?? ""
            result["otherUnchanged"] = otherAfter == otherBefore
            result["otherAfterTail"] = String(otherAfter.suffix(60))
        case "guard-click" where parts.count == 2:
            // A click in the field right after pFlow selected its own words.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            var clickMs = -1.0
            TextInjector.afterOwnSelect = { [self] in
                guard let field = target.field, let point = center(of: field) else { return }
                personClick(at: point)
                clickMs = Double(PersonInput.now() - KeyLiveTextField.lastOwnSelect) / 1_000_000
                usleep(30_000)
            }
            result["take"] = await take(target, mode: .typeInApp, label: spec)
            TextInjector.afterOwnSelect = nil
            result["clickMsAfterSelect"] = clickMs
        case "guard-password" where parts.count == 2:
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            let count = { target.field.flatMap { self.attribute($0, kAXNumberOfCharactersAttribute) as? Int } ?? -1 }
            let before = count()
            result["take"] = await take(target, mode: .typeInApp, label: spec)
            result["charactersBefore"] = before
            result["charactersAfter"] = count()
        case "guard-secure" where parts.count == 3:
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            result["take"] = await take(target, mode: parts[2] == "off" ? .off : .typeInApp, label: spec,
                                        beforeFinish: { EnableSecureEventInput() }, afterFinish: { DisableSecureEventInput() })
        case "guard-ime" where parts.count == 3:
            // Japanese input composing (marked text) when the take ends.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            guard selectInputSource("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese") else {
                result["error"] = "Japanese input not available"; return result
            }
            result["inputMethodSelected"] = PersonInput.inputMethodSelected()
            result["take"] = await take(target, mode: parts[2] == "off" ? .off : .typeInApp, label: spec, beforeBegin: { [self] in
                personKey(CGKeyCode(kVK_ANSI_K))
                personKey(CGKeyCode(kVK_ANSI_A))
                await pause(0.5)
            }, afterFinish: { [self] in
                personKey(CGKeyCode(kVK_Escape))
                personKey(CGKeyCode(kVK_Escape))
                await pause(0.3)
            })
            _ = selectInputSource("com.apple.keylayout.ABC") || selectInputSource("com.apple.keylayout.US")
        case "imeprobe" where parts.count == 3:
            // What Accessibility shows while a composition is in progress, then after it is committed.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            guard selectInputSource(parts[2]) else { result["error"] = "input source not available"; return result }
            _ = await activate(target.app)
            func dump(_ label: String) {
                guard let field = focused(target.app.processIdentifier) else { result[label] = "no field"; return }
                var names: CFArray?
                AXUIElementCopyAttributeNames(field, &names)
                var info: [String: String] = [:]
                for name in (names as? [String]) ?? [] {
                    guard let value = attribute(field, name) else { continue }
                    if CFGetTypeID(value) == AXValueGetTypeID() {
                        var range = CFRange()
                        if AXValueGetValue(value as! AXValue, .cfRange, &range) { info[name] = "\(range.location)+\(range.length)"; continue }
                    }
                    if let text = value as? String { info[name] = String(text.suffix(30)) } else if let number = value as? NSNumber { info[name] = number.stringValue } else { info[name] = "\(CFCopyTypeIDDescription(CFGetTypeID(value)) as String? ?? "?")" }
                }
                var parameterized: CFArray?
                AXUIElementCopyParameterizedAttributeNames(field, &parameterized)
                info["_parameterized"] = ((parameterized as? [String]) ?? []).joined(separator: ",")
                result[label] = info
            }
            dump("before")
            for code in [kVK_ANSI_N, kVK_ANSI_I, kVK_ANSI_H, kVK_ANSI_A, kVK_ANSI_O] { personKey(CGKeyCode(code)); usleep(80_000) }
            await pause(0.6)
            dump("composing")
            result["trackerWhileComposing"] = PersonInput.shared.composing(since: (false, 0))
            personKey(CGKeyCode(parts[2].contains("Pinyin") || parts[2].contains("SCIM") ? kVK_Space : kVK_Return))
            await pause(0.6)
            dump("committed")
            result["trackerAfterCommit"] = PersonInput.shared.composing(since: (false, 0))
            _ = selectInputSource("com.apple.keylayout.ABC")
        case "keepcopy" where parts.count == 3:
            // "Copy dictation to clipboard" on: the kept copy is the finished text, unmarked.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            let take = await take(target, mode: parts[2] == "off" ? .off : .typeInApp, label: spec, keepCopy: true)
            result["take"] = take
            let board = NSPasteboard.general
            result["clipboardIsFinal"] = board.string(forType: .string) == take["final"] as? String
            result["clipboardMarked"] = board.types?.contains(where: { [TextInjector.transientType, TextInjector.concealedType].contains($0) }) ?? false
        case "hold" where parts.count == 3:
            // The stop key still held for 200 ms when the take ends: Right Command, or Command+Shift.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            let command = CGEventFlags.maskCommand, rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
            let keys: [(CGKeyCode, CGEventFlags)] = parts[2] == "cmdshift"
                ? [(CGKeyCode(55), command), (CGKeyCode(56), command.union(.maskShift))]
                : [(CGKeyCode(54), rightCommand)]
            result["take"] = await take(target, mode: .typeInApp, label: spec, beforeFinish: { [self] in
                for (code, flags) in keys { personModifier(code, down: true, flags: flags) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    for (code, _) in keys.reversed() { personModifier(code, down: false, flags: []) }
                }
            })
        case "ime-commit" where parts.count == 4:
            // A finished composition ("nihao" + Space in Pinyin, + Return in Kotoeri) before the take: inserted.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            guard selectInputSource(parts[3]) else { result["error"] = "input source not available"; return result }
            result["take"] = await take(target, mode: parts[2] == "off" ? .off : .typeInApp, label: spec, beforeBegin: { [self] in
                for code in [kVK_ANSI_N, kVK_ANSI_I, kVK_ANSI_H, kVK_ANSI_A, kVK_ANSI_O] { personKey(CGKeyCode(code)); usleep(60_000) }
                personKey(CGKeyCode(parts[3].contains("SCIM") ? kVK_Space : kVK_Return))
                await pause(0.6)
            })
            _ = selectInputSource("com.apple.keylayout.ABC")
        case "ime-mid" where parts.count == 4:
            // A composition still open when the take ends: refused, the person's characters left alone.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            guard selectInputSource(parts[3]) else { result["error"] = "input source not available"; return result }
            result["take"] = await take(target, mode: parts[2] == "off" ? .off : .typeInApp, label: spec, beforeBegin: { [self] in
                for code in [kVK_ANSI_N, kVK_ANSI_I, kVK_ANSI_H, kVK_ANSI_A, kVK_ANSI_O] { personKey(CGKeyCode(code)); usleep(60_000) }
                await pause(0.6)
            }, afterFinish: { [self] in
                personKey(CGKeyCode(kVK_Escape)); personKey(CGKeyCode(kVK_Escape))
                await pause(0.3)
            })
            _ = selectInputSource("com.apple.keylayout.ABC")
        case "shortcut-before" where parts.count == 4:
            // Command+C pressed just before the take with an input method selected: not a composition.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            guard selectInputSource(parts[3]) else { result["error"] = "input source not available"; return result }
            result["take"] = await take(target, mode: parts[2] == "off" ? .off : .typeInApp, label: spec, beforeBegin: { [self] in
                personModifier(55, down: true, flags: .maskCommand)
                let source = CGEventSource(stateID: .hidSystemState)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
                    event?.flags = .maskCommand
                    event?.post(tap: .cghidEventTap)
                }
                personModifier(55, down: false, flags: [])
                await pause(0.3)
            })
            _ = selectInputSource("com.apple.keylayout.ABC")
        case "notwatching" where parts.count == 2:
            // The key watch not running: no typed live words, the finished text through the checked paste.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            PersonInput.shared.overrideWatching(false)
            result["take"] = await take(target, mode: .typeInApp, label: spec)
            PersonInput.shared.overrideWatching(nil)
        case "ime-seq" where parts.count == 6:
            // ime-seq:<target>:<off|type>:<source>:<keys>:<extra seconds>. Keys: letters, _ Space, ^ Return, - Backspace,
            // @ a click on the input method's candidate window. Then a take lasting longer by
            // the extra seconds.
            guard let target = await openTarget(parts[1]) else { result["error"] = "could not open"; return result }
            guard selectInputSource(parts[3]) else { result["error"] = "input source not available"; return result }
            let extra = Double(parts[5]) ?? 0
            let codes: [Character: Int] = ["a": kVK_ANSI_A, "b": kVK_ANSI_B, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "k": kVK_ANSI_K,
                                           "n": kVK_ANSI_N, "o": kVK_ANSI_O, "u": kVK_ANSI_U, "y": kVK_ANSI_Y,
                                           "_": kVK_Space, "^": kVK_Return, "-": kVK_Delete]
            var clicked = "none"
            result["take"] = await take(target, mode: parts[2] == "off" ? .off : .typeInApp, label: spec, beforeBegin: { [self] in
                for key in parts[4] {
                    if key == "@" {
                        await pause(0.6)
                        clicked = clickInputMethodWindow()
                    } else if let code = codes[key] {
                        personKey(CGKeyCode(code))
                    }
                    usleep(90_000)
                }
                await pause(0.6)
            }, beforeFinish: { [self] in
                await pause(extra)
            }, afterFinish: { [self] in
                personKey(CGKeyCode(kVK_Escape)); personKey(CGKeyCode(kVK_Escape))
                await pause(0.3)
            })
            result["candidateClick"] = clicked
            _ = selectInputSource("com.apple.keylayout.ABC")
        case "rearm":
            // The tap shut down by the system, and Accessibility followed off and on: never reported as
            // watching while it is not, and watching again (seeing the person) once re-created.
            func seesPerson() async -> Bool {
                let since = PersonInput.now()
                personKey(CGKeyCode(kVK_Escape))   // a plain key-down, no modifier state left behind
                await pause(0.3)
                return PersonInput.shared.acted(since: since) ?? false
            }
            PersonInput.shared.follow(trusted: AXIsProcessTrusted())
            _ = await waitFor(3) { PersonInput.shared.watching }
            result["1 watchingAtStart"] = PersonInput.shared.watching
            PersonInput.shared.invalidateTapForTesting()
            result["2 watchingAfterTapShutDown"] = PersonInput.shared.watching
            result["3 actedKnownAfterTapShutDown"] = PersonInput.shared.acted(since: 0) != nil
            PersonInput.shared.follow(trusted: AXIsProcessTrusted())
            _ = await waitFor(3) { PersonInput.shared.watching }
            result["4 watchingAfterRecreate"] = PersonInput.shared.watching
            result["5 seesPersonAfterRecreate"] = await seesPerson()
            PersonInput.shared.follow(trusted: false)
            result["6 watchingWhileUntrusted"] = PersonInput.shared.watching
            PersonInput.shared.follow(trusted: AXIsProcessTrusted())
            _ = await waitFor(3) { PersonInput.shared.watching }
            result["7 watchingAfterTrustBack"] = PersonInput.shared.watching
            result["8 seesPersonAfterTrustBack"] = await seesPerson()
            note("rearm: \(result.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })")
        default:
            result["error"] = "unknown spec"
        }
        return result
    }

    /// Clicks the middle of the frontmost on-screen window owned by an input method (its candidate list).
    func clickInputMethodWindow() -> String {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for window in windows {
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  PersonInput.isInputMethod(pid) || (pid == frontmost() && layer > 0),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 20, rect.height > 20 else { continue }
            personClick(at: CGPoint(x: rect.midX, y: rect.minY + min(rect.height / 2, 14)))
            return "\(window[kCGWindowOwnerName as String] ?? "?") \(Int(rect.width))x\(Int(rect.height))"
        }
        let owners = windows.prefix(10).map { "\($0[kCGWindowOwnerName as String] ?? "?")/\($0[kCGWindowLayer as String] ?? 0)" }
        return "no input method window; front: " + owners.joined(separator: ", ")
    }

    /// A modifier key pressed or released as the person would.
    func personModifier(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Enables and selects an input source by ID, or the first whose ID ends
    /// with `id` when the exact one is not installed; its input method first.
    func selectInputSource(_ id: String) -> Bool {
        guard let all = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return false }
        func sourceID(_ source: TISInputSource) -> String {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let suffix = "." + (id.split(separator: ".").last.map(String.init) ?? id)
        guard let source = all.first(where: { sourceID($0) == id })
                ?? all.first(where: { id.contains("Kotoeri") && sourceID($0).contains("Kotoeri") && sourceID($0).hasSuffix(suffix) }) else {
            note("input sources: " + all.map(sourceID).filter { $0.contains("Kotoeri") || $0.contains("Japanese") }.joined(separator: ", "))
            return false
        }
        let found = sourceID(source)
        let parentID = found.components(separatedBy: ".").dropLast().joined(separator: ".")
        if let parent = all.first(where: { sourceID($0) == parentID }) { TISEnableInputSource(parent) }
        TISEnableInputSource(source)
        let selected = TISSelectInputSource(source) == noErr
        // The system's input-source switch popup takes the keyboard for a moment.
        Thread.sleep(forTimeInterval: 1.5)
        note("input source \(found): selected \(selected)")
        return selected
    }
}
#endif
