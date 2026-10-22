import Foundation

/// What a live-typing session sees in the destination at one moment. Ranges
/// and lengths are UTF-16 code units, the unit Accessibility (and Windows)
/// uses. The same shape is used by the shared fixtures in
/// `fixtures/live-text/inline-ownership`.
struct LiveFieldState: Equatable {
    /// The frontmost app's process.
    var app: Int32
    /// "target" while the focused element is the captured field, anything else otherwise.
    var element: String
    var secure: Bool
    /// pFlow still has Accessibility permission.
    var trusted: Bool
    var value: String?
    var selection: NSRange?

    static let target = "target"
}

/// Words two consecutive transcript updates agree on. A recognizer may still
/// change its newest words, and Whisper's first window sometimes invents a
/// phrase that the next window drops, so only agreed words are typed live.
enum LiveStableText {
    static func agreed(previous: String?, current: String) -> String {
        guard let previous else { return "" }
        let old = Array(previous), new = Array(current)
        var count = 0
        while count < old.count, count < new.count, sameUnits(old[count], new[count]) { count += 1 }
        if count == old.count, count == new.count { return trimmed(current) }
        // Cut back to a point where a word has ended in both updates.
        while count > 0, !(endsWord(old, at: count, endIsBoundary: true) && endsWord(new, at: count, endIsBoundary: false)) {
            count -= 1
        }
        return trimmed(String(new[..<count]))
    }

    /// True when `prefix` is all of `text` or stops where a word ends.
    static func startsWithWholeWords(_ text: String, _ prefix: String) -> Bool {
        let characters = Array(text), head = Array(prefix)
        guard head.count <= characters.count,
              zip(head, characters).allSatisfy({ sameUnits($0, $1) }) else { return false }
        return endsWord(characters, at: head.count, endIsBoundary: true)
    }

    private static func endsWord(_ characters: [Character], at index: Int, endIsBoundary: Bool) -> Bool {
        if index == characters.count { return endIsBoundary }
        let next = characters[index]
        // An apostrophe or hyphen may continue the word ("don't", "follow-up").
        let joins = "'’-‐".contains(next)
        if next.isWhitespace || (next.isPunctuation && !joins) || unspaced(next) { return true }
        return index > 0 && (characters[index - 1].isWhitespace || unspaced(characters[index - 1]))
    }

    /// Chinese and Japanese are written without spaces, so each character ends a word.
    private static func unspaced(_ character: Character) -> Bool {
        InsertionSpacing.usesUnspacedScript(character)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Swift treats canonically equivalent characters as equal; a destination
    /// counts code units, so pFlow compares those.
    static func sameUnits(_ a: Character, _ b: Character) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }
}

/// The ownership rules for typing a take into another app while it is
/// spoken. Pure: it decides what to write and checks what it observed; the
/// caller performs the write with a native text-range operation and reports
/// back. pFlow owns exactly one span, starting at the person's caret or
/// selection. Anything outside that span, or any change pFlow did not make,
/// stops live typing for the take, and nothing is ever retried.
struct LiveInlineOwnership {
    enum Stop: String, Codable, Error, Equatable {
        case unsupported, permission, app, focus, secure, text, caret, uncertain
    }

    struct Write: Equatable {
        /// The part of the owned span to replace, in the field's UTF-16 positions.
        let range: NSRange
        let text: String
        /// Where the selection must be put afterwards; nil leaves the caret after `text`.
        let select: NSRange?
    }

    enum Step: Equatable {
        case none
        case write(Write)
        case stopped(Stop)
    }

    /// Longest field, in UTF-16 units, read on every update. Longer fields use Preview.
    static let maxFieldLength = 100_000

    private let app: Int32
    private let before: String
    private let after: String
    let original: NSRange
    let originalSelected: String
    /// Exactly what the owned span holds now.
    private(set) var owned: String
    private(set) var caret: NSRange
    private(set) var stopped: Stop?
    /// A write call succeeded this take, so the destination may hold pFlow's text.
    private(set) var touched = false
    private var typedWords = ""
    private var previous: String?
    private var pending: (owned: String, words: String, caret: NSRange)?

    /// Checks the destination captured before any pFlow UI appeared.
    /// `writable` is the native probe: range writes are possible here.
    static func begin(_ state: LiveFieldState, writable: Bool) -> Result<LiveInlineOwnership, Stop> {
        guard state.trusted else { return .failure(.permission) }
        guard !state.secure else { return .failure(.secure) }
        guard writable, state.element == LiveFieldState.target, let value = state.value,
              (value as NSString).length <= maxFieldLength,
              let selection = state.selection, selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= (value as NSString).length,
              let range = Range(selection, in: value),
              range.lowerBound.samePosition(in: value.unicodeScalars) != nil,
              range.upperBound.samePosition(in: value.unicodeScalars) != nil else { return .failure(.unsupported) }
        return .success(LiveInlineOwnership(app: state.app, value: value, selection: selection, range: range))
    }

    private init(app: Int32, value: String, selection: NSRange, range: Range<String.Index>) {
        self.app = app
        before = String(value[..<range.lowerBound])
        after = String(value[range.upperBound...])
        original = selection
        originalSelected = String(value[range])
        owned = originalSelected
        caret = selection
    }

