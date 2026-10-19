import AppKit
import FoundationModels
import Testing
@testable import Yap

@MainActor
struct DictationParagraphTests {
    static let arrival = "At 14:30, Officer Morgan Lee arrived at 12 Maple Street for a fictional training exercise. The front gate was open, and a blue bicycle was resting against the fence near the driveway. Morgan spoke with the resident at the front door and asked whether anyone needed medical help. The resident said that no staff were injured and that everyone was still inside the building."
    static let interview = "Regarding the witness interview, Alex Rivera said the bicycle had been there since the previous evening. Alex had not seen anyone ride it or move it away from the fence during the morning. Morgan asked Alex to describe the lock without guessing who might have left it there. Alex described a silver lock with a red label and said there was no visible damage."
    static let evidence = "Later that afternoon, Morgan photographed the bicycle and the silver lock from the public sidewalk. The photographs showed the position of the wheels, the open gate, and the red label on the lock. Morgan recorded the photographs as items 101 and 102 in the fictional training record. The bicycle remained in place, and no property was collected during the exercise."
    static var report: String { [arrival, interview, evidence].joined(separator: " ") }

    private func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    @Test func fallbackBreaksLongAccountAtSentenceBoundariesWithoutChangingWords() {
        let output = DictationParagraphs.readable(Self.report)
        let paragraphs = output.components(separatedBy: "\n\n")
        #expect(paragraphs.count >= 3)
        #expect(words(output) == words(Self.report))
        #expect(paragraphs.allSatisfy { DictationParagraphs.sentences($0).count >= 2 })
        #expect(output.contains("\n\nRegarding the witness"))
        #expect(output.contains("\n\nLater that afternoon"))
    }

    @Test func sentencePerParagraphOutputIsGroupedAndContextChunksAreSoftBoundaries() {
        let sentences = ["Restart the server on port 8080.", "Check the VPN after the restart.", "Call Pesh once the connection is working."]
        #expect(TranscriptCleanupService.joinEditedParts([sentences.joined(separator: "\n\n")], cleanup: true) == sentences.joined(separator: " "))
        #expect(TranscriptCleanupService.joinEditedParts([sentences[0], sentences[1]], cleanup: true) == sentences[0] + " " + sentences[1])
        let topics = sentences.joined(separator: "\n\n") + "\n\nSeparately, move tomorrow's meeting to the afternoon."
        #expect(DictationParagraphs.readable(topics, mergeShortParagraphs: true).contains("\n\nSeparately,"))
    }

    @Test func shortTextListsExistingParagraphsAndUnicodeRemainIntact() {
        for text in ["I spoke to Sinton. No staff were injured.", "First topic.\n\nSecond topic.",
                     "1. Check port 8080.\n2. Call Pesh.", "• First item.\n\n• Second item.\n\n• Third item.",
                     "Dr. Lee checked version 7.2 with 👮🏽‍♀️ Sinton. It stayed at 45.6."] {
            #expect(DictationParagraphs.readable(text) == text)
        }
        let list = "• First item.\n\n• Second item.\n\n• Third item."
        #expect(DictationParagraphs.readable(list, mergeShortParagraphs: true) == list)
        #expect(DictationParagraphs.readable("") == "")
    }

    @Test func narrativeUsesLightCleanupOnceAndToggleOffKeepsOriginalWords() async throws {
        var calls = 0
        let formatter = TemplateFormatter(cleanNarrative: { text, _, _ in
            calls += 1
            return text.replacingOccurrences(of: "Um, ", with: "")
        })
        let template = DictationTemplate(name: "Training fixture", sections: [ReportSection(title: "Narrative", includeFullDictation: true)])
        let input = "Um, " + Self.report
        let cleaned = try #require(await formatter.format(input, using: template, vocabulary: ["Sinton"]))
        #expect(calls == 1)
        #expect(words(String(cleaned.dropFirst("Narrative\n".count))) == words(Self.report))
        #expect(cleaned.components(separatedBy: "\n\n").count >= 3)
        formatter.cleanupFullDictation = { false }
        let raw = try #require(await formatter.format(input, using: template, vocabulary: []))
        #expect(calls == 1)
        #expect(words(String(raw.dropFirst("Narrative\n".count))) == words(input))
    }

