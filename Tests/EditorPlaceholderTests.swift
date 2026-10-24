import AppKit
import Testing
@testable import Yap

/// An empty rich-text editor read through Accessibility: it shows a
/// placeholder until the first character lands, then drops it or keeps it
/// at one end, the way T3 Code (ProseMirror), Tiptap, Lexical, Slate and
/// Gmail's compose body do. Keys typed land at the caret.
@MainActor
final class EditorReader: KeyFieldReader {
    enum Shape { case drops, keepsTrailing, keepsLeading }
    var raw: String
    var selection: NSRange
    let shape: Shape
    let placeholderText: String?
    /// Decided once, from what the field held when the take began (as TextInjector does).
    let placeholder: EditorPlaceholder.Start?
    var selects: [NSRange] = []

    init(_ raw: String, caret: Int, shape: Shape = .drops, placeholderText: String? = nil, markedEmpty: Bool = false,
         webContent: Bool = true) {
        self.raw = raw
        selection = NSRange(location: caret, length: 0)
        self.shape = shape
        placeholder = EditorPlaceholder.start(value: raw, placeholderText: placeholderText, markedEmpty: markedEmpty,
                                              webContent: webContent)
        self.placeholderText = placeholder?.text
    }

    func type(_ text: String) {
        if shape == .drops, EditorPlaceholder.only(raw, placeholderText: placeholderText) {
            raw = ""
            selection = NSRange(location: 0, length: 0)
        }
        raw = (raw as NSString).replacingCharacters(in: selection, with: text)
        selection = NSRange(location: selection.location + (text as NSString).length, length: 0)
    }

    func state() -> LiveFieldState {
        let state = LiveFieldState(app: 1, element: LiveFieldState.target, secure: false, trusted: true,
                                   value: raw, selection: selection)
        return placeholder == nil ? state : EditorPlaceholder.seen(state, placeholderText: placeholderText)
    }

    func select(_ range: NSRange) -> Bool {
        let field = placeholder == nil ? range : EditorPlaceholder.fieldRange(range, raw: raw, placeholderText: placeholderText)
        selects.append(field)
        selection = field
        return true
    }

    func selectionSettable() -> Bool { true }
}

/// A native AppKit field written with direct Accessibility range writes, as
/// AXLiveTextField does: the placeholder decision is the production one
/// (`EditorPlaceholder.start`, not web content), and a direct write is
/// refused under a placeholder view.
@MainActor
final class NativeRangeField: LiveTextField {
    var raw: String
    var selection: NSRange
    let placeholderText: String?
    let placeholder: EditorPlaceholder.Start?

    init(_ raw: String, caret: Int, placeholderText: String? = nil) {
        self.raw = raw
        selection = NSRange(location: caret, length: 0)
        self.placeholderText = placeholderText
        placeholder = EditorPlaceholder.start(value: raw, placeholderText: placeholderText, markedEmpty: false, webContent: false)
    }

    func state() -> LiveFieldState {
        let state = LiveFieldState(app: 1, element: LiveFieldState.target, secure: false, trusted: true, value: raw, selection: selection)
        return placeholder == nil ? state : EditorPlaceholder.seen(state, placeholderText: placeholder?.text)
    }
    func canWriteRanges() -> Bool { true }
    func replace(_ range: NSRange, with text: String) -> Bool {
        guard placeholder == nil else { return false }
        raw = (raw as NSString).replacingCharacters(in: range, with: text)
        selection = NSRange(location: range.location + (text as NSString).length, length: 0)
        return true
    }
    func select(_ range: NSRange) -> Bool { selection = range; return true }
}

@MainActor
struct EditorPlaceholderTests {
    private func nativeTake(_ field: NativeRangeField) -> LiveInlineFinal {
        guard case .success(let session) = LiveInlineSession.begin(id: "n", field: field, settle: {}) else {
            return .kept(.unsupported)
        }
        for words in ["the harbor", "the harbor lights", "the harbor lights glow", "the harbor lights glow softly"] {
            if let stop = session.update(words) { return .kept(stop) }
        }
        return session.finalize("The harbor lights glow softly.")
    }

