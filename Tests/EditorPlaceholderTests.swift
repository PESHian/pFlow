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

    init(_ raw: String, caret: Int, shape: Shape = .drops, placeholderText: String? = nil, markedEmpty: Bool = false) {
        self.raw = raw
        selection = NSRange(location: caret, length: 0)
        self.shape = shape
        placeholder = EditorPlaceholder.start(value: raw, placeholderText: placeholderText, markedEmpty: markedEmpty)
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

@MainActor
struct EditorPlaceholderTests {
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
        #expect(EditorPlaceholder.start(value: "Write a message\n", placeholderText: nil, markedEmpty: false) == nil,
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
