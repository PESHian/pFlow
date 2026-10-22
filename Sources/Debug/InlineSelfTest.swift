#if DEBUG
import AppKit
import ApplicationServices

/// Debug builds only, never in Release: drives the real live-typing path
/// (`TextInjector` begin, reconcile, finalize, cancel) with scripted
/// transcript updates against throwaway documents it opens itself, and writes
/// what each app actually did to a JSON file. No microphone, no key events,
/// no clipboard. The harness writes into a field only after confirming the
/// frontmost window and focused field are the ones it opened, holding the
/// fictional text it put there.
@MainActor
enum InlineSelfTest {
    static let flag = "--pflow-inline-selftest"

    static func start(arguments: [String]) {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { exit(2) }
        let folder = URL(fileURLWithPath: arguments[index + 1])
        let only = Set(arguments[(index + 2)...])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let report = await Runner(folder: folder, only: only).run()
            let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            try? data.write(to: folder.appendingPathComponent("results.json"))
            exit(0)
        }
        app.run()
    }
}

@MainActor
private final class Runner {
    let folder: URL
    let only: Set<String>
    var log: [String] = []

    init(folder: URL, only: Set<String>) {
        self.folder = folder
        self.only = only
    }

    func note(_ line: String) {
        log.append(line)
        try? log.joined(separator: "\n").write(to: folder.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }

    func wants(_ name: String) -> Bool { only.isEmpty || only.contains(name) }

    func run() async -> [String: Any] {
        // Never prompts: the plain check only reads the existing grant.
        var report: [String: Any] = ["trusted": AXIsProcessTrusted()]
        guard AXIsProcessTrusted() else {
            note("not trusted; nothing run")
            return report
        }
        var providers: [String: Any] = [:]
        if wants("textedit") { providers["textedit"] = await textEdit() }
        if wants("safari") { providers["safari"] = await safari() }
        if wants("vscode") { providers["vscode"] = await electron(bundle: "com.microsoft.VSCode", name: "vscode") }
        report["providers"] = providers
        return report
    }

    // MARK: Accessibility helpers (harness only)

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    func value(_ field: AXUIElement) -> String? { string(field, kAXValueAttribute) }

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

    @discardableResult
    func type(_ field: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func find(_ root: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(root) { return root }
        guard depth < 40 else { return nil }
        for child in children(root) {
            if let found = find(child, depth: depth + 1, match) { return found }
        }
        return nil
    }

    func focused(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        return element(app, kAXFocusedUIElementAttribute)
    }

    func windowTitle(_ pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        return element(app, kAXFocusedWindowAttribute).flatMap { string($0, kAXTitleAttribute) }
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.1)
        }
        return condition()
    }

    func frontmost() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func isOurs(_ pid: pid_t, _ field: AXUIElement) -> Bool {
        focused(pid).map { CFEqual($0, field) } == true
    }

    /// Brings `app` forward; a background app may be refused, so LaunchServices is asked next.
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

    /// Presses a menu item of `pid` only while its front window is ours.
    func pressMenu(_ pid: pid_t, menu: String, item: String, windowTitle expected: String) -> Bool {
        guard let title = windowTitle(pid), title.contains(expected) else {
            note("refused to press \(menu) > \(item): front window is not ours")
            return false
        }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = element(app, kAXMenuBarAttribute),
              let top = children(bar).first(where: { string($0, kAXTitleAttribute) == menu }),
              let list = children(top).first,
              let entry = children(list).first(where: { string($0, kAXTitleAttribute) == item }) else { return false }
        return AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success
    }

