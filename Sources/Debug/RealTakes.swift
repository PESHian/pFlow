#if DEBUG
import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import SwiftUI

/// Takes the way the owner dictates (Debug harness, test VM only, fictional
/// audio): the real Right Command monitor, the real coordinator, the real
/// Apple speech recognizer fed from a recording at real-time pace (no
/// microphone), the real injector and capsule, and the person's own saved
/// settings. The harness presses Right Command as a person would: held for the
/// whole take (push-to-talk), or double-tapped and tapped again to finish.
@MainActor
final class RealPipeline {
    let next: URL
    let history = HarnessHistory()
    let injector = TextInjector()
    let hud = HUDController()
    let coordinator: RecordingCoordinator
    private let hotkeys = ModifierHotkeyMonitor()

    init(folder: URL) {
        next = folder.appendingPathComponent("next-audio.txt")
        // Apple's recognizer does not run in the VM: its output for each recording, recorded on a Mac, is replayed.
        let locale = Locale(identifier: "en_US")
        DictationSession.assumeSupported(locale)
        let session = DictationSession(locale: locale, capture: QueuedFileCapture(next: next),
                                       appleEngine: { ReplayTranscriber.forCurrentFile() },
                                       appleLiveEngine: { ReplayTranscriber.forCurrentFile(fast: true) })
        session.selectedEngine = { .apple }
        let cleanup = TranscriptCleanupService()
        let cleanupOn = (UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool) ?? true
        coordinator = RecordingCoordinator(session: session, injector: injector, history: history, hud: hud, sounds: HarnessSounds(),
                                           cleaner: cleanup, cleanupEnabled: { cleanupOn }, vocabulary: { [] }, deviceName: { nil },
                                           liveTextMode: { LiveTextMode.saved() })
        InputMethodInstall.ensure()
        InputMethodLink.shared.start()
        hotkeys.recordingIsBusy = { [weak self] in self?.coordinator.state != .idle }
        hotkeys.onRightCommand = { [weak self] effect in self?.coordinator.handle(effect) }
        hotkeys.trigger = .rightCommand
        hotkeys.start()
        hud.prepare()
    }
}

extension TakeHarness {
    private static var pipeline: RealPipeline?

    func realPipeline() -> RealPipeline {
        if let pipeline = Self.pipeline { return pipeline }
        let made = RealPipeline(folder: folder)
        Self.pipeline = made
        return made
    }

