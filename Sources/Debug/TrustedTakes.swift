#if DEBUG
import AppKit
import ApplicationServices
import Carbon

/// Debug builds only, never in Release: whole takes through the real
/// coordinator, injector and HUD, with scripted transcript updates in place
/// of the microphone, against fictional documents this harness opens itself
/// in real apps (TextEdit, Notes, Safari, Chrome, LibreOffice Writer, VS
/// Code). Meant for a disposable test Mac (a VM) where this build has
/// Accessibility: it brings apps forward and, for the guard checks, posts
/// clicks and keys as "the person". Writes results.json and log.txt.
@MainActor
enum TrustedTakes {
    static let flag = "--pflow-trusted-takes"

    static func start(arguments: [String]) {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { exit(2) }
        let folder = URL(fileURLWithPath: arguments[index + 1])
        let specs = Array(arguments[(index + 2)...])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // The app starts watching at launch (PermissionsManager.refresh); so does the harness.
        PersonInput.shared.start()
        Task { @MainActor in
            let harness = TakeHarness(folder: folder)
            var results: [[String: Any]] = []
            let header: [String: Any] = ["trusted": AXIsProcessTrusted(),
                                         "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""]
            for spec in specs {
                results.append(await harness.run(spec))
                harness.save(header.merging(["results": results]) { a, _ in a })
            }
            harness.closeAll()
            harness.save(header.merging(["results": results, "done": true]) { a, _ in a })
            exit(0)
        }
        app.run()
    }
}

/// One app with one field pFlow dictates into, opened by the harness.
@MainActor
final class TakeTarget {
    let name: String
    let app: NSRunningApplication
    var field: AXUIElement?
    /// What the field (or the saved document) holds now.
    var readBack: () async -> String? = { nil }
    var windowTitle: String
    /// Empties the field before each take (a fresh message each time).
    var emptyBeforeTake = false

    init(name: String, app: NSRunningApplication, windowTitle: String) {
        self.name = name
        self.app = app
        self.windowTitle = windowTitle
    }
}

@MainActor
final class TakeHarness {
    let folder: URL
    var log: [String] = []
    var opened: [NSRunningApplication] = []
    private var targets: [String: TakeTarget] = [:]

    init(folder: URL) { self.folder = folder }

    func note(_ line: String) {
        log.append(line)
        try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }

    func save(_ report: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: folder.appendingPathComponent("results.json"))
    }

    // MARK: Accessibility helpers

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func children(_ element: AXUIElement) -> [AXUIElement] { (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    func focused(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        return element(app, kAXFocusedUIElementAttribute)
    }

    func title(_ pid: pid_t) -> String? {
        element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute).flatMap { string($0, kAXTitleAttribute) }
    }

    func selection(_ field: AXUIElement) -> NSRange? {
        guard let raw = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    @discardableResult
    func select(_ field: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func find(_ root: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(root) { return root }
        guard depth < 60 else { return nil }
        for child in children(root) { if let found = find(child, depth: depth + 1, match) { return found } }
        return nil
    }

    func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.1)
        }
        return condition()
    }

    func frontmost() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func activate(_ app: NSRunningApplication) async -> Bool {
        if frontmost() == app.processIdentifier { return true }
        app.activate(options: [])
        if await waitFor(1.5, { frontmost() == app.processIdentifier }) { return true }
        guard let url = app.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return await waitFor(4) { frontmost() == app.processIdentifier }
    }