    var expectedValue: String { before + owned + after }

    /// The first reason the destination is no longer exactly as pFlow left it.
    func check(_ state: LiveFieldState) -> Stop? {
        if !state.trusted { return .permission }
        if state.app != app { return .app }
        if state.element != LiveFieldState.target { return .focus }
        if state.secure { return .secure }
        guard let value = state.value, value.utf16.elementsEqual(expectedValue.utf16) else { return .text }
        guard state.selection == caret else { return .caret }
        return nil
    }

    /// A new whole transcript arrived. Returns the one write to make, if any.
    mutating func update(transcript: String, observed state: LiveFieldState) -> Step {
        guard stopped == nil, pending == nil else { return .none }
        if let reason = check(state) { return stop(reason) }
        let words = LiveStableText.agreed(previous: previous, current: transcript)
        previous = transcript
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep what is typed while the newest words still begin with it,
        // so a recognizer that hesitates over its last word causes no flicker.
        if words.count <= typedWords.count, LiveStableText.startsWithWholeWords(spoken, typedWords) { return .none }
        if words.isEmpty, !touched { return .none }
        return plan(words: words, text: spaced(words))
    }

    /// The finished, cleaned text replaces the owned span once.
    mutating func finalize(text: String, observed state: LiveFieldState) -> Step {
        if let stopped { return .stopped(stopped) }
        guard pending == nil else { return stop(.uncertain) }
        if let reason = check(state) { return stop(reason) }
        return plan(words: text, text: spaced(text))
    }

    /// Takes pFlow's text back out, only while everything is exactly as pFlow
    /// left it. Never after an uncertain write, never over a later edit.
    mutating func cancel(observed state: LiveFieldState) -> Step {
        guard touched || pending != nil else { return .none }
        if stopped == .uncertain || pending != nil { return .stopped(.uncertain) }
        if let reason = check(state) { return .stopped(reason) }
        if owned.utf16.elementsEqual(originalSelected.utf16), caret == original { return .none }
        let start = original.location
        pending = (originalSelected, "", original)
        return .write(Write(range: NSRange(location: start, length: owned.utf16.count),
                            text: originalSelected, select: original))
    }

    /// Reports how the write went and what the field shows now.
    /// Anything but the exact expected result ends live typing for the take.
    mutating func confirm(accepted: Bool, observed state: LiveFieldState) -> Step {
        guard let pending else { return .none }
        self.pending = nil
        // A write call that succeeded may have put pFlow's text in, whatever
        // the field reads back (Chromium and Electron apply it later), so the
        // take counts as typed. Only a write the app refused leaves nothing.
        // A refused write can still land (an Accessibility call that timed
        // out): any difference from what the field held before also counts.
        if accepted || !unchanged(state) { touched = true }
        guard accepted, settled(pending, state) else { return stop(.uncertain) }
        owned = pending.owned
        typedWords = pending.words
        caret = pending.caret
        return .none
    }

    /// Whether the field shows the pending write exactly, so there is nothing
    /// left to wait for before it is confirmed.
    func applied(_ state: LiveFieldState) -> Bool {
        guard let pending else { return true }
        return settled(pending, state)
    }

    /// Whether the field still holds exactly what it held before any pending
    /// write: nothing of pFlow's beyond what was confirmed is in it.
    func unchanged(_ state: LiveFieldState) -> Bool {
        state.app == app && state.element == LiveFieldState.target
            && state.value?.utf16.elementsEqual((before + owned + after).utf16) == true
    }

    /// A take that never had a successful write can still be touched if the
    /// field no longer matches its snapshot; called once before the final
    /// decision, after the field had time to settle.
    mutating func noteFieldChanged(_ state: LiveFieldState) {
        if !unchanged(state) { touched = true }
    }

    private func settled(_ pending: (owned: String, words: String, caret: NSRange), _ state: LiveFieldState) -> Bool {
        let expected = before + pending.owned + after
        return state.trusted && state.app == app && state.element == LiveFieldState.target && !state.secure
            && state.value?.utf16.elementsEqual(expected.utf16) == true && state.selection == pending.caret
    }

    private mutating func stop(_ reason: Stop) -> Step {
        stopped = reason
        return .stopped(reason)
    }

    private func spaced(_ words: String) -> String {
        guard !words.isEmpty else { return "" }
        return InsertionSpacing.prepare(words, value: before + originalSelected + after, selection: original).text
    }

    /// The smallest replacement from the first differing character to the
    /// end of the owned span, so the caret ends after pFlow's text.
    private mutating func plan(words: String, text target: String) -> Step {
        guard !owned.utf16.elementsEqual(target.utf16) else { return .none }
        let old = Array(owned), new = Array(target)
        var shared = 0, units = 0
        while shared < old.count, shared < new.count, LiveStableText.sameUnits(old[shared], new[shared]) {
            units += old[shared].utf16.count
            shared += 1
        }
        let replacement = String(new[shared...])
        let start = original.location
        let range = NSRange(location: start + units, length: owned.utf16.count - units)
        pending = (target, words, NSRange(location: start + target.utf16.count, length: 0))
        return .write(Write(range: range, text: replacement, select: nil))
    }
}
