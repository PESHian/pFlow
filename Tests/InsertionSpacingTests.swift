import AppKit
import Testing
@testable import Yap

@MainActor
struct InsertionSpacingTests {
    private func atEnd(_ text: String, after value: String) -> String {
        InsertionSpacing.prepare(text, value: value,
            selection: NSRange(location: (value as NSString).length, length: 0)).text
    }

    @Test func successiveSentencesHaveOneSpace() {
        #expect(atEnd("Just like this.", after: "It runs together.") == " Just like this.")
        #expect(atEnd("Next sentence.", after: "First sentence. ") == "Next sentence.")
        #expect(atEnd("Next paragraph.", after: "First paragraph.\n\n") == "Next paragraph.")
        #expect(atEnd("First sentence.", after: "") == "First sentence.")
    }

    @Test func replacementsFragmentsAndPunctuationKeepTheirMeaning() {
        #expect(InsertionSpacing.prepare("Sinton", value: "staff", selection: NSRange(location: 0, length: 5)).text == "Sinton")
        #expect(InsertionSpacing.prepare("t", value: "Sinon", selection: NSRange(location: 3, length: 0)).text == "t")
        #expect(atEnd(", then stop.", after: "Start") == ", then stop.")
        #expect(atEnd("2026", after: "ID-") == "2026")
        #expect(atEnd("name", after: "(") == "name")
        #expect(InsertionSpacing.prepare("new", value: "A word", selection: NSRange(location: 2, length: 0)).text == "new ")
    }

    @Test func utf16CaretAndUnspacedScriptsArePreserved() {
        #expect(atEnd("Next.", after: "👮🏽‍♀️ Café.") == " Next.")
        #expect(atEnd("こんにちは。", after: "こんにちは。") == "こんにちは。")
        #expect(atEnd("下一句。", after: "第一句。") == "下一句。")
        #expect(InsertionSpacing.prepare("Test", value: "👋", selection: NSRange(location: 1, length: 0)).text == "Test")
        #expect(InsertionSpacing.prepare("Test", value: "A", selection: NSRange(location: NSNotFound, length: 0)).text == "Test")
    }

    @Test func unreadableFieldsLeaveGapForNextUtterance() {
        let first = InsertionSpacing.prepare("It runs together.", value: nil, selection: nil).text
        let second = InsertionSpacing.prepare("Just like this.", value: nil, selection: nil).text
        #expect(first + second == "It runs together. Just like this. ")
        #expect(InsertionSpacing.prepare("Already spaced. ", value: nil, selection: nil).text == "Already spaced. ")
        #expect(InsertionSpacing.prepare("こんにちは。", value: nil, selection: nil).text == "こんにちは。")
        #expect(InsertionSpacing.prepare("staff", value: nil, selection: NSRange(location: 0, length: 6)).text == "staff")
    }

    @Test func paddingRetainsExactBoldHeadingRanges() throws {
        let styled = NSMutableAttributedString(string: "Officer\nMorgan Lee.")
        styled.addAttribute(TemplateTextStyle.heading, value: true, range: NSRange(location: 0, length: 7))
        let prepared = InsertionSpacing.prepare(styled.string, formatted: styled, value: "Previous.", selection: NSRange(location: 9, length: 0))
        let result = try #require(prepared.formatted)
        #expect(result.string == " Officer\nMorgan Lee.")
        #expect(result.attribute(TemplateTextStyle.heading, at: 0, effectiveRange: nil) == nil)
        #expect(result.attribute(TemplateTextStyle.heading, at: 1, effectiveRange: nil) as? Bool == true)
        #expect(result.attribute(TemplateTextStyle.heading, at: 9, effectiveRange: nil) == nil)
        #expect(InsertionSpacing.prepare("Changed", formatted: styled, value: nil, selection: nil).formatted == nil)
    }

    @Test func nativeRichAndPlainEditorsReceiveSeparatedUtterances() throws {
        let board = NSPasteboard(name: .init("pflow.spacing.fixture.\(UUID())"))
        defer { board.releaseGlobally() }
        for rich in [true, false] {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            editor.isRichText = rich
            for sentence in ["It runs together.", "Just like this."] {
                let payload = InsertionSpacing.prepare(sentence, value: editor.string, selection: editor.selectedRange())
                board.clearContents()
                #expect(board.writeObjects([try #require(TextInjector.clipboardItem(text: payload.text, formatted: nil, sessionID: "fixture", private: true))]))
                #expect(editor.readSelection(from: board))
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
            #expect(editor.string == "It runs together. Just like this.")
        }
    }
}
