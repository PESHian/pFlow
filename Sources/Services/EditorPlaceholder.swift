import Foundation

/// An empty rich-text editor (ProseMirror, Tiptap, Lexical, Slate, Gmail's
/// compose body, T3 Code's composer) often reads, over Accessibility, as a
/// placeholder instead of as empty: a lone line break, a zero-width space, or
/// the placeholder text itself. The placeholder goes away or moves once the
/// first character lands. A field that held only a placeholder when the take
/// began is treated as empty: placeholder characters at either end of what
/// it reads are set aside, and pFlow's words must then be everything in it,
/// exactly once. A field that held real text keeps the exact check.
enum EditorPlaceholder {
    /// Characters an empty editor shows in place of nothing.
    static func isResidue(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\n", "\r", "\u{2028}", "\u{2029}", "\u{200B}", "\u{FEFF}", "\u{2060}": return true
        default: return false
        }
    }

    /// Classes an editor puts on itself (or its first block) only while the
    /// whole editor is empty: Tiptap/ProseMirror's placeholder extension and
    /// Quill. Their placeholder is drawn with CSS, which Chromium reads out as
    /// text.
    static let emptyEditorClasses: Set<String> = ["is-editor-empty", "ql-blank"]

    /// The placeholder text of a field that holds only a placeholder when the
    /// take begins, or nil when it holds anything real. `placeholderText` is
    /// what the field reports as its placeholder; `markedEmpty` is true when
    /// the editor marks itself empty (`emptyEditorClasses`), in which case the
    /// whole value it shows is its placeholder.
    static func start(value: String?, placeholderText: String?, markedEmpty: Bool) -> Start? {
        let text = placeholderText.flatMap { $0.isEmpty ? nil : $0 }
            ?? (markedEmpty ? value?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        return only(value, placeholderText: text) ? Start(text: text) : nil
    }

    /// A field that began as a placeholder, and the placeholder text it showed then.
    struct Start: Equatable {
        let text: String?
    }

    /// The field holds nothing but a placeholder: one or more placeholder
    /// characters, or exactly its own placeholder text. An empty value is not
    /// a placeholder (it is simply empty) and nor is any real text.
    static func only(_ value: String?, placeholderText: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        if value.unicodeScalars.allSatisfy(isResidue) { return true }
        let shown = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let placeholderText else { return false }
        let placeholder = placeholderText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !placeholder.isEmpty && shown == placeholder
    }

    /// What a field that began as a placeholder holds, seen as pFlow sees it:
    /// placeholder characters at both ends set aside, the selection moved to
    /// match. `leading` is how many UTF-16 units were set aside before the text.
    static func view(_ value: String, selection: NSRange?, placeholderText: String?) -> (value: String, selection: NSRange?, leading: Int) {
        if only(value, placeholderText: placeholderText) {
            return ("", selection.map { _ in NSRange(location: 0, length: 0) }, 0)
        }
        let scalars = Array(value.unicodeScalars)
        var start = 0, end = scalars.count
        while start < end, isResidue(scalars[start]) { start += 1 }
        while end > start, isResidue(scalars[end - 1]) { end -= 1 }
        var inner = String.UnicodeScalarView()
        inner.append(contentsOf: scalars[start..<end])
        let text = String(inner)
        let leading = scalars[..<start].reduce(0) { $0 + $1.utf16.count }
        // A caret inside the leading placeholder is at the start of the text; one
        // past the text (after a trailing line break) stays past it, so it never
        // reads as the caret pFlow left.
        let moved = selection.map { NSRange(location: max($0.location - leading, 0), length: $0.length) }
        return (text, moved, leading)
    }

    /// A field state as pFlow sees it once the field began as a placeholder.
    static func seen(_ state: LiveFieldState, placeholderText: String?) -> LiveFieldState {
        guard let raw = state.value else { return state }
        let view = view(raw, selection: state.selection, placeholderText: placeholderText)
        var seen = state
        seen.value = view.value
        seen.selection = view.selection
        return seen
    }

    /// A range in what pFlow sees, as a range in the field itself.
    static func fieldRange(_ range: NSRange, raw: String?, placeholderText: String?) -> NSRange {
        guard let raw else { return range }
        return NSRange(location: range.location + view(raw, selection: nil, placeholderText: placeholderText).leading,
                       length: range.length)
    }

    /// The one read-back comparison: the field shows exactly `expected`. A
    /// no-break space counts as a space (browsers show a typed space at a
    /// line end as one). When the field began as a placeholder, placeholder
    /// characters at either end are set aside on both sides first.
    static func same(_ read: String?, _ expected: String?, startedAsPlaceholder: Bool) -> Bool {
        guard let read, let expected else { return false }
        if plain(read) == plain(expected) { return true }
        guard startedAsPlaceholder else { return false }
        return plain(view(read, selection: nil, placeholderText: nil).value)
            == plain(view(expected, selection: nil, placeholderText: nil).value)
    }

    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{00A0}", with: " ") }
}