    func open(_ files: [URL], bundle: String, arguments: [String] = [], newInstance: Bool = false) async -> NSRunningApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = newInstance
        let app: NSRunningApplication? = await withCheckedContinuation { continuation in
            if files.isEmpty {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in continuation.resume(returning: app) }
            } else {
                NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration) { app, _ in continuation.resume(returning: app) }
            }
        }
        if let app, !opened.contains(app) { opened.append(app) }
        return app
    }

    func pressMenu(_ pid: pid_t, _ menu: String, _ item: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = element(app, kAXMenuBarAttribute),
              let top = children(bar).first(where: { string($0, kAXTitleAttribute) == menu }),
              let list = children(top).first,
              let entry = children(list).first(where: { string($0, kAXTitleAttribute) == item }) else { return false }
        return AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success
    }

    func closeAll() {
        for app in opened where !app.isTerminated { app.forceTerminate() }
    }

    // MARK: Person input (unmarked events, as a person's would be)

    func personClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func personKey(_ code: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] { CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
    }

    /// Deletes what the field holds with Backspace (no modifier keys), before a take starts.
    func emptyField(_ target: TakeTarget) async {
        await caretToEnd(target)
        let count = (await target.readBack() ?? "").count
        for _ in 0..<(count + 2) { personKey(51); try? await Task.sleep(nanoseconds: 15_000_000) }
        await pause(0.6)
    }

    func center(of element: AXUIElement) -> CGPoint? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGPoint(x: point.x + min(size.width / 2, 120), y: point.y + min(size.height / 2, 14))
    }

    // MARK: Targets

    static let page = """
    <!doctype html><meta charset="utf-8"><title>TITLE</title>
    <style>body{font:16px -apple-system} [contenteditable]{border:1px solid #888;min-height:80px;padding:6px}</style>
    <p><input id="input" aria-label="Fictional line" size="70"></p>
    <p><textarea id="textarea" aria-label="Fictional notes" rows="6" cols="70"></textarea></p>
    <div id="compose" contenteditable="true" role="textbox" aria-multiline="true" aria-label="Fictional message body"></div>
    <p><input id="password" type="password" aria-label="Fictional password" size="30"></p>
    <script>
    const id = 'KIND';
    window.addEventListener('load', () => { const e = document.getElementById(id); e.focus(); });
    </script>
    """

    func openTarget(_ name: String) async -> TakeTarget? {
        if let existing = targets[name], !existing.app.isTerminated { return existing }
        let tag = String(UUID().uuidString.prefix(6))
        var made: TakeTarget?
        switch name {
        case "textedit", "textedit2":
            let file = folder.appendingPathComponent("pflow-fictional-\(name)-\(tag).txt")
            try? "Dear Sam,\n".write(to: file, atomically: true, encoding: .utf8)
            guard let app = await open([file], bundle: "com.apple.TextEdit") else { return nil }
            let t = TakeTarget(name: name, app: app, windowTitle: file.lastPathComponent)
            _ = await waitFor(10) { title(app.processIdentifier)?.contains(file.lastPathComponent) == true }
            made = t
        case "notes":
            guard let app = await open([], bundle: "com.apple.Notes") else { return nil }
            await pause(3)
            _ = await activate(app)
            _ = pressMenu(app.processIdentifier, "File", "New Note")
            await pause(1.5)
            // The new note's body has the focus; its first line becomes the title.
            if let body = focused(app.processIdentifier), string(body, kAXRoleAttribute) == "AXTextArea" {
                AXUIElementSetAttributeValue(body, kAXSelectedTextAttribute as CFString, "Fictional note\n" as CFString)
                await pause(0.5)
            }
            made = TakeTarget(name: name, app: app, windowTitle: "Notes")
        case let web where web.hasPrefix("safari-") || web.hasPrefix("chrome-"):
            let parts = web.split(separator: "-", maxSplits: 1).map(String.init)
            let browser = parts[0], kind = parts[1]
            let pageTitle = "pFlow fictional \(kind) \(tag)"
            // One page per field: a file URL's #fragment does not survive LaunchServices.
            let page = folder.appendingPathComponent("pflow-form-\(kind)-\(tag).html")
            try? Self.page.replacingOccurrences(of: "TITLE", with: pageTitle).replacingOccurrences(of: "KIND", with: kind)
                .write(to: page, atomically: true, encoding: .utf8)
            let url = page
            let app: NSRunningApplication?
            if browser == "safari" {
                app = await open([url], bundle: "com.apple.Safari")
            } else if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
                // The harness's own Chrome is running: a new tab there.
                _ = await open([url], bundle: "com.google.Chrome")
                app = running
            } else {
                let profile = folder.appendingPathComponent("chrome-profile")
                app = await open([], bundle: "com.google.Chrome", arguments: [
                    "--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
                    "--disable-features=Translate", "--new-window", url.absoluteString])
            }
            guard let app else { return nil }
            _ = await waitFor(20) { title(app.processIdentifier)?.contains(pageTitle) == true }
            WebAppAccessibility.enable(app)
            await pause(1.5)
            made = TakeTarget(name: name, app: app, windowTitle: pageTitle)
        case "t3", "t3empty":
            // T3 Code (Electron): its composer, a new thread without a project.
            guard let app = await open([], bundle: "com.t3tools.t3code") else { return nil }
            _ = await waitFor(20) { title(app.processIdentifier) != nil }
            WebAppAccessibility.enable(app)
            await pause(3)
            made = TakeTarget(name: name, app: app, windowTitle: title(app.processIdentifier) ?? "T3 Code")
            made?.emptyBeforeTake = name == "t3empty"
        case "terminal":
            guard let app = await open([], bundle: "com.apple.Terminal") else { return nil }
            await pause(3)
            made = TakeTarget(name: name, app: app, windowTitle: title(app.processIdentifier) ?? "Terminal")
        case "writer":
            let file = folder.appendingPathComponent("pflow-fictional-writer-\(tag).odt")
            guard let app = await open([], bundle: "org.libreoffice.script", arguments: ["--writer", "--norestore", "--nologo"]) else { return nil }
            _ = await waitFor(25) { title(app.processIdentifier).map { $0.contains("Untitled") || $0.contains("Writer") } == true }
            await pause(2)
            made = TakeTarget(name: name, app: app, windowTitle: title(app.processIdentifier) ?? "Writer")
            _ = file
        case "vscode":
            let data = folder.appendingPathComponent("vscode-data")
            let file = folder.appendingPathComponent("pflow-fictional-vscode-\(tag).txt")
            try? "Dear Sam,\n".write(to: file, atomically: true, encoding: .utf8)
            let arguments = ["--user-data-dir", data.path, "--extensions-dir", data.appendingPathComponent("ext").path,
                             "--disable-extensions", "--disable-workspace-trust", "--skip-welcome", "--skip-release-notes",
                             "--new-window", file.path]
            guard let app = await open([], bundle: "com.microsoft.VSCode", arguments: arguments, newInstance: true) else { return nil }
            _ = await waitFor(30) { title(app.processIdentifier)?.contains(file.lastPathComponent) == true }
            WebAppAccessibility.enable(app)
            await pause(3)
            let t = TakeTarget(name: name, app: app, windowTitle: file.lastPathComponent)
            t.readBack = { [weak self] in
                guard let self else { return nil }
                _ = self.pressMenu(app.processIdentifier, "File", "Save")
                await self.pause(0.8)
                return try? String(contentsOf: file, encoding: .utf8)
            }
            made = t
        default:
            return nil
        }
        guard let made else { return nil }
        _ = await activate(made.app)
        await pause(0.5)
        // Some apps answer the first Accessibility question with nothing while their tree is built.
        _ = await waitFor(8) { focused(made.app.processIdentifier).flatMap { string($0, kAXRoleAttribute) }.map { ["AXTextArea", "AXTextField"].contains($0) } == true }
        made.field = focused(made.app.processIdentifier)
        if made.field == nil, let window = element(AXUIElementCreateApplication(made.app.processIdentifier), kAXFocusedWindowAttribute) {
            // LibreOffice reports no focused element; its document is the window's text area.
            made.field = find(window) { string($0, kAXRoleAttribute) == "AXTextArea" }
        }
        if name != "vscode" {
            made.readBack = { [weak self, weak made] in
                guard let self, let field = made?.field else { return nil }
                return self.string(field, kAXValueAttribute)?.replacingOccurrences(of: "\u{00A0}", with: " ")
            }
        }
        targets[name] = made
        note("target \(name): field role \(made.field.flatMap { string($0, kAXRoleAttribute) } ?? "none"), readable \(await made.readBack() != nil)")
        return made
    }

    /// The app the system says has the keyboard, by name and pid.
    func keyboardAppName() -> String {
        let system = AXUIElementCreateSystemWide()
        guard let app = element(system, kAXFocusedApplicationAttribute) else { return "none" }
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        return "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") \(pid)"
    }

    /// Puts the caret at the end of the field through Accessibility (no keys).
    func caretToEnd(_ target: TakeTarget) async {
        guard let field = target.field else { return }
        let length = (string(field, kAXValueAttribute) as NSString?)?.length ?? 0
        select(field, NSRange(location: length, length: 0))
        await pause(0.2)
    }

    // MARK: Takes

    static let sentences = [
        ("the harbor lights glow softly tonight", "The harbor lights glow softly tonight."),
        ("seven blue kites drift over the dunes", "Seven blue kites drift over the dunes."),
        ("the baker left warm bread by the gate", "The baker left warm bread by the gate."),
        ("a quiet fox crossed the frozen meadow", "A quiet fox crossed the frozen meadow."),
        ("our lantern parade starts after dinner", "Our lantern parade starts after dinner."),
        ("the copper kettle sings on the stove", "The copper kettle sings on the stove."),
        ("nine pelicans rest on the old pier", "Nine pelicans rest on the old pier."),
        ("the orchard ladder leans by the barn", "The orchard ladder leans by the barn."),
    ]

    static func updates(_ spoken: String) -> [String] {
        let words = spoken.split(separator: " ").map(String.init)
        return (2...words.count).map { words.prefix($0).joined(separator: " ") } + [spoken]
    }

    /// The field holds `before` plus the finished text exactly once (at the
    /// caret: the end, or the start in VS Code), and nothing else of the take.
    static func landedOnce(before: String, after: String, final: String) -> Bool {
        guard after.components(separatedBy: final).count == before.components(separatedBy: final).count + 1,
              let range = after.range(of: final, options: .backwards) else { return false }
        func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        return squeezed(after.replacingCharacters(in: range, with: "")) == squeezed(before)
    }

    var takeIndex = 0

    /// One take. `during` runs after the second update (a guard's action);
    /// `beforeFinish` right before the take ends.
    func take(_ target: TakeTarget, mode: LiveTextMode, label: String,
              keepCopy: Bool = false, beforeBegin: (() async -> Void)? = nil, during: (() async -> Void)? = nil, beforeFinish: (() async -> Void)? = nil,
              afterFinish: (() async -> Void)? = nil) async -> [String: Any] {
        let (spoken, final) = Self.sentences[takeIndex % Self.sentences.count]
        takeIndex += 1
        var record: [String: Any] = ["target": target.name, "mode": mode.rawValue, "label": label]
        guard await activate(target.app) else { record["error"] = "could not bring the app forward"; return record }
        if target.emptyBeforeTake { await emptyField(target) }
        if target.name != "vscode" { await caretToEnd(target) }
        let before = await target.readBack() ?? ""
        record["frontmostIsTarget"] = frontmost() == target.app.processIdentifier
        let session = HarnessSession(final: final)
        let injector = TextInjector()
        injector.copyToClipboard = { keepCopy }
        let hud = HUDController()
        let history = HarnessHistory()
        let coordinator = RecordingCoordinator(
            session: session, injector: injector, history: history, hud: hud, sounds: HarnessSounds(),
            cleaner: HarnessCleanup(), cleanupEnabled: { false }, vocabulary: { [] }, deviceName: { nil },
            liveTextMode: { mode })
        if let beforeBegin { await beforeBegin() }
        record["keyboardAppAtBegin"] = keyboardAppName()
        let started = Date()
        coordinator.begin()
        await pause(0.3)
        record["startNote"] = hud.model.liveNote ?? NSNull()
        var liveSeen = 0, firstLiveMs = -1
        for (index, update) in Self.updates(spoken).enumerated() {
            session.emit(update)
            await pause(0.45)
            if mode == .typeInApp, target.name != "vscode", let now = await target.readBack(), now.count > before.count {
                let added = String(now.dropFirst(before.count)).trimmingCharacters(in: .whitespaces)
                let words = added.split(separator: " ").count
                if words > liveSeen { liveSeen = words }
                if firstLiveMs < 0, words > 0 { firstLiveMs = Int(Date().timeIntervalSince(started) * 1000) }
            }
            if index == 1, let during { await during() }
        }
        if let beforeFinish { await beforeFinish() }
        record["keyboardAppAtFinish"] = keyboardAppName()
        record["markedAtFinish"] = focused(target.app.processIdentifier).flatMap(FocusedElement.markedLength) ?? -1
        await coordinator.finish()
        if let afterFinish { await afterFinish() }
        await pause(1.2)
        let after = await target.readBack() ?? ""
        record["liveWordsSeen"] = liveSeen
        record["firstLiveMs"] = firstLiveMs
        record["outcome"] = coordinator.lastOutcome.map { "\($0)" } ?? "none"
        record["phase"] = "\(hud.model.phase)"
        record["card"] = hud.model.livePreview
        record["reason"] = hud.model.reason ?? NSNull()
        record["copyOffered"] = hud.model.copyOffer != nil
        record["landedOnce"] = Self.landedOnce(before: before, after: after, final: final)
        record["unchanged"] = after == before
        record["beforeTail"] = String(before.suffix(60))
        record["afterTail"] = String(after.suffix(90))
        record["final"] = final
        record["before"] = before
        record["after"] = after
        note("\(label) \(target.name) \(mode.rawValue): live \(liveSeen) first \(firstLiveMs) ms, once \(record["landedOnce"]!), outcome \(record["outcome"]!), card \(hud.model.livePreview) \(hud.model.reason ?? "")")
        hud.hide(after: 0)
        await pause(0.4)
        return record
    }

    /// "target:mode:count", or a guard check by name.
    func run(_ spec: String) async -> [String: Any] {
        let parts = spec.split(separator: ":").map(String.init)
        if parts.count == 3, let mode = parts[1] == "off" ? LiveTextMode.off : parts[1] == "type" ? .typeInApp : nil, let count = Int(parts[2]) {
            guard let target = await openTarget(parts[0]) else { return ["spec": spec, "error": "could not open"] }
            var takes: [[String: Any]] = []
            for n in 0..<count { takes.append(await take(target, mode: mode, label: "\(spec)#\(n + 1)")) }
            let once = takes.filter { $0["landedOnce"] as? Bool == true }.count
            let live = takes.filter { ($0["liveWordsSeen"] as? Int ?? 0) > 0 }.count
            note("SUMMARY \(spec): exactly once \(once)/\(count), live words \(live)/\(count)")
            return ["spec": spec, "takes": takes, "exactlyOnce": once, "withLiveWords": live, "count": count]
        }
        if parts.count == 2, parts[0] == "probe" { return await probe(parts[1]) }
        if parts.count == 2, parts[0] == "im" { return await imSpike(parts[1]) }
        if parts.count == 2, parts[0] == "imside" { return await imSide(parts[1]) }
        if parts.first == "capsules" { return await capsules(hold: Double(parts.count > 1 ? parts[1] : "4") ?? 4) }
        if parts.first == "cards" { return await cards(hold: Double(parts.count > 1 ? parts[1] : "4") ?? 4) }
        return await guardCheck(spec)
    }

    /// The recording capsule on screen in each state, `hold` seconds each,
    /// for screenshots over whatever is behind it: quiet and loud listening,
    /// transcribing, and a status after the take.
    func capsules(hold: Double) async -> [String: Any] {
        let hud = HUDController()
        var shown: [String] = []
        let states: [(String, HUDPhase, Float)] = [("quiet", .listening, 0.04), ("loud", .listening, 0.85),
                                                   ("processing", .transcribing, 0), ("status", .copied, 0)]
        for (name, phase, level) in states {
            hud.show(device: nil, livePreview: false)
            hud.setPhase(phase)
            let start = Date()
            note("capsule \(name) shown")
            while Date().timeIntervalSince(start) < hold {
                if phase == .listening { hud.setLevel(level * Float(0.6 + 0.4 * abs(sin(Date().timeIntervalSince(start) * 9)))) }
                await pause(0.05)
            }
            if let panel = hud.panelForTesting { shown.append("\(name): \(Int(panel.frame.width))x\(Int(panel.frame.height)) key=\(panel.isKeyWindow)") }
            hud.hide(after: 0)
            await pause(0.3)
        }
        note("capsules: \(shown)")
        return ["spec": "capsules", "shown": shown]
    }

    /// The explaining card for each way pFlow does not put the text in, as
    /// the coordinator shows it (capsule then card, phase, reason, words).
    func cards(hold: Double) async -> [String: Any] {
        let hud = HUDController()
        let words = "Seven blue kites drift over the dunes."
        let states: [(String, HUDPhase, String, String?)] = [
            ("password", .passwordField, RecordingCoordinator.passwordNote, nil),
            ("failed", .failed, RecordingCoordinator.startFailedNote, nil),
            ("kept", .liveTextKept, RecordingCoordinator.keptNote, words),
            ("keptTyped", .liveTextKeptTyped, RecordingCoordinator.keptTypedNote, words),
            ("typedLeft", .typedTextLeft, RecordingCoordinator.typedLeftNote, nil),
            ("clipboard", .copied, RecordingCoordinator.onClipboardNote, words)]
        for (name, phase, reason, text) in states {
            hud.show(device: nil, livePreview: false)
            hud.setLivePreview(true)
            hud.setPhase(phase)
            hud.setReason(reason)
            if let text { hud.setPartial(text); hud.offerCopy(text) }
            note("card \(name) shown")
            await pause(hold)
            hud.hide(after: 0)
            await pause(0.3)
        }
        return ["spec": "cards"]
    }

    /// What Accessibility shows of the target's focused element, and whether
    /// a range write there shows up, read back over two seconds.
    func probe(_ name: String) async -> [String: Any] {
        guard let target = await openTarget(name) else { return ["spec": "probe:\(name)", "error": "could not open"] }
        var result: [String: Any] = ["spec": "probe:\(name)", "window": title(target.app.processIdentifier) ?? ""]
        guard let field = focused(target.app.processIdentifier) ?? target.field else {
            result["focused"] = "none"
            let system = AXUIElementCreateSystemWide()
            result["systemFocused"] = element(system, kAXFocusedUIElementAttribute).flatMap { string($0, kAXRoleAttribute) } ?? "none"
            var roles: [String] = []
            func walk(_ e: AXUIElement, _ depth: Int) {
                guard roles.count < 60, depth < 12 else { return }
                roles.append(String(repeating: ".", count: depth) + (string(e, kAXRoleAttribute) ?? "?"))
                children(e).forEach { walk($0, depth + 1) }
            }
            if let window = element(AXUIElementCreateApplication(target.app.processIdentifier), kAXFocusedWindowAttribute) { walk(window, 0) }
            result["tree"] = roles
            note("probe \(name): no focused element; system \(result["systemFocused"]!); tree \(roles.prefix(40))")
            await pause(8)
            return result
        }
        func settable(_ name: String) -> Bool {
            var flag = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(field, name as CFString, &flag) == .success && flag.boolValue
        }
        var names: CFArray?
        AXUIElementCopyAttributeNames(field, &names)
        result["attributes"] = (names as? [String]) ?? []
        result["role"] = string(field, kAXRoleAttribute) ?? ""
        result["focusedAttribute"] = (attribute(field, kAXFocusedAttribute) as? Bool).map { "\($0)" } ?? "nil"
        result["subrole"] = string(field, kAXSubroleAttribute) ?? ""
        result["classes"] = (attribute(field, "AXDOMClassList") as? [String]) ?? []
        result["value"] = string(field, kAXValueAttribute).map { String($0.suffix(60)) } ?? "nil"
        result["selection"] = selection(field).map { "\($0.location)+\($0.length)" } ?? "nil"
        result["settableRange"] = settable(kAXSelectedTextRangeAttribute)
        result["settableText"] = settable(kAXSelectedTextAttribute)
        result["settableValue"] = settable(kAXValueAttribute)
        let length = (string(field, kAXValueAttribute) as NSString?)?.length ?? 0
        let selected = select(field, NSRange(location: length, length: 0))
        let write = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, " zebra" as CFString)
        result["selectResult"] = selected
        result["writeResult"] = Int(write.rawValue)
        var seen: [String] = []
        for wait in [0.05, 0.2, 0.5, 1.0, 2.0] {
            await pause(wait)
            seen.append("\(wait)s:" + (string(field, kAXValueAttribute).map { $0.contains("zebra") ? "shown" : "absent" } ?? "nil"))
        }
        result["readBack"] = seen
        note("probe \(name): \(result.filter { $0.key != "attributes" })")
        await pause(8)
        return result
    }
}

