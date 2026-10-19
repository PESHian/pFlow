import Foundation
import NaturalLanguage

/// Paragraph layout never changes the words, their order, or punctuation.
enum DictationParagraphs {
    static func sentences(_ text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            result.append(range)
            return true
        }
        return result
    }

    /// Conservative fallback for a wall of text. Keeps lists and existing
    /// paragraphs; splits only between complete sentences, never at a word count.
    static func readable(_ text: String, mergeShortParagraphs: Bool = false) -> String {
        var blocks = text.components(separatedBy: "\n\n")
        if mergeShortParagraphs, blocks.count >= 3,
           blocks.allSatisfy({ !isStructured($0) && sentences($0).count == 1 }) {
            var merged: [String] = []
            var group = ""
            for block in blocks {
                if !group.isEmpty, wordCount(group) >= 70 || beginsTopic(block) {
                    merged.append(group); group = ""
                }
                group += (group.isEmpty ? "" : " ") + block.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !group.isEmpty { merged.append(group) }
            blocks = merged
        }
        return blocks.map { block in
            guard !isStructured(block), wordCount(block) > 110 else { return block }
            let ranges = sentences(block)
            var breaks: [Int] = []
            var count = 0
            var words = 0
            for (index, range) in ranges.enumerated() {
                let next = String(block[range])
                let topic = beginsTopic(next)
                let full = count >= 2 && words >= 75 || count >= 4 && words >= 45
                if count >= 2, topic || (full && index < ranges.count - 1) {
                    breaks.append(index + 1); count = 0; words = 0
                }
                count += 1; words += wordCount(next)
            }
            let result = NSMutableString(string: block)
            for number in breaks.reversed() {
                let end = ranges[number - 1].lowerBound
                var begin = end
                while begin > block.startIndex, block[block.index(before: begin)].isWhitespace {
                    begin = block.index(before: begin)
                }
                result.replaceCharacters(in: NSRange(begin..<end, in: block), with: "\n\n")
            }
            return result as String
        }.joined(separator: "\n\n")
    }

    private static func isStructured(_ text: String) -> Bool {
        text.contains("\n") || text.range(of: #"^\s*(?:[-*•]|\d+[.)]|#{1,6}|```)[ \t]+"#,
            options: .regularExpression) != nil
    }

    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    private static func beginsTopic(_ text: String) -> Bool {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["separately,", "regarding ", "turning to ", "as for ", "meanwhile,", "the next day", "later that "]
            .contains(where: start.hasPrefix)
    }
}
