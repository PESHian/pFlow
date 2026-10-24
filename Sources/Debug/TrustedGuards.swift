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
        default:
            result["error"] = "unknown spec"
        }
        return result
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
        note("input source \(found): selected \(selected)")
        return selected
    }
}
#endif