    /// The fictional recordings, made with `say` in the VM: (file, words spoken).
    static func recordings() -> [(URL, String)] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("pflow-audio")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".aiff") }.sorted()
        return names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8) else { return nil }
            return (url, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func rightCommand(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: 54, keyDown: down)
        event?.type = .flagsChanged
        event?.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10) : []
        event?.post(tap: .cghidEventTap)
    }

    func audioSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFileProbe(url: url) else { return 4 }
        return file.seconds
    }

    /// One take as the owner makes it. `way`: "hold" or "tap". `during` runs about a second in (a guard's action).
    func realTake(_ target: TakeTarget, way: String, label: String, frames: URL? = nil,
                  during: (() async -> Void)? = nil, beforeStart: (() async -> Void)? = nil) async -> [String: Any] {
        let pipeline = realPipeline()
        let recordings = Self.recordings()
        guard !recordings.isEmpty else { return ["error": "no recordings in ~/pflow-audio"] }
        let (audio, spoken) = recordings[takeIndex % recordings.count]
        takeIndex += 1
        var record: [String: Any] = ["target": target.name, "way": way, "label": label, "audio": audio.lastPathComponent, "spoken": spoken]
        guard await activate(target.app) else { record["error"] = "could not bring the app forward"; return record }
        if target.raiseWindow, let field = target.field, let window = element(field, kAXWindowAttribute) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            await pause(0.6)
        }
        if target.emptyBeforeTake { await emptyField(target) }
        if target.name != "vscode", target.field != nil { await caretToEnd(target) }
        var before = await target.readBack() ?? ""
        if target.name.contains("tiptap"), before.trimmingCharacters(in: .whitespacesAndNewlines) == "Write a message" { before = "" }
        try? audio.path.write(to: pipeline.next, atomically: true, encoding: .utf8)
        let sourceBefore = InputMethodInstall.currentSourceID() ?? "?"
        let board = NSPasteboard.general
        let marker = "Fictional clipboard marker \(UUID().uuidString.prefix(6))"
        board.clearContents()
        board.setString(marker, forType: .string)
        let clipboardCount = board.changeCount
        if let beforeStart { await beforeStart() }
        ReasonLog.recent.removeAll()
        KeyLiveTextField.trace.removeAll()
        LiveLatency.reset()
        var firstVisibleAt: Double?
        let seconds = audioSeconds(audio) + 0.8
        let started = Date()
        // Frames: a capture loop outside pFlow (the VM driver) records while this file names a folder.
        let framesOn = folder.appendingPathComponent("frames-on")
        if let frames { try? frames.path.write(to: framesOn, atomically: true, encoding: .utf8) }
        // Start: hold Right Command, or double-tap it.
        if way == "hold" {
            rightCommand(down: true)
        } else {
            rightCommand(down: true); await pause(0.06); rightCommand(down: false)
            await pause(0.12)
            rightCommand(down: true); await pause(0.06); rightCommand(down: false)
        }
        var liveSeen = 0, firstLiveMs = -1, previewSeen = 0, sourceDuring = "?"
        var duringRan = false
        while Date().timeIntervalSince(started) < seconds {
            await pause(0.1)
            if sourceDuring == "?", Date().timeIntervalSince(started) > 1 { sourceDuring = InputMethodInstall.currentSourceID() ?? "?" }
            if var now = await target.readBack() {
                // Chromium reads the Tiptap page's CSS placeholder out as text; it is not a live word.
                if now.trimmingCharacters(in: .whitespacesAndNewlines) == "Write a message" { now = before }
                let added = now.count > before.count ? String(now.dropFirst(before.count)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let words = added.split(whereSeparator: \.isWhitespace).count
                if words > liveSeen { liveSeen = words }
                if firstLiveMs < 0, words > 0 {
                    firstLiveMs = Int(Date().timeIntervalSince(started) * 1000)
                    firstVisibleAt = ProcessInfo.processInfo.systemUptime
                }
            }
            let shown = pipeline.hud.model.livePreview ? pipeline.hud.model.partial.split(whereSeparator: \.isWhitespace).count : 0
            previewSeen = max(previewSeen, shown)
            if !duringRan, Date().timeIntervalSince(started) > 1.6, let during { duringRan = true; await during() }
        }
        // Finish: let go, or tap once.
        if way == "hold" {
            rightCommand(down: false)
        } else {
            rightCommand(down: true); await pause(0.06); rightCommand(down: false)
        }
        _ = await waitFor(25) { pipeline.coordinator.state == .idle }
        await pause(1.0)
        try? FileManager.default.removeItem(at: framesOn)
        let after = await target.readBack() ?? ""
        let final = pipeline.history.saved.last ?? ""
        record["liveWordsSeen"] = liveSeen
        // From the moment the recording began to play (speech starts within 10 ms of it).
        record["firstVisibleAfterSpeechMs"] = firstVisibleAt.flatMap { at in QueuedFileCapture.startedAt.map { Int((at - $0) * 1000) } } ?? -1
        let delays = LiveLatency.samples.sorted()
        record["pflowDelayMedianMs"] = delays.isEmpty ? -1 : Int(delays[delays.count / 2])
        record["pflowDelayMaxMs"] = Int(delays.last ?? -1)
        record["firstLiveMs"] = firstLiveMs
        record["previewWordsSeen"] = previewSeen
        record["outcome"] = pipeline.coordinator.lastOutcome.map { "\($0)" } ?? "none"
        record["card"] = pipeline.hud.model.livePreview
        record["reason"] = pipeline.hud.model.reason ?? NSNull()
        record["final"] = final
        record["landedOnce"] = !final.isEmpty && Self.landedOnce(before: before, after: after, final: final)
        record["before"] = String(before.suffix(80))
        record["after"] = String(after.suffix(160))
        record["sourceBefore"] = sourceBefore
        record["sourceDuring"] = sourceDuring
        record["sourceAfter"] = InputMethodInstall.currentSourceID() ?? "?"
        record["sourceRestored"] = (InputMethodInstall.currentSourceID() ?? "") == sourceBefore
        record["clipboardUntouched"] = board.changeCount == clipboardCount && board.string(forType: .string) == marker
        record["reasons"] = ReasonLog.recent
        record["keyTrace"] = KeyLiveTextField.trace
        record["startError"] = pipeline.coordinator.lastStartError ?? NSNull()
        pipeline.coordinator.lastStartError = nil
        // Used, not only tried: the input method became active in the app.
        record["inputMethod"] = ReasonLog.recent.contains("input method active in the app")
        note("\(label) \(target.name) \(way): live \(liveSeen) first \(firstLiveMs) ms, preview \(previewSeen), once \(record["landedOnce"]!), outcome \(record["outcome"]!), source \(sourceBefore)→\(sourceDuring)→\(record["sourceAfter"]!), clipboard \(record["clipboardUntouched"]!), im \(record["inputMethod"]!)")
        pipeline.hud.hide(after: 0)
        await pause(0.5)
        return record
    }

    /// "realguard:<kind>:<target>:<hold|tap>": a person's action in a real take.
    func realGuard(_ parts: [String]) async -> [String: Any] {
        let spec = parts.joined(separator: ":")
        guard parts.count == 4, let target = await openTarget(parts[2]) else { return ["spec": spec, "error": "could not open"] }
        var result: [String: Any] = ["spec": spec]
        switch parts[1] {
        case "switch":
            guard let other = await openTarget("textedit2") else { return ["spec": spec, "error": "no other app"] }
            _ = await activate(target.app)
            let otherBefore = await other.readBack() ?? ""
            result["take"] = await realTake(target, way: parts[3], label: spec, during: { [self] in _ = await activate(other.app) })
            result["otherUnchanged"] = await other.readBack() == otherBefore
        case "click":
            result["take"] = await realTake(target, way: parts[3], label: spec, during: { [self] in
                if let field = target.field, let point = center(of: field) { personClick(at: point) }
            })
        case "key":
            result["take"] = await realTake(target, way: parts[3], label: spec, during: { [self] in personKey(CGKeyCode(kVK_ANSI_X)) })
        case "kotoeri", "pinyin":
            let id = parts[1] == "kotoeri" ? "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese" : "com.apple.inputmethod.SCIM.ITABC"
            result["take"] = await realTake(target, way: parts[3], label: spec, beforeStart: { [self] in
                _ = InputMethodInstall.select(id)
                await pause(0.4)
                for code in [kVK_ANSI_N, kVK_ANSI_I, kVK_ANSI_H, kVK_ANSI_O, kVK_ANSI_N] { personKey(CGKeyCode(code)); usleep(60_000) }
                await pause(0.5)
                result["markedAtStart"] = target.field.flatMap(FocusedElement.markedLength) ?? -1
            })
            personKey(CGKeyCode(kVK_Escape))
            _ = InputMethodInstall.select("com.apple.keylayout.ABC")
        default:
            result["take"] = await realTake(target, way: parts[3], label: spec)
        }
        note("\(spec): \(result.filter { $0.key != "take" })")
        return result
    }

    /// The Appearance picker's thumbnails (both styles, every theme), drawn by the
    /// same view the Settings page uses, for the side-by-side with the capsule.
    func thumbnails() -> [String: Any] {
        let custom = ThemePalette(primary: ThemeColor(hex: "AAAAAA")!, secondary: ThemeColor(hex: "AAAAAA")!)
        var made: [String] = []
        for (theme, palette) in [("pesh", ThemePalette.pesh), ("aurora", .aurora), ("solar", .solar), ("custom", custom)] {
            for style in WaveformStyle.allCases {
                let view = RecordingWaveform(levels: AppearanceView.previewLevels, style: style, palette: palette)
                    .padding(12).background(Color(white: 0.16))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                let name = "thumb-\(style.rawValue)-\(theme).png"
                try? png.write(to: folder.appendingPathComponent(name))
                made.append(name)
            }
        }
        return ["spec": "thumbs", "made": made]
    }

    /// The setup page and the input method's setup row, light and dark, as they render now.
    func setupRenders(_ tag: String) -> [String: Any] {
        var made: [String] = []
        for scheme in [ColorScheme.light, .dark] {
            let views: [(String, AnyView)] = [
                ("onboarding", AnyView(OnboardingView().environment(AppState.shared))),
                ("row", AnyView(InputMethodSetupRow().frame(width: 420).padding(16))),
            ]
            for (name, view) in views {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97)))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                let file = "setup-\(tag)-\(name)-\(scheme == .dark ? "dark" : "light").png"
                try? png.write(to: folder.appendingPathComponent(file))
                made.append(file)
            }
        }
        return ["spec": "setup", "made": made]
    }

    /// "twowin:<target 1>:<target 2>:<hold|tap>:<rounds>": two windows of one app, takes alternating
    /// between them; each take's words must land in its own window and the other stay unchanged.
    func twoWindows(_ parts: [String]) async -> [String: Any] {
        let spec = parts.joined(separator: ":")
        guard parts.count == 5, let one = await openTarget(parts[1]), let two = await openTarget(parts[2]),
              let rounds = Int(parts[4]) else { return ["spec": spec, "error": "could not open"] }
        one.raiseWindow = true
        two.raiseWindow = true
        var takes: [[String: Any]] = []
        for n in 0..<rounds {
            for (target, other) in [(one, two), (two, one)] {
                let otherBefore = await other.readBack() ?? ""
                var take = await realTake(target, way: parts[3], label: "\(spec)#\(n + 1)-\(target.name)")
                let otherAfter = await other.readBack() ?? ""
                take["otherUnchanged"] = otherAfter == otherBefore
                take["refused"] = (take["outcome"] as? String ?? "").contains("savedToHistory") && otherAfter == otherBefore
                takes.append(take)
            }
        }
        let right = takes.filter { ($0["landedOnce"] as? Bool == true && $0["otherUnchanged"] as? Bool == true) || $0["refused"] as? Bool == true }.count
        let wrong = takes.filter { $0["otherUnchanged"] as? Bool == false }.count
        note("SUMMARY \(spec): own window once or refused \(right)/\(takes.count), other window changed \(wrong)/\(takes.count)")
        return ["spec": spec, "takes": takes]
    }

    /// "real:<target>:<hold|tap>:<count>", "realframes:<target>:<hold|tap>".
    func realRun(_ parts: [String]) async -> [String: Any] {
        if parts.first == "twowin" { return await twoWindows(parts) }
        if parts.first == "thumbs" { return thumbnails() }
        if parts.first == "setup" { return setupRenders(parts.count > 1 ? parts[1] : "now") }
        if parts.first == "realguard" { return await realGuard(parts) }
        let spec = parts.joined(separator: ":")
        guard parts.count >= 3, let target = await openTarget(parts[1]) else { return ["spec": spec, "error": "could not open"] }
        if parts[0] == "realframes" {
            let frames = folder.appendingPathComponent("frames-\(parts[1])-\(parts[2])")
            return ["spec": spec, "take": await realTake(target, way: parts[2], label: spec, frames: frames)]
        }
        let count = Int(parts.count > 3 ? parts[3] : "5") ?? 5
        var takes: [[String: Any]] = []
        for n in 0..<count { takes.append(await realTake(target, way: parts[2], label: "\(spec)#\(n + 1)")) }
        func tally(_ key: String) -> Int { takes.filter { $0[key] as? Bool == true }.count }
        let live = takes.filter { ($0["liveWordsSeen"] as? Int ?? 0) > 0 }.count
        let preview = takes.filter { ($0["previewWordsSeen"] as? Int ?? 0) > 0 }.count
        note("SUMMARY \(spec): exactly once \(tally("landedOnce"))/\(takes.count), live words \(live)/\(takes.count), preview \(preview)/\(takes.count), source restored \(tally("sourceRestored"))/\(takes.count), clipboard untouched \(tally("clipboardUntouched"))/\(takes.count), input method \(tally("inputMethod"))/\(takes.count)")
        return ["spec": spec, "takes": takes]
    }
}

/// A recording's length, without decoding it.
struct AVAudioFileProbe {
    let seconds: Double
    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        seconds = Double(file.length) / file.processingFormat.sampleRate
    }
}
#endif
