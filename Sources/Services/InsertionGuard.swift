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
/// Electron) the key tracker decides (CompositionTracker). A paste then could
/// commit or mix with the person's unfinished characters.
enum InputComposition {
    /// `markedLength` is the field's marked text length when it reports one, nil when it cannot say.
    static func composing(markedLength: Int?, tracked: Bool) -> Bool {
        if let markedLength { return markedLength > 0 }
        return tracked
    }
}

/// Input method families, by input source ID; each ends a composition with its own keys.
enum InputMethodFamily: Equatable {
    /// `phonetic`: Vietnamese (Telex, VNI, VIQR), Hindi transliteration.
    case japanese, chinese, korean, phonetic, other

    static func of(sourceID: String) -> InputMethodFamily {
        let id = sourceID.lowercased()
        if id.contains("kotoeri") || id.contains("japanese") || id.contains("atok") { return .japanese }
        if id.contains("korean") || id.contains("hangul") { return .korean }
        if id.contains("rime") || id.contains("squirrel") || id.contains("cantonese") || id.contains("jyutping") { return .chinese }
        if id.contains("vietnamese") || id.contains("telex") || id.contains("vni") || id.contains("viqr")
            || id.contains("transliteration") || id.contains("hindi") { return .phonetic }
        if id.contains(".scim") || id.contains(".tcim") || id.contains("pinyin") || id.contains("zhuyin")
            || id.contains("chinese") || id.contains("wubi") || id.contains("cangjie") || id.contains("sogou")
            || id.contains("stroke") { return .chinese }
        return .other
    }
}

/// Key codes the tracker treats specially.
enum CompositionKeys {
    static let `return`: Int64 = 36, enter: Int64 = 76, escape: Int64 = 53, space: Int64 = 49
    /// 1-9 (candidate picks in Chinese input methods).
    static let digits: Set<Int64> = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    static let punctuation: Set<Int64> = [43, 47, 44, 41, 39, 33, 30, 27, 24, 50, 42]
    static let arrows: Set<Int64> = [123, 124, 125, 126]
    /// Backspace, forward delete, arrows, Home, End, Page Up, Page Down: they
    /// edit or move inside a composition but never start one.
    static let navigation: Set<Int64> = Set<Int64>([51, 117, 115, 119, 116, 121]).union(arrows)

    /// The keys that end a composition in this family: only keys that do so
    /// in every input method of the family; when unsure, none (the take is
    /// refused and the Copy card offers the text). Kotoeri converts with
    /// Space and keeps digits and punctuation; Chinese input methods commit
    /// with Space or a candidate digit, but Rime and Pinyin page with - and =,
    /// so no punctuation; Korean ends a syllable with Space, punctuation or
    /// an arrow; Vietnamese (VIQR tone marks ' . - `, Telex [ ]) and Hindi
    /// transliteration end a word with Space only. Unknown: Return and Escape.
    static func commits(_ key: Int64, in family: InputMethodFamily) -> Bool {
        if key == `return` || key == enter || key == escape { return true }
        switch family {
        case .japanese, .other: return false
        case .chinese: return key == space || digits.contains(key)
        case .korean: return key == space || punctuation.contains(key) || arrows.contains(key)
        case .phonetic: return key == space
        }
    }
}

/// What the person's keys say about a composition outside AppKit fields.
/// Each key is kept with the input source that was selected when it was
/// pressed (read on the main thread right after the key) since the last
/// universal end (Return, Enter, Escape, a committing click). At a take's
/// start and at the final check the keys are read with the input source
/// selected *then*: keys typed under another source belong to before a switch
/// (switching ends a composition), and with a plain layout selected there is
/// no composition to protect. No notification decides anything.
///
/// No time limit runs during a take: the state at the take's start is kept,
/// and the end of the take refuses until a real commit is seen. Before a take
/// a composition left alone for `preTakeExpiry` no longer counts: dictation is
/// started by the person, and a minute is far longer than anyone leaves a
/// half-typed word open and then starts dictating into the same field
/// (Windows 0.1.28 reads the open composition itself; this is the stand-in).
struct CompositionTracker: Equatable {
    static let preTakeExpiry: UInt64 = 60_000_000_000
    /// Keys kept at most (a word being composed is far shorter).
    static let keptKeys = 200

