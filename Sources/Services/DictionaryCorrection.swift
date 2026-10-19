import Foundation

/// Deterministic first pass over a transcript using the user's dictionary.
enum DictionaryCorrection {
    /// One pass over the original text: longest phrase wins, inserted values
    /// are literal and never trigger another rule. Match Unicode word boundaries.
    static func applyReplacements(in text: String, rules: [DictionaryReplacement]) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for (range, replacement) in replacementEdits(in: text, rules: rules) {
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            result += replacement
            cursor = NSMaxRange(range)
        }
        return result + ns.substring(from: cursor)
    }

    static func applyReplacements(in text: NSAttributedString, rules: [DictionaryReplacement]) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        for (range, replacement) in replacementEdits(in: text.string, rules: rules).reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        return result
    }

    private static func replacementEdits(in text: String, rules: [DictionaryReplacement]) -> [(NSRange, String)] {
        let ordered = rules.filter { !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !$0.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
        guard !ordered.isEmpty else { return [] }
        let patterns = ordered.map { rule in
            rule.heard.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        }
        let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])(?:" + patterns.joined(separator: "|") + ")(?![\\p{L}\\p{M}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let matched = ns.substring(with: match.range)
            let key = matched.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let rule = ordered.first { $0.heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .caseInsensitiveCompare(key) == .orderedSame }
            return (match.range, rule?.replacement ?? matched)
        }
    }
    /// Replaces any word that differs from a learned term only in its first
    /// letter, e.g. "brigade" -> "Frigade". A swapped first consonant is the
    /// most common way dictation mangles a name, and requiring everything after
    /// the first letter to match keeps this from touching unrelated words. Runs
    /// on device with no model, so it costs nothing.
    static func correctFirstLetterMisses(in text: String, terms: [String], excluding phrases: [String] = []) -> String {
        // Single words only (phrases are handled by biasing and the AI pass), and
        // at least four letters so short common words don't collide.
        let candidates = terms.filter { !$0.contains(" ") && $0.count >= 4 }
        guard !candidates.isEmpty else { return text }

        let regex = try? NSRegularExpression(pattern: "\\p{L}{4,}")
        guard let regex else { return text }

        let ns = text as NSString
        let protected = Set(phrases.flatMap { $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) })
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let word = ns.substring(with: range)
            result += protected.contains(word.lowercased()) ? word : replacement(for: word, in: candidates) ?? word
            cursor = range.location + range.length
        }
        result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        return result
    }

    private static func replacement(for word: String, in terms: [String]) -> String? {
        let lowerWord = word.lowercased()
        for term in terms where term.count == word.count {
            let lowerTerm = term.lowercased()
            guard lowerTerm != lowerWord else { return nil } // already the term (any case)
            if lowerTerm.first != lowerWord.first, lowerTerm.dropFirst() == lowerWord.dropFirst() {
                return term
            }
        }
        return nil
    }
}
