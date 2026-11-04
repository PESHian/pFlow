import Foundation
import Testing
@testable import Yap

/// Owner 2026-11-01, T3 Code: after a click from its browser pane into the message box, live words
/// started and then went to pFlow's card. When the field pFlow captured never shows the words, the
/// field focused now is checked: it becomes the take's target only when it holds pFlow's newest words
/// right before its caret, or in exactly one place.
struct MarksPlaceTests {
    @Test func theWordsRightBeforeTheCaret() {
        let value = "Dear Sam, the harbor lights"
        #expect(TextInjector.marksPlace(value: value, caret: CFRange(location: 27, length: 0), words: "the harbor lights") == 10)
    }

    @Test func theWordsInTheirOnlyPlaceWhenTheCaretSaysNothing() {
        #expect(TextInjector.marksPlace(value: "Dear Sam, the harbor lights. Bye", caret: nil, words: "the harbor lights") == 10)
        #expect(TextInjector.marksPlace(value: "Dear Sam, the harbor lights. Bye", caret: CFRange(location: 3, length: 4), words: "the harbor lights") == 10)
    }

    @Test func neverAFieldThatDoesNotHoldThemOrHoldsThemTwice() {
        #expect(TextInjector.marksPlace(value: "Dear Sam,", caret: CFRange(location: 9, length: 0), words: "the harbor") == nil)
        #expect(TextInjector.marksPlace(value: "the harbor and the harbor again", caret: CFRange(location: 0, length: 0), words: "the harbor") == nil,
                "twice, and neither right before the caret: no way to tell which is pFlow's")
        #expect(TextInjector.marksPlace(value: "the harbor and the harbor", caret: CFRange(location: 25, length: 0), words: "the harbor") == 15)
        #expect(TextInjector.marksPlace(value: "anything", caret: nil, words: "") == nil)
        #expect(TextInjector.marksPlace(value: "Dear Sam, Sorry", caret: CFRange(location: 0, length: 0), words: " So") == nil,
                "part of a word is not pFlow's words")
        #expect(TextInjector.marksPlace(value: "Dear Sam, So. Bye", caret: CFRange(location: 0, length: 0), words: " So") == 9)
        #expect(TextInjector.marksPlace(value: "Mr. Harbor", caret: nil, words: "Harbor") == 4)
        #expect(TextInjector.marksPlace(value: "Mr. Harbors", caret: nil, words: "Harbor") == nil)
        #expect(TextInjector.marksPlace(value: "Seaharbor", caret: nil, words: "harbor") == nil, "the end of a longer word")
    }

    /// Owner 2026-11-01, T3 Code: its message box keeps one line break where pFlow's finished text has
    /// a blank line between paragraphs. The text is the same; the caret ended inside the last word.
    @Test func paragraphBreaksReadAsSingleLineBreaksAreTheSameText() {
        let expected = "Dear Sam, The harbor lights glow.\n\nSeven kites drift.\n\nNine pelicans rest."
        #expect(TextInjector.sameButParagraphBreaks("Dear Sam, The harbor lights glow.\nSeven kites drift.\nNine pelicans rest.", expected))
        #expect(!TextInjector.sameButParagraphBreaks(expected, expected), "an exact match is checked the usual way")
        #expect(!TextInjector.sameButParagraphBreaks("Dear Sam, The harbor lights glow. Seven kites drift. Nine pelicans rest.", expected))
        #expect(!TextInjector.sameButParagraphBreaks("Dear Sam, The harbor lights glow.\nSeven kites drift.", expected), "words missing")
        #expect(!TextInjector.sameButParagraphBreaks("One line.\nTwo.", "One line.\nTwo"), "no paragraphs in the text: not this case")
    }

    @Test func theCaretGoesBeforeWhatFollowedIt() {
        #expect(TextInjector.caretAfterFinished(read: "Dear Sam, Hi.\nBye.", after: "") == 18)
        #expect(TextInjector.caretAfterFinished(read: "Dear Sam, Hi.\nBye. Best, Ann", after: " Best, Ann") == 18)
        #expect(TextInjector.caretAfterFinished(read: "Dear Sam, Hi.\nBye.", after: " Best, Ann") == nil)
    }

    @Test func onlyACaretOrSelectionInsideTheFinishedTextIsMoved() {
        #expect(TextInjector.caretNeedsMoving(CFRange(location: 17, length: 0), start: 10, end: 19), "inside the last word")
        #expect(TextInjector.caretNeedsMoving(CFRange(location: 10, length: 9), start: 10, end: 19), "the finished text selected")
        #expect(TextInjector.caretNeedsMoving(CFRange(location: 10, length: 0), start: 10, end: 19), "at its start")
        #expect(!TextInjector.caretNeedsMoving(CFRange(location: 19, length: 0), start: 10, end: 19), "already at the end")
        #expect(!TextInjector.caretNeedsMoving(CFRange(location: 4, length: 0), start: 10, end: 19), "in the person's own text before it")
        #expect(!TextInjector.caretNeedsMoving(CFRange(location: 5, length: 9), start: 10, end: 19), "a selection reaching into the person's text")
        #expect(TextInjector.caretNeedsMoving(CFRange(location: 20, length: 0), start: 10, end: 25))
    }

    @MainActor @Test func anotherAppOrDesktopComingForwardIsRemembered() {
        let moves = FocusMoves.shared
        let before = PersonInput.now()
        #expect(!moves.moved(since: PersonInput.now() + 1_000_000_000), "nothing after a time still to come")
        moves.noteMoveForTesting()
        #expect(moves.moved(since: before))
        #expect(!moves.moved(since: PersonInput.now() + 1_000_000_000))
    }
}