    struct Key: Equatable {
        let code: Int64
        let at: UInt64
        /// The input source ID selected for this key ("" a plain layout); nil until read.
        var source: String?
    }

    /// Keys since the last universal end, in order.
    private(set) var keys: [Key] = []
    /// When a composition last ended for every input method (Return, Escape, a click).
    private(set) var lastEnd: UInt64 = 0

    /// A key the person pressed. Shortcuts (Command or Control held) are never part of a composition.
    mutating func key(_ code: Int64, shortcut: Bool, at time: UInt64, source: String? = nil) {
        if shortcut { return }
        if code == CompositionKeys.return || code == CompositionKeys.enter || code == CompositionKeys.escape {
            end(at: time)
            return
        }
        keys.append(Key(code: code, at: time, source: source))
        if keys.count > Self.keptKeys { keys.removeFirst(keys.count - Self.keptKeys) }
    }

    /// The input source read for the key pressed at `time`. A key typed
    /// with a plain layout (source "") can be part of no composition and is
    /// not kept.
    mutating func stamp(at time: UInt64, source: String) {
        guard let index = keys.lastIndex(where: { $0.at == time && $0.source == nil }) else { return }
        if source.isEmpty { keys.remove(at: index) } else { keys[index].source = source }
    }

    /// Keys that may belong to an open composition (typed under an input
    /// method, or not read yet). Only then is a click's window looked up.
    var mayBeComposing: Bool { keys.contains { $0.source != "" } }

    /// A click that commits (anywhere but the input method's own candidate window).
    mutating func click(commits: Bool, at time: UInt64) {
        if commits { end(at: time) }
    }

    mutating func end(at time: UInt64) {
        if !keys.isEmpty { lastEnd = time }
        keys.removeAll()
    }

    /// The kept keys read for the input source selected now (nil: a plain
    /// layout): when a composition was last started or continued (nil when
    /// none is open) and when one last ended.
    func replay(sourceID: String?) -> (since: UInt64?, lastCommit: UInt64) {
        guard let sourceID else { return (nil, lastEnd) }
        let family = InputMethodFamily.of(sourceID: sourceID)
        // Only keys after the last one typed under another source (a switch since).
        let start = (keys.lastIndex { $0.source != nil && $0.source != sourceID }).map { $0 + 1 } ?? 0
        var since: UInt64?
        var lastCommit = start > 0 ? max(lastEnd, keys[start - 1].at) : lastEnd
        for key in keys[start...] {
            if CompositionKeys.commits(key.code, in: family) {
                if since != nil { lastCommit = key.at }
                since = nil
            } else if CompositionKeys.navigation.contains(key.code) {
                if since != nil { since = key.at }
            } else {
                since = key.at
            }
        }
        return (since, lastCommit)
    }

    /// At the start of a take: a composition is open (and not stale) for the input source selected now.
    func snapshot(at time: UInt64, sourceID: String?) -> Bool {
        guard let since = replay(sourceID: sourceID).since else { return false }
        return time >= since && time - since < Self.preTakeExpiry
    }

    /// During and at the end of a take, with no time limit: composing when it
    /// was at the start and no commit was seen since, or when one began after
    /// the start. Never with a plain layout selected now.
    func composing(snapshot: Bool, takeStart: UInt64, sourceID: String?) -> Bool {
        guard sourceID != nil else { return false }
        let state = replay(sourceID: sourceID)
        if snapshot, state.lastCommit < takeStart { return true }
        if let since = state.since, since >= takeStart { return true }
        return false
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
