#if DEBUG
import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import SwiftUI

/// Takes the way the owner dictates (Debug harness, test VM only, fictional
/// audio): the real activation key monitor, the real coordinator, the real
/// Apple speech recognizer fed from a recording at real-time pace (no
/// microphone), the real injector and capsule, and the person's own saved
/// settings, the activation key among them. The harness presses that key as a
/// person would: held for the whole take (push-to-talk), or double-tapped and
/// tapped again to finish.
@MainActor
final class RealPipeline {
    let next: URL
    let history = HarnessHistory()
    let injector = TextInjector()
    let hud = HUDController()
    let coordinator: RecordingCoordinator
    private let hotkeys = ActivationKeyMonitor()

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
        hotkeys.onActivation = { [weak self] effect in self?.coordinator.handle(effect) }
        hotkeys.key = ActivationKey.saved()
        hotkeys.start()
        hud.prepare()
    }
}

extension TakeHarness {
    private static var pipeline: RealPipeline?
    /// Quick re-takes: when the last take finished, and what its field held then.
    private static var lastIdleAt: Date?
    private static var lastAfter: [String: String] = [:]

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

    /// The saved activation key, down or up, as the keyboard sends it.
    func rightCommand(down: Bool) {
        let key = ActivationKey.saved()
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.keyCode), keyDown: down)
        if let flag = key.flag, let bit = ActivationKey.deviceBits[key.keyCode] {
            event?.type = .flagsChanged
            event?.flags = down ? CGEventFlags(rawValue: flag.rawValue | bit) : []
        } else {
            event?.flags = []
        }
        event?.post(tap: .cghidEventTap)
    }

    func audioSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFileProbe(url: url) else { return 4 }
        return file.seconds
    }

    /// One take as the owner makes it. `way`: "hold" or "tap". `during` runs about a second in (a guard's action).
    func realTake(_ target: TakeTarget, way: String, label: String, frames: URL? = nil, quickRun: Bool = false,
                  during: (() async -> Void)? = nil, beforeStart: (() async -> Void)? = nil) async -> [String: Any] {
        // A quick re-take follows the last one at once: no setup, the field as the last take left it.
        let quick = quickRun && Self.lastAfter[target.name] != nil
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
            await pause(quickRun ? 0.3 : 0.6)
        }
        if target.emptyBeforeTake, !quick { await emptyField(target) }
        if target.name != "vscode", target.field != nil, !quick { await caretToEnd(target) }
        var before = quick ? Self.lastAfter[target.name] ?? "" : await target.readBack() ?? ""
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
        record["gapMs"] = quick ? Self.lastIdleAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1 : -1
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
        // Finish: let go, or tap once ("taplong": that tap held 1.5 s, past the paste).
        if way == "hold" {
            rightCommand(down: false)
        } else {
            rightCommand(down: true); await pause(way == "taplong" ? 1.5 : 0.06); rightCommand(down: false)
        }
        _ = await waitFor(25) { pipeline.coordinator.state == .idle }
        Self.lastIdleAt = Date()
        await pause(quickRun ? 0.25 : 1.0)
        try? FileManager.default.removeItem(at: framesOn)
        let after = await target.readBack() ?? ""
        Self.lastAfter[target.name] = after
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
        // Used, not only tried: the finished text went in through the input method.
        record["inputMethod"] = ReasonLog.recent.contains { $0.hasPrefix("finished text committed") }
        record["probation"] = ReasonLog.recent.contains("input method on probation: no activation came for this take")
        record["attachTimeout"] = ReasonLog.recent.contains { $0.hasPrefix("input method attach: timeout") }
        note("\(label) \(target.name) \(way)\(quick ? " quick gap \(record["gapMs"]!) ms" : ""): live \(liveSeen) first \(firstLiveMs) ms, preview \(previewSeen), once \(record["landedOnce"]!), outcome \(record["outcome"]!), source \(sourceBefore)→\(sourceDuring)→\(record["sourceAfter"]!), clipboard \(record["clipboardUntouched"]!), im \(record["inputMethod"]!)")
        pipeline.hud.hide(after: 0)
        if !quickRun { await pause(0.5) }
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

    /// "keyprobe:<target>:<accent|shortcut|escape>": the saved activation key
    /// with other keys, outside a full take. accent: ⌥E then E, with Option
    /// held as the activation key when it is one (else Left Option): é, not ´e.
    /// shortcut: the key with Command held starts nothing. escape: Escape while
    /// the key is held cancels.
    func keyProbe(_ parts: [String]) async -> [String: Any] {
        let spec = parts.joined(separator: ":")
        guard parts.count == 3, let target = await openTarget(parts[1]) else { return ["spec": spec, "error": "could not open"] }
        let pipeline = realPipeline()
        let key = ActivationKey.saved()
        // A take started by the key needs a recording to play, as in a real take.
        if let (audio, _) = Self.recordings().first { try? audio.path.write(to: pipeline.next, atomically: true, encoding: .utf8) }
        _ = await activate(target.app)
        await emptyField(target)
        let before = await target.readBack() ?? ""
        var states: [String] = []
        func state() { states.append("\(pipeline.coordinator.state)") }
        ActivationKeyMonitor.trace.removeAll()
        ReasonLog.recent.removeAll()
        switch parts[2] {
        case "accent":
            let option = [kVK_Option, kVK_RightOption].contains(Int(key.keyCode))
            let alt = CGEventFlags.maskAlternate
            if option { rightCommand(down: true) } else { personModifier(58, down: true, flags: CGEventFlags(rawValue: alt.rawValue | 0x20)) }
            await pause(0.5)
            state()
            personModifier(CGKeyCode(kVK_ANSI_E), down: true, flags: alt)
            personModifier(CGKeyCode(kVK_ANSI_E), down: false, flags: alt)
            await pause(0.4)
            if option { rightCommand(down: false) } else { personModifier(58, down: false, flags: []) }
            await pause(0.4)
            personKey(CGKeyCode(kVK_ANSI_E))
        case "shortcut":
            let code = CGKeyCode(key.keyCode)
            personModifier(code, down: true, flags: .maskCommand)
            await pause(0.5)
            state()
            personModifier(code, down: false, flags: .maskCommand)
        case "escape":
            rightCommand(down: true)
            await pause(0.8)
            state()
            personKey(CGKeyCode(kVK_Escape))
            await pause(0.6)
            state()
            rightCommand(down: false)
        default:
            return ["spec": spec, "error": "unknown probe"]
        }
        _ = await waitFor(8) { pipeline.coordinator.state == .idle }
        await pause(0.8)
        state()
        let after = await target.readBack() ?? ""
        let result: [String: Any] = [
            "spec": spec, "key": key.name, "states": states,
            "typed": after.count >= before.count ? String(after.dropFirst(before.count)) : "<shorter>",
            "sourceAfter": InputMethodInstall.currentSourceID() ?? "?",
        ]
        note("\(spec): key \(key.name), states \(states), typed \"\(result["typed"]!)\", source after \(result["sourceAfter"]!)")
        note("  monitor: \(ActivationKeyMonitor.trace)")
        note("  reasons: \(ReasonLog.recent)")
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

    /// Every step of the update window (builds that cannot install themselves), light and dark,
    /// shown as the real window. A capture script outside pFlow (the VM driver) photographs the
    /// window's rectangle, named in "update-shot", and answers in "update-shot-done".
    func updateRenders() async -> [String: Any] {
        let release = GitHubRelease(version: "0.3.17", page: GitHubReleases.releasesPage,
                                    dmg: URL(string: "https://github.com/PESHian/pFlow/releases/download/pflow-desktop-2026.10.25.1/pFlow-Mac-0.3.17.dmg")!,
                                    bytes: 6_601_374, sha256: String(repeating: "0", count: 64), checksumFile: nil)
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/pFlow-Mac-0.3.17.dmg")
        let states: [(String, GitHubUpdateState)] = [
            ("01-idle", .idle), ("02-checking", .checking), ("03-newer", .newer(release)), ("04-up-to-date", .upToDate("0.3.18")),
            ("05-downloading", .downloading(release, received: 3_145_728, total: 6_601_374)), ("06-verifying", .verifying(release)),
            ("07-ready", .ready(release, file: file)),
            ("08-error-offline", .failed(.offline, retry: nil)), ("09-error-rate-limit", .failed(.rateLimited, retry: nil)),
            ("10-error-no-mac-asset", .failed(.noMacAsset, retry: nil)), ("11-error-no-checksum", .failed(.noChecksum, retry: nil)),
            ("12-error-disk", .failed(.disk, retry: release)), ("13-error-checksum-mismatch", .failed(.mismatch, retry: release)),
            ("14-error-too-large", .failed(.tooLarge, retry: release)),
        ]
        let updates = GitHubUpdates()
        let request = folder.appendingPathComponent("update-shot"), answer = folder.appendingPathComponent("update-shot-done")
        var made: [String] = []
        NSApp.activate(ignoringOtherApps: true)
        for (dark, label) in [(false, "light"), (true, "dark")] {
            for (name, state) in states {
                updates.showForRendering(state)
                let host = NSHostingView(rootView: GitHubUpdateView(updates: updates, quit: {}))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "pFlow updates"
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.setContentSize(host.fittingSize)
                window.center()
                window.makeKeyAndOrderFront(nil)
                await pause(0.8)
                let frame = window.frame, height = NSScreen.screens.first?.frame.height ?? frame.maxY
                let shot = "update-\(name)-\(label)"
                try? "\(shot) \(Int(frame.minX)) \(Int(height - frame.maxY)) \(Int(frame.width)) \(Int(frame.height))".write(to: request, atomically: true, encoding: .utf8)
                _ = await waitFor(8) { (try? String(contentsOf: answer, encoding: .utf8)) == shot }
                made.append(shot)
                window.orderOut(nil)
            }
        }
        try? FileManager.default.removeItem(at: request)
        note("SUMMARY updaterenders: \(made.count) shown")
        return ["spec": "updaterenders", "made": made]
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
        guard parts.count >= 5, let one = await openTarget(parts[1]), let two = await openTarget(parts[2]),
              let rounds = Int(parts[4]) else { return ["spec": spec, "error": "could not open"] }
        one.raiseWindow = true
        two.raiseWindow = true
        // "leftover": from the second take on, the input method acts as if macOS sent no activation, so
        // the client still active is the OTHER window's (the last take's). "frames": frames of take 2.
        let leftover = parts.contains("leftover"), withFrames = parts.contains("frames")
        // "appcommit": the leftover window's app commits the first marked words itself.
        // "click": a click into the other window's field during the probe (only where it shows).
        let appCommit = parts.contains("appcommit"), click = parts.contains("click")
        // "quick": the person switches window and starts the next take at once (no field setup).
        let quickSwitch = parts.contains("quick")
        if parts.contains("partial") {
            // Window one large, window two small over its top left: when two is the target, one's caret
            // is inside two's frame (probation allowed) and the right part of one's field still shows.
            for (target, frame) in [(one, CGRect(x: 8, y: 40, width: 1000, height: 660)), (two, CGRect(x: 8, y: 40, width: 470, height: 380))] {
                guard let field = target.field, let window = element(field, kAXWindowAttribute) else { continue }
                var origin = frame.origin, size = frame.size
                if let position = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
                if let extent = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) }
            }
            await pause(0.8)
        }
        // "side": the two windows side by side, so a frame shows both.
        if parts.contains("side") {
            for (n, target) in [one, two].enumerated() {
                guard let field = target.field, let window = element(field, kAXWindowAttribute) else { continue }
                var origin = CGPoint(x: 8 + CGFloat(n) * 508, y: 60), size = CGSize(width: 500, height: 560)
                if let position = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
                if let extent = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) }
            }
            await pause(0.8)
        }
        defer {
            UserDefaults.standard.removeObject(forKey: "pflow.debug.simulateNoActivation")
            UserDefaults.standard.removeObject(forKey: "pflow.debug.simulateAppCommit")
        }
        var takes: [[String: Any]] = []
        for n in 0..<rounds {
            for (target, other) in [(one, two), (two, one)] {
                let otherBefore = await other.readBack() ?? ""
                UserDefaults.standard.set(leftover && !takes.isEmpty, forKey: "pflow.debug.simulateNoActivation")
                UserDefaults.standard.set(appCommit && !takes.isEmpty, forKey: "pflow.debug.simulateAppCommit")
                var clicked = false
                let during: (() async -> Void)? = click && target === two ? { [self] in
                    // A point of the other window's field to the right of the target window.
                    guard let field = other.field, let frame = self.frame(of: field), frame.maxX > 520 else { return }
                    self.personClick(at: CGPoint(x: max(frame.minX + 10, 540), y: frame.midY))
                    clicked = true
                } : nil
                let frames = withFrames && takes.count == 1 ? folder.appendingPathComponent("frames-twowin-\(parts[3])") : nil
                // The other window's live state during the take: anything of this take's words showing there.
                var otherShowed = false
                let watch = Task { @MainActor in
                    while !Task.isCancelled {
                        if let now = await other.readBack(), now != otherBefore { otherShowed = true }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                var take = await realTake(target, way: parts[3], label: "\(spec)#\(n + 1)-\(target.name)", frames: frames, quickRun: quickSwitch, during: during)
                take["clickedOther"] = clicked
                watch.cancel()
                let otherAfter = await other.readBack() ?? ""
                take["otherShowedDuring"] = otherShowed
                take["otherUnchanged"] = otherAfter == otherBefore
                take["refused"] = (take["outcome"] as? String ?? "").contains("savedToHistory") && otherAfter == otherBefore
                takes.append(take)
            }
        }
        let right = takes.filter { ($0["landedOnce"] as? Bool == true && $0["otherUnchanged"] as? Bool == true) || $0["refused"] as? Bool == true }.count
        let wrong = takes.filter { $0["otherUnchanged"] as? Bool == false }.count
        let flashed = takes.filter { $0["otherShowedDuring"] as? Bool == true }.count
        let used = takes.filter { $0["inputMethod"] as? Bool == true }.count
        // Words in both windows: in the target, and the other window changed too.
        let doubled = takes.filter { $0["landedOnce"] as? Bool == true && $0["otherUnchanged"] as? Bool == false }.count
        let cards = takes.filter { ($0["outcome"] as? String ?? "").contains("savedToHistory") && $0["card"] as? Bool == true }.count
        note("SUMMARY \(spec): own window once or refused \(right)/\(takes.count), other window changed \(wrong)/\(takes.count), other window showed words during the take \(flashed)/\(takes.count), input method \(used)/\(takes.count), words in both windows \(doubled)/\(takes.count), card shown \(cards)/\(takes.count), exactly once \(takes.filter { $0["landedOnce"] as? Bool == true }.count)/\(takes.count), attach timeout \(takes.filter { $0["attachTimeout"] as? Bool == true }.count)/\(takes.count), clicked other \(takes.filter { $0["clickedOther"] as? Bool == true }.count)")
        return ["spec": spec, "takes": takes]
    }

    /// "real:<target>:<hold|tap>:<count>", "realframes:<target>:<hold|tap>".
    func realRun(_ parts: [String]) async -> [String: Any] {
        if parts.first == "twowin" { return await twoWindows(parts) }
        if parts.first == "thumbs" { return thumbnails() }
        if parts.first == "updaterenders" { return await updateRenders() }
        if parts.first == "setup" { return setupRenders(parts.count > 1 ? parts[1] : "now") }
        if parts.first == "realguard" { return await realGuard(parts) }
        if parts.first == "keyprobe" { return await keyProbe(parts) }
        if parts.first == "learnkey" { return await learnKeyProbe() }
        let spec = parts.joined(separator: ":")
        guard parts.count >= 3, let target = await openTarget(parts[1]) else { return ["spec": spec, "error": "could not open"] }
        if parts[0] == "realframes" {
            let frames = folder.appendingPathComponent("frames-\(parts[1])-\(parts[2])")
            return ["spec": spec, "take": await realTake(target, way: parts[2], label: spec, frames: frames)]
        }
        let count = Int(parts.count > 3 ? parts[3] : "5") ?? 5
        let quick = parts.count > 4 && parts[4] == "quick"
        var takes: [[String: Any]] = []
        Self.lastAfter[target.name] = nil
        for n in 0..<count { takes.append(await realTake(target, way: parts[2], label: "\(spec)#\(n + 1)", quickRun: quick)) }
        func tally(_ key: String) -> Int { takes.filter { $0[key] as? Bool == true }.count }
        let live = takes.filter { ($0["liveWordsSeen"] as? Int ?? 0) > 0 }.count
        let preview = takes.filter { ($0["previewWordsSeen"] as? Int ?? 0) > 0 }.count
        note("SUMMARY \(spec): exactly once \(tally("landedOnce"))/\(takes.count), live words \(live)/\(takes.count), preview \(preview)/\(takes.count), source restored \(tally("sourceRestored"))/\(takes.count), clipboard untouched \(tally("clipboardUntouched"))/\(takes.count), input method \(tally("inputMethod"))/\(takes.count), probation \(tally("probation"))/\(takes.count), attach timeout \(tally("attachTimeout"))/\(takes.count)\(quick ? ", gap under 1 s \(takes.filter { ($0["gapMs"] as? Int ?? -1) >= 0 && ($0["gapMs"] as? Int ?? 9999) < 1000 }.count)/\(takes.count - 1)" : "")")
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
