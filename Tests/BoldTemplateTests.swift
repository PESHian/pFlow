import AppKit
import Foundation
import Testing
@testable import Yap

@MainActor
struct BoldTemplateTests {
    private func report() -> NSAttributedString {
        var template = DictationTemplate(name: "Fixture", sections: [
            ReportSection(title: "Officer 👮"), ReportSection(title: "Evidence")])
        template.boldHeadings = true
        return template.renderStyled(["Morgan Lee.\n\nEvidence\nThis is body text.", "A photo of <staff> & a lock."])
    }

    @Test func boldChoicePersistsAndOldTemplatesDecodeUnchanged() throws {
        let name = "pflow.bold.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let old = DictationTemplate.policeReport
        #expect(try JSONDecoder().decode(DictationTemplate.self, from: JSONEncoder().encode(old)) == old)
        #expect(old.boldHeadings == nil)
        let store = TemplateStore(defaults: defaults)
        var edited = try #require(store.templates.first)
        edited.boldHeadings = true
        store.save(edited)
        store.activeID = edited.id
        #expect(TemplateStore(defaults: defaults).active == edited)
    }

    @Test func onlyRenderedHeadingsAreBoldEvenWhenBodyRepeatsThem() {
        let styled = report()
        let expected = "Officer 👮\nMorgan Lee.\n\nEvidence\nThis is body text.\n\nEvidence\nA photo of <staff> & a lock."
        #expect(styled.string == expected)
        let ns = styled.string as NSString
        let repeatedBody = ns.range(of: "Evidence")
        let sectionHeading = ns.range(of: "Evidence", options: .backwards)
        #expect(styled.attribute(TemplateTextStyle.heading, at: 0, effectiveRange: nil) as? Bool == true)
        #expect(styled.attribute(TemplateTextStyle.heading, at: repeatedBody.location, effectiveRange: nil) == nil)
        #expect(styled.attribute(TemplateTextStyle.heading, at: sectionHeading.location, effectiveRange: nil) as? Bool == true)
    }

    @Test func dictionaryEditsPreserveBoldRangesAndDoNotCascade() {
        let before = report()
        let rules = [DictionaryReplacement(heard: "Officer", replacement: "Reporting officer"),
                     DictionaryReplacement(heard: "Morgan Lee", replacement: "Sinton 👮‍♀️"),
                     DictionaryReplacement(heard: "Sinton", replacement: "Wrong")]
        let after = DictionaryCorrection.applyReplacements(in: before, rules: rules)
        #expect(after.string == DictionaryCorrection.applyReplacements(in: before.string, rules: rules))
        #expect(after.string.contains("Sinton 👮‍♀️"))
        let ns = after.string as NSString
        #expect(after.attribute(TemplateTextStyle.heading, at: 0, effectiveRange: nil) as? Bool == true)
        #expect(after.attribute(TemplateTextStyle.heading, at: ns.range(of: "Sinton").location, effectiveRange: nil) == nil)
        #expect(after.attribute(TemplateTextStyle.heading, at: ns.range(of: "Evidence", options: .backwards).location, effectiveRange: nil) as? Bool == true)
    }

    @Test func richAndPlainEditorsReceiveSameWordsWithAppropriateBold() throws {
        let styled = report()
        let board = NSPasteboard(name: .init("pflow.bold.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let item = try #require(TextInjector.clipboardItem(text: styled.string, formatted: styled, sessionID: "fixture"))
        #expect(board.writeObjects([item]))
        #expect(board.string(forType: .string) == styled.string)
        #expect(board.data(forType: .rtf) != nil)
        #expect(board.data(forType: .html) != nil)
        for isRich in [true, false] {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            editor.isRichText = isRich
            #expect(editor.readSelection(from: board))
            #expect(editor.string == styled.string)
            let storage = try #require(editor.textStorage)
            let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask) == isRich)
            let bodyOffset = (styled.string as NSString).range(of: "Morgan").location
            let bodyFont = try #require(storage.attribute(.font, at: bodyOffset, effectiveRange: nil) as? NSFont)
            #expect(!NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
        }
    }

    @Test func htmlEscapesDictationAndOnlyWrapsActualHeadings() throws {
        let styled = report()
        let data = try #require(TemplateTextStyle.representations(for: styled)[.html])
        let html = try #require(String(data: data, encoding: .utf8))
        #expect(html.contains("<b>Officer 👮</b>"))
        #expect(html.components(separatedBy: "<b>Evidence</b>").count == 2)
        #expect(html.contains("&lt;staff&gt; &amp; a lock."))
        #expect(!html.contains("<staff>"))
    }

    @Test func staleOrPlainFormattingDoesNotAddRichClipboardTypes() throws {
        let item = try #require(TextInjector.clipboardItem(text: "Current text", formatted: report(), sessionID: "fixture"))
        #expect(item.string(forType: .string) == "Current text")
        #expect(item.data(forType: .rtf) == nil && item.data(forType: .html) == nil)
        let plain = try #require(TextInjector.clipboardItem(text: "Plain", formatted: NSAttributedString(string: "Plain"), sessionID: "fixture"))
        #expect(plain.data(forType: .rtf) == nil && plain.data(forType: .html) == nil)
    }

    @Test func copyOffPreservesScreenshotWhenRichPasteIsUnavailable() async throws {
        let board = NSPasteboard(name: .init("pflow.bold.off.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let image = Data([1, 2, 3, 4])
        let original = NSPasteboardItem()
        original.setData(image, forType: .png)
        #expect(board.writeObjects([original]))
        let injector = TextInjector(pasteboard: board)
        injector.copyToClipboard = { false }
        let styled = report()
        #expect(await injector.deliver(styled.string, formatted: styled) == .savedToHistory)
        #expect(board.data(forType: .png) == image)
        #expect(board.data(forType: .rtf) == nil)
    }

    @Test func coordinatorPreservesFormattingAfterDictionaryAndKeepsHistoryPlain() async throws {
        let session = FakeSession()
        session.textToReturn = "Sinton inspected the lock."
        let injector = FakeInjector()
        let history = FakeHistory()
        var template = DictationTemplate(name: "Fixture", sections: [
            ReportSection(title: "Senten 👮", includeFullDictation: true)])
        template.boldHeadings = true
        let coordinator = makeCoordinator(session: session, injector: injector, history: history,
            replacements: [DictionaryReplacement(heard: "Senten", replacement: "Sinton")],
            formatter: TemplateFormatter(cleanNarrative: { text, _, _ in text }), activeTemplate: { template })
        await coordinator.toggle()
        await coordinator.finish()
        let styled = try #require(injector.receivedFormatting.first ?? nil)
        #expect(styled.string == "Sinton 👮\nSinton inspected the lock.")
        #expect(injector.delivered == [styled.string])
        #expect(history.saved == [styled.string])
        #expect(styled.attribute(TemplateTextStyle.heading, at: 0, effectiveRange: nil) as? Bool == true)
        let bodyOffset = (styled.string as NSString).range(of: "inspected").location
        #expect(styled.attribute(TemplateTextStyle.heading, at: bodyOffset, effectiveRange: nil) == nil)
    }
}