    func attributedFonts(_ field: AXUIElement, _ range: NSRange) -> [String] {
        var cf = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cf) else { return [] }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &result) == .success,
              let text = result as? NSAttributedString else { return [] }
        var fonts: [String] = []
        text.enumerateAttribute(NSAttributedString.Key("AXFontText"), in: NSRange(location: 0, length: text.length)) { value, run, _ in
            let name = (value as? [String: Any])?["AXFontName"] as? String ?? "none"
            fonts.append("\(run.location)+\(run.length):\(name)")
        }
        return fonts
    }

    // MARK: Scenarios

    enum Interruption: String { case none, userEdit, caretMove, appSwitch }

    struct Field {
        let app: NSRunningApplication
        let element: AXUIElement
        let windowTitle: String
    }

    /// Puts fictional text in our own field: select all, replace, place the caret.
    func reset(_ field: Field, to text: String, selection: NSRange) async -> Bool {
        guard await activate(field.app), windowTitle(field.app.processIdentifier)?.contains(field.windowTitle) == true,
              let current = value(field.element), isOurs(field.app.processIdentifier, field.element) else { return false }
        select(field.element, NSRange(location: 0, length: (current as NSString).length))
        type(field.element, text)
        await pause(0.2)
        select(field.element, selection)
        return await waitFor(2) { value(field.element) == text && self.selection(field.element) == selection }
    }

    func scenario(_ name: String, _ field: Field, initial: String, selection start: NSRange, updates: [String],
                  interrupt: Interruption = .none, at interruptAfter: Int = 2,
                  final: String?, expected: String?, expectedSelection: NSRange? = nil,
                  skipReset: Bool = false) async -> [String: Any] {
        var record: [String: Any] = ["name": name]
        if !skipReset {
            guard await reset(field, to: initial, selection: start) else {
                record["error"] = "harness could not set up the field"
                record["observed"] = value(field.element) ?? NSNull()
                note("\(name): setup failed")
                return record
            }
        }
        guard await activate(field.app), isOurs(field.app.processIdentifier, field.element),
              value(field.element) == initial else {
            record["error"] = "field not ours before begin"
            return record
        }
        let injector = TextInjector()
        injector.captureTarget()
        let session = UUID().uuidString
        var started = injector.beginLive(session: session)
        // As the coordinator does: an Electron or Chromium app was asked for its tree.
        var retries = 0
        while started == .waiting, retries < 30 {
            await pause(0.1)
            started = injector.retryLive(session: session)
            retries += 1
        }
        record["begin"] = "\(started)"
        if retries > 0 { record["beginRetries"] = retries }
        var stops: [String] = []
        var snapshots: [String] = []
        var afterInterruption: String?
        for (index, update) in updates.enumerated() {
            let begin = Date()
            if let stop = injector.reconcileLive(session: session, transcript: update) { stops.append("\(index):\(stop)") }
            record["update\(index)Ms"] = Int(Date().timeIntervalSince(begin) * 1000)
            snapshots.append(value(field.element) ?? "<unreadable>")
            if index == interruptAfter, interrupt != .none {
                switch interrupt {
                case .userEdit:
                    select(field.element, NSRange(location: 0, length: 0))
                    type(field.element, "Re: ")
                case .caretMove:
                    select(field.element, NSRange(location: 0, length: 0))
                case .appSwitch:
                    if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                        record["switched"] = await activate(finder)
                    }
                case .none: break
                }
                await pause(0.3)
                afterInterruption = value(field.element)
            }
            await pause(0.3)
        }
        if interrupt == .appSwitch { _ = await activate(field.app) }
        if let final {
            record["final"] = "\(injector.finalizeLive(session: session, text: final))"
        } else {
            record["cancel"] = "\(injector.cancelLive(session: session))"
        }
        await pause(0.3)
        let observed = value(field.element)
        record["stops"] = stops
        record["snapshots"] = snapshots
        record["observed"] = observed ?? NSNull()
        record["observedSelection"] = selection(field.element).map { [$0.location, $0.length] } ?? NSNull()
        if let afterInterruption {
            record["unchangedAfterInterruption"] = observed == afterInterruption
        }
        if let expected { record["matchesExpected"] = observed.map { Array($0.utf16) == Array(expected.utf16) } ?? false }
        if let expectedSelection { record["selectionRestored"] = selection(field.element) == expectedSelection }
        note("\(name): begin \(started) stops \(stops) final/cancel \(record["final"] ?? record["cancel"] ?? "") matches \(record["matchesExpected"] ?? "-")")
        return record
    }

    /// The standard set: revisions with Unicode and a multiline final, cancel,
    /// and each interruption. `multiline` false keeps single-line text.
    func standard(_ field: Field, multiline: Bool) async -> [[String: Any]] {
        let head = multiline ? "Dear Sam,\n\n" : "To Sam: "
        let tail = multiline ? "\nSee you soon." : " (draft)"
        let initial = head + tail
        let caret = NSRange(location: (head as NSString).length, length: 0)
        let updates = ["thanks for", "thanks for the nap", "thanks for the map and",
                       "thanks for the map 🗺️ and the", "thanks for the map 🗺️ and the cafe\u{301} 你好",
                       "thanks for the map 🗺️ and the cafe\u{301} 你好"]
        let final = multiline ? "Thanks for the map 🗺️ and the cafe\u{301}.\nWe leave at nine, 你好。"
                              : "Thanks for the map 🗺️ and the cafe\u{301}, 你好。"
        var results: [[String: Any]] = []
        results.append(await scenario("revisions-final", field, initial: initial, selection: caret, updates: updates,
                                      final: final, expected: head + final + tail))
        let picked = "Pack the old tent today"
        results.append(await scenario("selection-cancel", field, initial: picked, selection: NSRange(location: 9, length: 8),
                                      updates: ["new", "new canvas", "new canvas tarp"], final: nil, expected: picked,
                                      expectedSelection: NSRange(location: 9, length: 8)))
        for interruption in [Interruption.userEdit, .caretMove, .appSwitch] {
            results.append(await scenario(interruption.rawValue, field, initial: initial, selection: caret, updates: updates,
                                          interrupt: interruption, final: final, expected: nil))
        }
        return results
    }

    // MARK: TextEdit

    func open(_ files: [URL], bundle: String, arguments: [String] = [], newInstance: Bool = false) async -> NSRunningApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = newInstance
        return await withCheckedContinuation { continuation in
            if files.isEmpty {
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in continuation.resume(returning: app) }
            } else {
                NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration) { app, _ in continuation.resume(returning: app) }
            }
        }
    }

    func textEdit() async -> [String: Any] {
        var result: [String: Any] = [:]
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
        result["wasRunning"] = wasRunning
        let tag = String(UUID().uuidString.prefix(6))
        let plain = folder.appendingPathComponent("pflow-fictional-\(tag).txt")
        let rich = folder.appendingPathComponent("pflow-fictional-rich-\(tag).rtf")
        try? "Dear Sam,\n\nSee you soon.".write(to: plain, atomically: true, encoding: .utf8)
        let styled = NSMutableAttributedString(string: "Trip notes", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        styled.append(NSAttributedString(string: "\n\n\nPlain ending line.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        try? styled.rtf(from: NSRange(location: 0, length: styled.length), documentAttributes: [:])?.write(to: rich)
        // Fresh launch: do not restore any earlier TextEdit windows.
        let launchArguments = wasRunning ? [] : ["-ApplePersistenceIgnoreState", "YES"]
        for (kind, file) in [("plain", plain), ("rich", rich)] {
            guard let app = await open([file], bundle: "com.apple.TextEdit", arguments: launchArguments) else {
                result[kind] = ["error": "could not open TextEdit"]
                continue
            }
            let pid = app.processIdentifier
            let name = file.lastPathComponent
            let ready = await waitFor(10) {
                windowTitle(pid)?.contains(name.replacingOccurrences(of: ".txt", with: "").replacingOccurrences(of: ".rtf", with: "")) == true
                    && focused(pid).flatMap { string($0, kAXRoleAttribute) } == kAXTextAreaRole
            }
            guard ready, let element = focused(pid) else {
                result[kind] = ["error": "our document did not get focus", "window": windowTitle(pid) ?? ""]
                continue
            }
            let title = String(name.split(separator: ".").first ?? "")
            let field = Field(app: app, element: element, windowTitle: title)
            if kind == "plain" {
                result[kind] = await standard(field, multiline: true)
            } else {
                let initial = "Trip notes\n\n\nPlain ending line."
                let fontsBefore = (attributedFonts(element, NSRange(location: 0, length: 10)),
                                   attributedFonts(element, NSRange(location: 13, length: 18)))
                select(element, NSRange(location: 12, length: 0))
                var record = await scenario("rich-revisions-final", field, initial: initial, selection: NSRange(location: 12, length: 0),
                    updates: ["boats leave", "boats leave at dawn", "boats leave at dawn 🚤", "boats leave at dawn 🚤"],
                    final: "Boats leave at dawn 🚤.", expected: "Trip notes\n\nBoats leave at dawn 🚤.\nPlain ending line.",
                    skipReset: true)
                let shift = ("Boats leave at dawn 🚤." as NSString).length
                let fontsAfter = (attributedFonts(element, NSRange(location: 0, length: 10)),
                                  attributedFonts(element, NSRange(location: 13 + shift, length: 18)))
                record["boldTitleKept"] = fontsBefore.0 == fontsAfter.0 && !fontsAfter.0.isEmpty
                record["endingStyleKept"] = fontsBefore.1 == fontsAfter.1 && !fontsAfter.1.isEmpty
                record["fonts"] = ["before": [fontsBefore.0, fontsBefore.1], "after": [fontsAfter.0, fontsAfter.1]]
                result[kind] = [record]
            }
            result["\(kind)Closed"] = pressMenu(pid, menu: "File", item: "Close", windowTitle: title)
            await pause(1)
        }
        if !wasRunning, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first {
            result["quit"] = app.terminate()
        }
        return result
    }

    // MARK: Safari

    func safari() async -> [String: Any] {
        var result: [String: Any] = [:]
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
        result["wasRunning"] = wasRunning
        let tag = String(UUID().uuidString.prefix(6))
        let title = "pFlow fictional form \(tag)"
        let page = folder.appendingPathComponent("pflow-form-\(tag).html")
        let html = """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <p><input id="line" aria-label="Fictional line" size="60" autofocus></p>
        <p><textarea id="notes" aria-label="Fictional notes" rows="8" cols="60"></textarea></p>
        """
        try? html.write(to: page, atomically: true, encoding: .utf8)
        guard let app = await open([page], bundle: "com.apple.Safari") else { return ["error": "could not open Safari"] }
        let pid = app.processIdentifier
        guard await waitFor(15, { windowTitle(pid)?.contains(title) == true }), await activate(app) else {
            return ["error": "our tab did not come to the front", "window": windowTitle(pid) ?? ""]
        }
        let window = AXUIElementCreateApplication(pid)
        func control(_ label: String) -> AXUIElement? {
            guard let front = element(window, kAXFocusedWindowAttribute) else { return nil }
            return find(front) { string($0, kAXDescriptionAttribute) == label || string($0, kAXTitleAttribute) == label }
        }
        for (kind, label, multiline) in [("input", "Fictional line", false), ("textarea", "Fictional notes", true)] {
            guard let target = control(label) else {
                result[kind] = ["error": "could not find \(label)"]
                continue
            }
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard await waitFor(3, { isOurs(pid, target) }) else {
                result[kind] = ["error": "\(label) did not take focus", "role": focused(pid).flatMap { string($0, kAXRoleAttribute) } ?? ""]
                continue
            }
            result[kind] = await standard(Field(app: app, element: target, windowTitle: title), multiline: multiline)
        }
        result["closed"] = pressMenu(pid, menu: "File", item: "Close Tab", windowTitle: title)
        return result
    }

    // MARK: Electron

    func electron(bundle: String, name: String) async -> [String: Any] {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else { return ["error": "not installed"] }
        let data = folder.appendingPathComponent("\(name)-data")
        let file = folder.appendingPathComponent("pflow-fictional-\(name).txt")
        try? "Dear Sam,\n\nSee you soon.".write(to: file, atomically: true, encoding: .utf8)
        // A separate profile in the scratch folder: no earlier windows, settings or extensions.
        let arguments = ["--user-data-dir", data.path, "--extensions-dir", data.appendingPathComponent("ext").path,
                         "--disable-extensions", "--disable-workspace-trust", "--skip-welcome", "--skip-release-notes",
                         "--new-window", file.path]
        guard let app = await open([], bundle: bundle, arguments: arguments, newInstance: true) else { return ["error": "could not launch"] }
        var result: [String: Any] = ["pid": Int(app.processIdentifier)]
        let pid = app.processIdentifier
        let ready = await waitFor(25) { windowTitle(pid)?.contains(file.lastPathComponent) == true }
        _ = await activate(app)
        await pause(2)
        result["windowReady"] = ready
        result["focusedRoleBeforeAsk"] = focused(pid).flatMap { string($0, kAXRoleAttribute) } ?? "none"
        // What TextInjector.beginLive does for this app, done here first so the
        // harness can read the fictional text the scenario starts from.
        result["treeAsked"] = WebAppAccessibility.enable(app)
        let askedAt = Date()
        let readable = await waitFor(5) { focused(pid).flatMap { value($0) } != nil }
        result["treeReadyMs"] = readable ? Int(Date().timeIntervalSince(askedAt) * 1000) : -1
        let focus = focused(pid)
        result["focusedRole"] = focus.flatMap { string($0, kAXRoleAttribute) } ?? "none"
        result["focusedValueReadable"] = readable
        if ready, readable, let focus {
            // Same production path; whatever pFlow decides here is the result.
            let field = Field(app: app, element: focus, windowTitle: file.lastPathComponent)
            result["scenarios"] = [await scenario("revisions-final", field, initial: value(focus) ?? "",
                selection: selection(focus) ?? NSRange(location: 0, length: 0),
                updates: ["thanks for", "thanks for the map", "thanks for the map 🗺️ and"],
                final: "Thanks for the map 🗺️.", expected: nil, skipReset: true)]
        } else if ready {
            let injector = TextInjector()
            injector.captureTarget()
            let session = UUID().uuidString
            var started = injector.beginLive(session: session)
            var retries = 0
            while started == .waiting, retries < 30 {
                await pause(0.1)
                started = injector.retryLive(session: session)
                retries += 1
            }
            result["begin"] = "\(started)"
            result["beginRetries"] = retries
        }
        app.terminate()
        let quit = await waitFor(8, { app.isTerminated })
        if !quit {
            // Only this scratch instance, launched above with its own profile.
            app.forceTerminate()
        }
        result["quit"] = app.isTerminated
        return result
    }
}
#endif
