import Foundation

struct SpokenTemplateCommand {
    let template: DictationTemplate
    let text: String

    /// Only an explicit command at the beginning of a recording selects a
    /// format. Mentioning a report inside the narrative does not switch it.
    static func parse(_ text: String, templates: [DictationTemplate]) -> SpokenTemplateCommand? {
        var matches: [(template: DictationTemplate, end: Int, exactName: Bool)] = []
        let ns = text as NSString
        let polite = #"^\s*(?:(?:okay|ok|please)[,.:]?\s+)?"#
        let article = #"(?:(?:a|an|the)\s+)?"#
        let boundary = #"(?![\p{L}\p{N}_])"#
        func phrase(_ alias: String) -> String? {
            let words = alias.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-‑–—")))
                .filter { !$0.isEmpty }
            return words.isEmpty ? nil : words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"[\s\-‑–—]+"#)
        }
        for template in templates {
            let aliases = Set([template.name] + (template.voiceTriggers ?? []))
            let alternatives = aliases.compactMap(phrase).sorted { $0.count > $1.count }.joined(separator: "|")
            let repeatedUse = #"(?:[.,:;!?—–-]\s*|\s+)(?:(?:so|and)\s+)?(?:please\s+)?use\s+"#
                + article + "(?:" + alternatives + ")" + boundary + #"(?:\s+template\b)?"#
            for alias in aliases {
                guard let name = phrase(alias) else { continue }
                let target = article + name + boundary
                let patterns = [
                    polite + #"(?:write|format)\s+(?:this\s+)?(?:as\s+)?"# + target,
                    polite + #"use\s+"# + target + #"(?:\s+template\b)?"#,
                    polite + #"this\s+is\s+"# + target + "(?:" + repeatedUse + ")?"
                ]
                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                          let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
                    matches.append((template, NSMaxRange(match.range), alias == template.name))
                }
            }
        }
        guard let longest = matches.map(\.end).max() else { return nil }
        var best = matches.filter { $0.end == longest }
        if best.contains(where: \.exactName) { best = best.filter(\.exactName) }
        guard Set(best.map { $0.template.id }).count == 1, let selected = best.first else { return nil }
        var body = ns.substring(from: selected.end).trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove at most one command separator. Never trim narrative punctuation:
        // a leading minus/decimal can be a fact, and the final period is speech.
        if let first = body.first, ".,:;!?…—–-".contains(first) {
            let rest = body.dropFirst()
            let isDecimal = ".,".contains(first) && rest.first?.isNumber == true
            let magnitude = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSignedNumber = "-–−".contains(first)
                && (magnitude.first?.isNumber == true
                    || (magnitude.first.map { ".,".contains($0) } == true
                        && magnitude.dropFirst().first?.isNumber == true))
            if !isDecimal && !isSignedNumber {
                body = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return SpokenTemplateCommand(template: selected.template, text: body)
    }
}