    /// The rule applies only in web content; native fields never report a placeholder as their value.
    @Test func thePlaceholderRuleAppliesOnlyInWebContent() {
        #expect(EditorPlaceholder.start(value: "\n", placeholderText: nil, markedEmpty: false, webContent: true) != nil)
        #expect(EditorPlaceholder.start(value: "Reply", placeholderText: "Reply", markedEmpty: false, webContent: true) != nil)
        #expect(EditorPlaceholder.start(value: "Write a message\n", placeholderText: nil, markedEmpty: true, webContent: true) != nil)
        #expect(EditorPlaceholder.start(value: "\n", placeholderText: nil, markedEmpty: false, webContent: false) == nil,
                "a native line break is the person's")
        #expect(EditorPlaceholder.start(value: "Search", placeholderText: "Search", markedEmpty: false, webContent: false) == nil,
                "native text equal to the placeholder is typed text")
        #expect(EditorPlaceholder.start(value: "Dear Sam,", placeholderText: nil, markedEmpty: false, webContent: true) == nil)
    }

    /// TextEdit: the person pressed Return, then dictates. The words go on line 2, where the caret is.
    @Test func aNativeLineBreakIsRealTextAndTheWordsGoAtTheCaret() {
        let field = NativeRangeField("\n", caret: 1)
        #expect(nativeTake(field) == .applied)
        #expect(field.raw.hasPrefix("\n"), "the person's line break stays first: \(field.raw.debugDescription)")
        #expect(field.raw.dropFirst().hasPrefix("The harbor lights glow softly"))
        #expect(field.raw.components(separatedBy: "harbor").count == 2, "once")
    }

    /// A native field whose text equals its placeholder: the text is the person's and stays before the words.
    @Test func nativeTextEqualToThePlaceholderIsKept() {
        let field = NativeRangeField("Search", caret: 6, placeholderText: "Search")
        #expect(nativeTake(field) == .applied)
        #expect(field.raw.hasPrefix("Search "), "\(field.raw.debugDescription)")
        #expect(field.raw.components(separatedBy: "harbor").count == 2, "once")
    }

    /// The finished check never calls a read that looks the same as before a landing.
    @Test func aReadThatLooksAsBeforeIsNeverLanded() {
        // Placeholder "Reply" and the words "Reply": the field reads "Reply" either way.
        #expect(!EditorPlaceholder.landed("Reply", expected: "Reply", start: "Reply", startedAsPlaceholder: true))
        #expect(!EditorPlaceholder.landed("Reply\n", expected: "Reply", start: "Reply\n", startedAsPlaceholder: true))
        // A real change: Chromium's read-out placeholder had a line break, the words do not.
        #expect(EditorPlaceholder.landed("Reply", expected: "Reply", start: "Reply\n", startedAsPlaceholder: true))
        // The words a prefix of the placeholder, and the placeholder a prefix of the words.
        #expect(!EditorPlaceholder.landed("Reply", expected: "Rep", start: "Reply", startedAsPlaceholder: true))
        #expect(EditorPlaceholder.landed("Rep", expected: "Rep", start: "Reply", startedAsPlaceholder: true))
        #expect(!EditorPlaceholder.landed("Reply", expected: "Reply now", start: "Reply", startedAsPlaceholder: true))
        #expect(EditorPlaceholder.landed("Reply now", expected: "Reply now", start: "Reply", startedAsPlaceholder: true))
        // Native: a selected word replaced by the same word cannot be seen to land.
        #expect(!EditorPlaceholder.landed("Dear Reply,", expected: "Dear Reply,", start: "Dear Reply,", startedAsPlaceholder: false))
        #expect(EditorPlaceholder.landed("Dear Sam, Reply", expected: "Dear Sam, Reply", start: "Dear Sam,", startedAsPlaceholder: false))
    }

    /// Web placeholder "Reply" and the spoken word "Reply": the typed key lands
    /// and the field reads as before. Typing stops as unconfirmed, the take counts
    /// as typed (no second copy by paste), and the card offers the text.
    @Test func webWordsEqualToThePlaceholderAreNeverConfirmedAndNeverPastedAgain() {
        let reader = EditorReader("Reply", caret: 0, shape: .drops, placeholderText: "Reply")
        let watch = PersonInput(isTrusted: { false })
        watch.overrideWatching(true)
        let field = KeyLiveTextField(reader: reader, pid: 1, facts: { _ in InsertionFacts() }, watch: watch,
                                     inputMethod: { false }, send: { reader.type($0); return true })
        guard case .success(let session) = LiveInlineSession.begin(id: "r", field: field, settle: {}) else {
            Issue.record("begin refused"); return
        }
        _ = session.update("Reply")
        _ = session.update("Reply")
        #expect(reader.raw == "Reply", "the key went out and landed")
        #expect(session.touched, "the take counts as typed")
        guard case .kept = session.finalize("Reply") else { Issue.record("not kept: a second copy would be pasted"); return }
    }

    /// One take of typed live words, then the end: pFlow's own words selected for the checked paste.
    private func take(_ reader: EditorReader) -> LiveInlineFinal {
        let watch = PersonInput(isTrusted: { false })
        watch.overrideWatching(true)
        let field = KeyLiveTextField(reader: reader, pid: 1, facts: { _ in InsertionFacts() }, watch: watch,
                                     inputMethod: { false }, send: { reader.type($0); return true })
        guard case .success(let session) = LiveInlineSession.begin(id: "t", field: field, settle: {}) else {
            return .kept(.unsupported)
        }
        for words in ["the harbor", "the harbor lights", "the harbor lights glow", "the harbor lights glow softly"] {
            if let stop = session.update(words) { return .kept(stop) }
        }
        return session.finalize("The harbor lights glow softly.")
    }

    @Test func whatCountsAsOnlyAPlaceholder() {
        #expect(EditorPlaceholder.only("\n", placeholderText: nil))
        #expect(EditorPlaceholder.only("\u{200B}", placeholderText: nil))
        #expect(EditorPlaceholder.only("\u{FEFF}\n", placeholderText: nil))
        #expect(EditorPlaceholder.only("Write a message", placeholderText: "Write a message"))
        #expect(!EditorPlaceholder.only("", placeholderText: nil), "empty is simply empty")
        #expect(!EditorPlaceholder.only(" ", placeholderText: nil), "a space is the person's")
        #expect(!EditorPlaceholder.only("Dear Sam,\n", placeholderText: nil))
        #expect(!EditorPlaceholder.only("Dear Sam,", placeholderText: "Write a message"))
        #expect(!EditorPlaceholder.only("Write", placeholderText: ""))
    }

    /// T3 Code: the empty composer reads "\n" and drops it when the first key lands.
    /// 0.3.14 stopped after the first words ("could not check") and kept the final out.
    @Test func anEditorThatDropsItsLineBreakIsTypedIntoAndReplacedOnce() {
        let reader = EditorReader("\n", caret: 0, shape: .drops)
        guard case .replace(let own) = take(reader) else { Issue.record("typing stopped in an empty editor"); return }
        #expect(reader.raw == "the harbor lights glow")
        #expect(own.text == "the harbor lights glow")
        #expect(reader.selects.last == NSRange(location: 0, length: 22))
        #expect(own.mismatch(value: reader.state().value, selection: reader.state().selection) == nil)
    }

    @Test func anEditorThatKeepsItsLineBreakAfterTheWords() {
        let reader = EditorReader("\n", caret: 0, shape: .keepsTrailing)
        guard case .replace(let own) = take(reader) else { Issue.record("typing stopped"); return }
        #expect(reader.raw == "the harbor lights glow\n")
        #expect(reader.selects.last == NSRange(location: 0, length: 22))
        #expect(own.mismatch(value: reader.state().value, selection: reader.state().selection) == nil)
    }

    /// A zero-width space kept before the words: the select lands one unit in.
    @Test func anEditorThatKeepsAZeroWidthSpaceBeforeTheWords() {
        let reader = EditorReader("\u{200B}", caret: 1, shape: .keepsLeading)
        guard case .replace = take(reader) else { Issue.record("typing stopped"); return }
        #expect(reader.raw == "\u{200B}the harbor lights glow")
        #expect(reader.selects.last == NSRange(location: 1, length: 22))
    }

    /// Slate and some others read as their placeholder text until a key lands.
    @Test func anEditorThatReadsAsItsPlaceholderText() {
        let reader = EditorReader("Write a message", caret: 0, shape: .drops, placeholderText: "Write a message")
        guard case .replace = take(reader) else { Issue.record("typing stopped"); return }
        #expect(reader.raw == "the harbor lights glow")
    }

    /// Tiptap in Chromium: its CSS placeholder reads out as text, then a line break.
    @Test func anEditorThatMarksItselfEmptyReadsAsItsCSSPlaceholder() {
        let reader = EditorReader("Write a message\n", caret: 0, shape: .drops, markedEmpty: true)
        guard case .replace = take(reader) else { Issue.record("typing stopped"); return }
        #expect(reader.raw == "the harbor lights glow")
        #expect(EditorPlaceholder.start(value: "Write a message\n", placeholderText: nil, markedEmpty: false, webContent: true) == nil,
                "unmarked text is real text")
    }

    /// The placeholder text staying next to pFlow's words is not "only ours": stop.
    @Test func placeholderTextLeftBesideTheWordsStopsTyping() {
        let reader = EditorReader("Write a message", caret: 15, shape: .keepsTrailing, placeholderText: "Write a message")
        guard case .kept = take(reader) else { Issue.record("typed beside text that was not pFlow's"); return }
    }

    /// The finished-text check after a paste or an Accessibility write.
    @Test func theLandCheckAfterAPlaceholderDemandsTheWordsExactlyOnce() {
        #expect(EditorPlaceholder.same("The harbor.", "The harbor.\n", startedAsPlaceholder: true))
        #expect(EditorPlaceholder.same("\u{200B}The harbor.", "The harbor.", startedAsPlaceholder: true))
        #expect(!EditorPlaceholder.same("\n", "The harbor.\n", startedAsPlaceholder: true), "words missing")
        #expect(!EditorPlaceholder.same("", "The harbor.", startedAsPlaceholder: true), "words missing")
        #expect(!EditorPlaceholder.same("The harbor.The harbor.", "The harbor.", startedAsPlaceholder: true), "twice")
        #expect(!EditorPlaceholder.same("The harbor", "The harbor.", startedAsPlaceholder: true), "a character lost")
    }

    /// A field with real text keeps the exact check: a lone extra line break
    /// never stands in for pFlow's words, and the person's own line break may
    /// not go missing.
    @Test func aFieldWithRealTextKeepsTheExactCheck() {
        let start = "Dear Sam,\n"
        let placeholder = EditorPlaceholder.only(start, placeholderText: nil)
        #expect(!placeholder)
        #expect(!EditorPlaceholder.same("Dear Sam,\n", "Dear Sam, The harbor.", startedAsPlaceholder: placeholder))
        #expect(!EditorPlaceholder.same("Dear Sam, The harbor.", "Dear Sam, The harbor.\n", startedAsPlaceholder: placeholder),
                "the person's line break went missing")
        #expect(EditorPlaceholder.same("Dear Sam,\u{00A0}The harbor.\n", "Dear Sam, The harbor.\n", startedAsPlaceholder: placeholder))
        // Live typing in the same field: the editor shows a lone extra line break and none of pFlow's words.
        let reader = EditorReader(start, caret: 9, shape: .keepsTrailing)
        let watch = PersonInput(isTrusted: { false })
        watch.overrideWatching(true)
        let field = KeyLiveTextField(reader: reader, pid: 1, facts: { _ in InsertionFacts() }, watch: watch,
                                     inputMethod: { false }, send: { _ in reader.raw += "\n"; return true })
        guard case .success(let session) = LiveInlineSession.begin(id: "t", field: field, settle: {}) else {
            Issue.record("begin refused"); return
        }
        _ = session.update("the harbor")
        #expect(session.update("the harbor lights") != nil, "typing stops: pFlow's words are not there")
        guard case .kept = session.finalize("The harbor lights.") else { Issue.record("the finished text went in"); return }
    }
}
