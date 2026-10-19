import Foundation
import Observation

struct DictionaryReplacement: Codable, Equatable, Identifiable {
    var id = UUID()
    var heard: String
    var replacement: String
}

/// The user's custom dictionary: names and words the transcriber should lean
/// toward. Fed to the recognizer as contextual strings at the start of each
/// dictation, never used to blindly replace text. Persisted as a small JSON
/// array so it survives launches without pulling in a database.
@MainActor
@Observable
final class VocabularyStore {
    private static let key = "dictionaryTerms"
    private static let replacementsKey = "dictionaryReplacements"

    private(set) var terms: [String]
    private(set) var replacements: [DictionaryReplacement]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            terms = decoded
        } else {
            terms = []
        }
        replacements = defaults.data(forKey: Self.replacementsKey)
            .flatMap { try? JSONDecoder().decode([DictionaryReplacement].self, from: $0) } ?? []
    }

    // Exact Heard → Write rules edit only matching text after recognition.
    // Their output spellings must not bias unrelated audio toward that name.
    var recognitionTerms: [String] { terms }

    /// Cleanup may preserve these spellings, but may never introduce an absent
    /// name. This list is separate from recognition bias.
    var preservationTerms: [String] { Array(Set(terms + replacements.map(\.replacement))).sorted() }

    func addReplacement(heard: String, replacement: String, id: UUID? = nil) {
        let source = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !target.isEmpty else { return }
        let existing = replacements.first { $0.heard.caseInsensitiveCompare(source) == .orderedSame }
        let rule = DictionaryReplacement(id: existing?.id ?? id ?? UUID(), heard: source, replacement: target)
        replacements.removeAll { $0.id == id || $0.heard.caseInsensitiveCompare(source) == .orderedSame }
        replacements.insert(rule, at: 0)
        persistReplacements()
    }

    func removeReplacement(_ id: UUID) {
        replacements.removeAll { $0.id == id }
        persistReplacements()
    }

    private func persistReplacements() {
        guard let data = try? JSONEncoder().encode(replacements) else { return }
        defaults.set(data, forKey: Self.replacementsKey)
    }

    /// Adds a term, newest first. Ignores blanks and case-insensitive duplicates
    /// so the list stays clean.
    func add(_ raw: String) {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty,
              !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame })
        else { return }
        terms.insert(term, at: 0)
        persist()
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(terms) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