    @Test func formattedReportKeepsParagraphsAndBoldHeadingInRealEditors() async throws {
        let formatter = TemplateFormatter(cleanNarrative: { text, _, _ in text })
        var template = DictationTemplate(name: "Training fixture", sections: [ReportSection(title: "Narrative", includeFullDictation: true)])
        template.boldHeadings = true
        let report = try #require(await formatter.formatStyled(Self.report, using: template, vocabulary: []))
        let board = NSPasteboard(name: .init("pflow.paragraph.fixture.\(UUID())"))
        defer { board.releaseGlobally() }
        let item = try #require(TextInjector.clipboardItem(text: report.string, formatted: report, sessionID: "fixture"))
        #expect(board.writeObjects([item]))
        for rich in [true, false] {
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            editor.isRichText = rich
            #expect(editor.readSelection(from: board))
            #expect(editor.string == report.string)
            #expect(editor.string.contains("\n\nRegarding the witness"))
        }
        #expect(report.attribute(TemplateTextStyle.heading, at: 0, effectiveRange: nil) as? Bool == true)
        #expect(report.attribute(TemplateTextStyle.heading, at: "Narrative\n".count, effectiveRange: nil) == nil)
    }

    @Test func actualOnDeviceCleanupAndFullNarrativeProduceReadableFaithfulParagraphs() async throws {
        #expect(SystemLanguageModel.default.isAvailable)
        // Raw fallback cannot pass the stammer-removal assertion. These three
        // explicit paragraphs must survive the actual model and normalization.
        let deliberate = "The server server stopped.\n\nPesh checked the VPN.\n\nThe connection returned."
        let session = try #require(IntelligenceSettings.shared.session(
            instructions: TranscriptCleanupService.instructions(cleanup: true, vocabulary: []), using: .onDevice))
        let reply = try await session.respond(to: "Edit this transcript:\n<transcript>\n\(deliberate)\n</transcript>",
            generating: TranscriptCleanupService.CleanedTranscript.self,
            options: GenerationOptions(samplingMode: .greedy)).content.text
        #expect(TranscriptCleanupService.isFaithful(input: deliberate, output: reply), "Synthetic model reply: \(reply)")
        #expect(reply.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0 == "server" }.count == 1,
            "Synthetic model reply: \(reply)")
        let edited = await TranscriptCleanupService().process(deliberate, cleanup: true, vocabulary: [], using: .onDevice)
        #expect(edited.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0 == "server" }.count == 1,
            "Synthetic model reply: \(reply); pipeline: \(edited)")
        #expect(edited.components(separatedBy: "\n\n").count == 3)
        let cleaned = await TranscriptCleanupService().process(Self.report, cleanup: true, vocabulary: [], using: .onDevice)
        #expect(cleaned.components(separatedBy: "\n\n").count >= 2)
        #expect(TranscriptCleanupService.isFaithful(input: Self.report, output: cleaned))
        #expect(!cleaned.contains("!"))
        let formatter = TemplateFormatter()
        let template = DictationTemplate(name: "Training fixture", sections: [ReportSection(title: "Narrative", includeFullDictation: true)])
        let report = try #require(await formatter.format(Self.report, using: template, vocabulary: []))
        #expect(report.components(separatedBy: "\n\n").count >= 2)
        #expect(TranscriptCleanupService.isFaithful(input: Self.report, output: String(report.dropFirst("Narrative\n".count))))
        #expect(report.contains("101") && report.contains("102") && report.localizedCaseInsensitiveContains("no staff were injured"))
    }
}
