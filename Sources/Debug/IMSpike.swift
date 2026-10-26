#if DEBUG
import AppKit
import Carbon

/// M0315 spike only (VM, fictional text): drives the spike input method over its local socket.
extension TakeHarness {
    static let spikeID = "com.pesh.inputmethod.pFlow"

    func imSend(_ line: String) -> [String: Any] {
        let path = NSTemporaryDirectory() + "pfim-spike.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { p in withUnsafeMutablePointer(to: &addr.sun_path) { strcpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), p) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { return ["error": "no socket"] }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0, let d = try? JSONSerialization.jsonObject(with: Data(buffer[0..<n])) as? [String: Any] else { return ["error": "no answer"] }
        return d
    }

    func source(_ id: String) -> TISInputSource? {
        (TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    func sourceID(_ s: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "?" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    func keyboardID() -> String { sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) }

    func imSpike(_ name: String) async -> [String: Any] {
        var r: [String: Any] = ["spec": "im:\(name)"]
        guard let target = await openTarget(name) else { r["error"] = "could not open"; return r }
        guard await activate(target.app) else { r["error"] = "not forward"; return r }
        if target.name != "vscode" { await caretToEnd(target) }
        let before = await target.readBack() ?? ""
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        r["keyboardBefore"] = sourceID(previous)
        guard let ours = source(Self.spikeID) else { r["error"] = "not installed"; return r }
        let started = Date()
        r["select"] = Int(TISSelectInputSource(ours))
        var attached = false
        _ = await waitFor(3) {
            let s = imSend("status")
            attached = (s["client"] as? String) == target.app.bundleIdentifier
            return attached
        }
        r["attachMs"] = attached ? Int(Date().timeIntervalSince(started) * 1000) : -1
        r["status"] = imSend("status")
        r["keyboardDuring"] = keyboardID()
        let (spoken, final) = Self.sentences[takeIndex % Self.sentences.count]
        takeIndex += 1
        let words = spoken.split(separator: " ").map(String.init)
        var partialsSeen = 0, partials = 0
        var marks: [[String: Any]] = []
        for n in stride(from: 2, through: words.count, by: 2) {
            let partial = words.prefix(n).joined(separator: " ")
            partials += 1
            let m = imSend("mark \(partial)")
            await pause(0.35)
            let ax = await target.name == "vscode" ? nil : target.readBack()
            let im = imSend("read")
            let tail = (im["tail"] as? String) ?? (im["tail2"] as? String) ?? ""
            let seen = (ax?.contains(partial) ?? false) || tail.contains(partial)
            if seen { partialsSeen += 1 }
            marks.append(["partial": partial, "marked": m["marked"] ?? NSNull(), "axHas": ax?.contains(partial) ?? NSNull(), "clientHas": tail.contains(partial)])
        }
        r["marks"] = marks
        r["partialsSeen"] = "\(partialsSeen)/\(partials)"
        let c = imSend("commit \(final)")
        r["commit"] = c
        await pause(0.6)
        let read = imSend("read")
        r["clientTail"] = (read["tail"] as? String).map { String($0.suffix(80)) } ?? NSNull()
        TISSelectInputSource(previous)
        await pause(0.4)
        r["keyboardAfter"] = keyboardID()
        let after = await target.readBack() ?? ""
        r["before"] = String(before.suffix(60))
        r["after"] = String(after.suffix(100))
        r["landedOnce"] = Self.landedOnce(before: before, after: after, final: final)
        r["clientOnce"] = ((read["tail"] as? String) ?? "").components(separatedBy: final).count - 1
        r["frontmostStill"] = frontmost() == target.app.processIdentifier
        note("im \(name): attach \(r["attachMs"]!) ms client \((r["status"] as? [String: Any])?["client"] ?? "-") partials \(partialsSeen)/\(partials) once \(r["landedOnce"]!) clientOnce \(r["clientOnce"]!) kb \(r["keyboardBefore"]!)→\(r["keyboardDuring"]!)→\(r["keyboardAfter"]!)")
        return r
    }

    func switcherWindows() -> [String] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w in
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard owner.contains("TextInput") || owner.contains("CursorUI") || owner.contains("Switcher") else { return nil }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return "\(owner) layer \(w[kCGWindowLayer as String] ?? "?") \(b["Width"] ?? "?")x\(b["Height"] ?? "?")"
        }
    }

    func markedNow(_ target: TakeTarget) -> Int {
        focused(target.app.processIdentifier).flatMap(FocusedElement.markedLength) ?? -1
    }

    /// Side effects: the caret pop-up, a person's key or click mid-take, an open Kotoeri word.
    func imSide(_ name: String) async -> [String: Any] {
        var r: [String: Any] = ["spec": "imside:\(name)"]
        guard let target = await openTarget(name), await activate(target.app), let ours = source(Self.spikeID) else { r["error"] = "setup"; return r }
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        // 1. Pop-up near the caret when the source changes.
        await caretToEnd(target)
        let windowsBefore = switcherWindows()
        TISSelectInputSource(ours)
        await pause(0.25)
        r["switcherBefore"] = windowsBefore
        r["switcherAfterSelect"] = switcherWindows()
        _ = await waitFor(2) { (imSend("status")["client"] as? String) == target.app.bundleIdentifier }
        // 2. A person's key while words are marked.
        let before = await target.readBack() ?? ""
        _ = imSend("mark seven blue kites")
        await pause(0.3)
        personKey(7) // x
        await pause(0.5)
        let afterKey = await target.readBack() ?? ""
        r["keyMidTake"] = ["before": String(before.suffix(40)), "after": String(afterKey.suffix(60)), "imStatus": imSend("status"), "axMarked": markedNow(target)]
        _ = imSend("unmark")
        // 3. A click while words are marked.
        await caretToEnd(target)
        _ = imSend("mark the harbor lights")
        await pause(0.3)
        if let field = target.field, let p = center(of: field) { personClick(at: p) }
        await pause(0.5)
        r["clickMidTake"] = ["after": String((await target.readBack() ?? "").suffix(80)), "imStatus": imSend("status"), "axMarked": markedNow(target)]
        _ = imSend("unmark")
        TISSelectInputSource(previous)
        await pause(0.4)
        // 4. An open Kotoeri word when pFlow selects its source.
        if let kotoeri = source("com.apple.inputmethod.Japanese") ?? source("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese") {
            await caretToEnd(target)
            TISSelectInputSource(kotoeri)
            await pause(0.5)
            let k0 = await target.readBack() ?? ""
            for code: CGKeyCode in [45, 34, 4, 31, 45] { personKey(code); try? await Task.sleep(nanoseconds: 60_000_000) }
            await pause(0.6)
            let k1 = await target.readBack() ?? ""
            let marked1 = markedNow(target)
            TISSelectInputSource(ours)
            await pause(0.6)
            let k2 = await target.readBack() ?? ""
            r["kotoeri"] = ["source": sourceID(kotoeri), "typedAdded": String(k1.dropFirst(k0.count)), "markedWhileTyping": marked1,
                            "afterSelectOurs": String(k2.dropFirst(k0.count)), "markedAfterSelect": markedNow(target), "imStatus": imSend("status")]
            personKey(53) // Escape
            TISSelectInputSource(previous)
            await pause(0.4)
        }
        r["keyboardAfter"] = keyboardID()
        note("imside \(name): \(r)")
        return r
    }
}
#endif
