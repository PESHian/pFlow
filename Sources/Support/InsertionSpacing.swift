import Foundation

/// Adds only the separators needed at the destination; history keeps the original words.
enum InsertionSpacing {
    static func prepare(_ text: String, formatted: NSAttributedString? = nil,
                        value: String?, selection: NSRange?) -> (text: String, formatted: NSAttributedString?) {
        var prefix = ""
        var suffix = ""
        if let selection, selection.length != 0 {
            return (text, formatted?.string == text ? formatted : nil)
        }
        if let value, let selection {
            let length = (value as NSString).length
            guard selection.location >= 0, selection.location <= length,
                  let range = Range(selection, in: value),
                  range.lowerBound.samePosition(in: value.unicodeScalars) != nil else {
                return (text, formatted?.string == text ? formatted : nil)
            }
            let left = value[..<range.lowerBound].last
            let right = value[range.upperBound...].first
            // Replacing part of a word is a deliberate edit, not another sentence.
            if !(left.map(isWord) == true && right.map(isWord) == true) {
                if let left, let first = text.first, needsGap(left, first) { prefix = " " }
                if let last = text.last, let right, needsGap(last, right) { suffix = " " }
            }
        } else if let last = text.last, needsGap(last, "A") {
            // Some Electron fields expose no caret context. Leave a separator for
            // the next utterance rather than guessing what precedes this one.
            suffix = " "
        }
        let result = prefix + text + suffix
        guard let formatted, formatted.string == text else { return (result, nil) }
        let styled = NSMutableAttributedString(string: prefix)
        styled.append(formatted)
        styled.append(NSAttributedString(string: suffix))
        return (result, styled)
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func needsGap(_ left: Character, _ right: Character) -> Bool {
        guard !left.isWhitespace, !right.isWhitespace,
              !"([{‘“_-/'\\@#".contains(left),
              !".,;:!?%)]}’”_-/'\\@#".contains(right),
              !usesUnspacedScript(left), !usesUnspacedScript(right) else { return false }
        return true
    }

    static func usesUnspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                || (0x20000...0x323AF).contains($0.value)
        }
    }
}
