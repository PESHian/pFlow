import ApplicationServices
import Foundation

/// A place pFlow never types or pastes into.
enum NoTypePlace: Equatable {
    /// A line break would run a command.
    case terminal
    /// The keys would go to another computer or a virtual machine.
    case remote
}

/// The one list of places pFlow never types or pastes into, by app and by the
/// focused element's web classes (a terminal inside an editor or a page).
enum NoTypePlaces {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "dev.warp.Warp-Preview", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "com.mitchellh.ghostty", "org.tabby",
    ]
    static let remotes: Set<String> = [
        "com.microsoft.rdc.macos", "com.microsoft.rdc.mac", "com.microsoft.rdc.osx.beta",
        "com.apple.ScreenSharing", "com.realvnc.vncviewer", "com.teamviewer.TeamViewer",
        "com.anydesk.anydeskmacos", "com.parallels.desktop.console", "com.vmware.fusion",
        "com.utmapp.UTM", "org.virtualbox.app.VirtualBoxVM", "com.github.cirruslabs.tart",
        "com.citrix.receiver.icaviewer.mac", "tv.parsec.www",
    ]
    /// xterm.js's input box: VS Code's terminal panel and web terminals.
    static let terminalElementClasses: Set<String> = ["xterm-helper-textarea"]

    static func place(bundleID: String?, elementClasses: [String]) -> NoTypePlace? {
        if let bundleID, terminals.contains(bundleID) { return .terminal }
        if elementClasses.contains(where: terminalElementClasses.contains) { return .terminal }
        if let bundleID, remotes.contains(bundleID) { return .remote }
        return nil
    }
}

/// What pFlow saw right before a paste or a batch of typed keys. The slow
/// reads (Accessibility) are taken first, the fast ones last.
struct InsertionFacts: Equatable {
    var place: NoTypePlace?
    /// The captured app is still frontmost and active.
    var sameApp = true
    /// Its focused element is still the captured one.
    var sameField = true
    /// The focused element is a password field.
    var password = false
    /// Another app holds Secure Event Input.
    var secureInput = false
    /// Command, Shift, Option, Control or Fn is down.
    var modifiersHeld = false
    /// A key or mouse button is physically down.
    var keyDown = false
    /// The person pressed a key or clicked since these checks began.
    var personActed = false
    /// An input method may be composing text (InputComposition).
    var composing = false
}

/// The one rule over those facts, for the final paste, the end replace and
/// every live key batch alike: the first reason not to send anything, or nil.
enum InsertionGuard {
    static func block(_ facts: InsertionFacts) -> InsertionBlock? {
        if let place = facts.place { return place == .terminal ? .terminal : .remoteViewer }
        if !facts.sameApp { return .appChanged }
        if !facts.sameField { return .fieldChanged }
        if facts.password { return .passwordField }
        if facts.secureInput { return .secureInput }
        if facts.modifiersHeld { return .interrupted }
        if facts.keyDown || facts.personActed { return .personActed }
        if facts.composing { return .inputMethod }
        return nil
    }
}

/// Whether an input method is composing text in the field (Japanese,
/// Chinese, Korean), the same rule as Windows 0.1.28: only a real composition
/// counts, never the keyboard language alone. AppKit fields say so directly
/// (AXTextInputMarkedRange, length > 0 while composing); elsewhere (Chrome,
/// Electron) a composing input method is selected and the person pressed a
/// key that continues a composition, with no commit key or click since and
/// not long ago (PersonInput). A paste then could commit or mix with the
/// person's unfinished characters.
enum InputComposition {
    /// Keys that end a composition: Return, keypad Enter, Escape, Tab, Space
    /// (Pinyin and Korean commit with it), the candidate digits 1-9 and
    /// punctuation.
    static let commitKeys: Set<Int64> = [36, 76, 53, 48, 49,
                                         18, 19, 20, 21, 23, 22, 26, 28, 25,
                                         43, 47, 44, 41, 39, 33, 30, 27, 24, 50, 42]

    /// `markedLength` is the field's marked text length when it reports one, nil when it cannot say.
    static func composing(markedLength: Int?, inputMethod: Bool, uncommittedKeys: Bool) -> Bool {
        if let markedLength { return markedLength > 0 }
        return inputMethod && uncommittedKeys
    }
}