/// Transcript updates on a script, in place of an engine.
@MainActor
final class HarnessSession: DictationSessioning {
    var onLevel: ((Float) -> Void)?
    var onTranscript: ((TranscriptUpdate) -> Void)?
    var onLiveStopped: (() -> Void)?
    private let final: String
    private var take = ""
    private var sequence = 0

    init(final: String) { self.final = final }

    func start(take: String, live: Bool) async throws { self.take = take; sequence = 0 }
    func emit(_ text: String) {
        onTranscript?(TranscriptUpdate(session: take, sequence: sequence, text: text, isFinal: false))
        sequence += 1
    }
    func stop() async throws -> TranscriptUpdate {
        defer { sequence += 1 }
        return TranscriptUpdate(session: take, sequence: sequence, text: final, isFinal: true)
    }
    func cancel() async {}
    func setCapturePaused(_ paused: Bool) throws {}
}

@MainActor
final class HarnessHistory: HistoryStoring {
    var saved: [String] = []
    func save(text: String, duration: Double?, device: String?, spokenWordCount: Int?, applicationName: String?, applicationBundleID: String?) {
        saved.append(text)
    }
}

struct HarnessSounds: SoundPlaying {
    func playStart() {}
    func playStop() {}
}

@MainActor
final class HarnessCleanup: TranscriptCleaning {
    var isAvailable: Bool { false }
    func process(_ text: String, cleanup: Bool, vocabulary: [String]) async -> String { text }
}
#endif
