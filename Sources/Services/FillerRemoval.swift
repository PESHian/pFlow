import Foundation

/// Strips common filler words ("um", "uh", ...) from a transcript with a plain
/// regex. Deterministic and on device, so it costs nothing and can be on by
/// default. The heavier Apple Intelligence cleanup does this too, but this runs
/// even when that is off.
enum FillerRemoval {
    /// The default filler set. Whole-word and case-insensitive, so real words
    /// that merely contain these letters ("human", "summary") are left alone.
    static let words = ["uhhh", "uhh", "uhm", "umm", "mmm", "hmm", "ehh", "uh", "um", "hm", "mm", "mh"]

    static func strip(_ text: String) -> String {
        let alternation = words
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        // Remove each filler token as a whole word, taking a trailing comma with it. Never right
        // after a number: there it is a unit ("10 mm", "5 um"), and dropping it changes the number.
        var out = text.replacingOccurrences(
            of: "(?<![0-9][ \\t])(?<![0-9])\\b(?:\(alternation))\\b,?",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Nothing matched: leave the transcript exactly as it was, so filler-free
        // dictations aren't re-spaced or re-capitalized.
        guard out != text else { return text }

        // Tidy the gaps the removals leave behind.
        out = out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "([,.!?;:])\\1+", with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: "^[\\s,]+", with: "", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)

        return capitalizeSentences(out)
    }

    /// Uppercase the first letter, and the first letter after each real sentence
    /// end, so removing a leading "Um" doesn't leave the sentence starting
    /// lowercase. A sentence ends at ".", "!" or "?" followed by a space, never
    /// inside a word ("pesh.tech", "3.5") or after an abbreviation ("i.e.",
    /// "Dr."). Never lowercases anything that was already capital.
    private static func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if ".!?".contains(c) {
                let spaced = i + 1 < chars.count && chars[i + 1].isWhitespace
                capitalizeNext = spaced && !(c == "." && abbreviation(endingAt: i, in: chars))
            } else if !c.isWhitespace {
                capitalizeNext = false
            }
        }
        return String(chars)
    }

    /// Short words a period ends without ending the sentence.
    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "approx", "no", "fig"]

    /// The word whose period is at `end` is an abbreviation: it has a period inside ("i.e.", "e.g.")
    /// or is a short title or term ("Dr.", "vs.").
    private static func abbreviation(endingAt end: Int, in chars: [Character]) -> Bool {
        var start = end
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        let word = String(chars[start..<end])
        return word.contains(".") || abbreviations.contains(word.lowercased())
    }
}