/// How live words reach a field while the take is spoken.
enum LiveFieldMethod: Equatable {
    /// Accessibility range writes, read back after each one (native text views).
    case ranges
    /// Typed characters, append only, the way a person's typing would go in;
    /// pFlow's own words are replaced by the finished text at the end.
    case keys

    /// Web content (Safari, Chrome, Electron apps) accepts an Accessibility
    /// text write without showing it (trusted VM, macOS 27: absent after 2 s
    /// in Safari and Chrome fields and VS Code); native text views, Notes and
    /// LibreOffice's document show it at once. Word takes typed keys too.
    static let keyApps: Set<String> = ["com.microsoft.Word"]

    /// Typed live keys only while the person's own keys and clicks are
    /// watched (else a key of theirs could land between pFlow's checks and
    /// keys unseen) and no input method that composes is selected (it could
    /// turn typed characters into a composition).
    static func keysAllowed(watching: Bool, inputMethod: Bool) -> Bool { watching && !inputMethod }

    static func method(webApp: Bool, bundleID: String?) -> LiveFieldMethod {
        if webApp { return .keys }
        if let bundleID, keyApps.contains(bundleID) { return .keys }
        return .ranges
    }
}

/// pFlow's own live words at the end of a take, selected without a key for the
/// finished text to go over them.
struct OwnedWords: Equatable {
    let range: NSRange
    let text: String
    /// The person pressed a key or clicked since the select, or nobody can say
    /// they did not: nothing goes over the selection then.
    let personActed: () -> Bool
    /// Ends pFlow's selection without a key, caret at its end.
    let collapse: () -> Void

    /// Nil when the field's one selection is exactly pFlow's words in place;
    /// otherwise why not. A no-break space counts as a space (browsers show a
    /// typed space at a line end as one).
    func mismatch(value: String?, selection: NSRange?) -> String? {
        guard let value, let selection else { return "the field could not be read" }
        guard selection == range else { return "the selection moved" }
        let field = value as NSString
        guard NSMaxRange(range) <= field.length else { return "the field is shorter than pFlow's words" }
        return Self.plain(field.substring(with: range)) == Self.plain(text) ? nil : "the selected text is not pFlow's words"
    }

    private static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{00A0}", with: " ") }

    static func == (a: OwnedWords, b: OwnedWords) -> Bool { a.range == b.range && a.text == b.text }
}

/// The one way pFlow finds the field the person is typing in, in another app.
@MainActor
enum FocusedElement {
    /// Apps that report no focused element although their document has the
    /// caret (LibreOffice): the focused window's text area stands in for it.
    static let windowTextAreaApps: Set<String> = ["org.libreoffice.script"]

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func of(pid: pid_t, bundleID: String?) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        if let focused = element(app, kAXFocusedUIElementAttribute) { return focused }
        guard let bundleID, windowTextAreaApps.contains(bundleID), let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        return textArea(in: window)
    }

    /// The first text area with a caret, breadth first, looking at no more than 300 elements.
    private static func textArea(in window: AXUIElement) -> AXUIElement? {
        var queue = [window], seen = 0
        while !queue.isEmpty, seen < 300 {
            let next = queue.removeFirst()
            seen += 1
            if attribute(next, kAXRoleAttribute) as? String == kAXTextAreaRole,
               attribute(next, kAXSelectedTextRangeAttribute) != nil { return next }
            queue += (attribute(next, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }

    /// The element sits in web content (Safari, Mail, Chrome, Electron), where
    /// an Accessibility text write is accepted but not shown.
    static func inWebArea(_ start: AXUIElement) -> Bool {
        var current: AXUIElement? = start
        for _ in 0..<40 {
            guard let node = current else { return false }
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { return true }
            current = element(node, kAXParentAttribute)
        }
        return false
    }

    /// The field's marked (composing) text length, when it reports one (AppKit).
    static func markedLength(_ element: AXUIElement) -> Int? {
        guard let raw = attribute(element, "AXTextInputMarkedRange"), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range.length : nil
    }

    /// Web classes of fields whose text Accessibility does not show (VS Code's
    /// editor reads as empty whatever it holds): pasted, never typed live.
    static let unreadableClasses: Set<String> = ["native-edit-context"]

    static func unreadable(_ element: AXUIElement) -> Bool {
        ((attribute(element, "AXDOMClassList") as? [String]) ?? []).contains(where: unreadableClasses.contains)
    }
}
