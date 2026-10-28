import Foundation
import Testing
@testable import Yap

@MainActor
final class VocabularyStoreTests {
    /// Each test's throwaway domains, removed with the test.
    private var scratch: [ScratchDefaults] = []

    @Test func replacementsEditPersistAndKeepOldLearnedWords() throws {
        let defaults = isolatedDefaults()
        let store = VocabularyStore(defaults: defaults)
        store.add("Pesh")
        store.addReplacement(heard: "  Senten ", replacement: " Sinton ")
        store.addReplacement(heard: "senten", replacement: "Sinton")
        #expect(store.replacements.count == 1)
        let id = try #require(store.replacements.first?.id)
        store.addReplacement(heard: "sent in", replacement: "Sinton", id: id)
        #expect(store.replacements.count == 1)
        let reloaded = VocabularyStore(defaults: defaults)
        #expect(reloaded.replacements.first?.heard == "sent in")
        #expect(reloaded.replacements.first?.replacement == "Sinton")
        #expect(reloaded.terms == ["Pesh"])
        #expect(reloaded.recognitionTerms == ["Pesh"])
        #expect(reloaded.preservationTerms == ["Pesh", "Sinton"])
        reloaded.removeReplacement(id)
        #expect(VocabularyStore(defaults: defaults).replacements.isEmpty)
    }

    @Test func exactOnlyDictionaryProtectsNamesWithoutBiasingRecognition() {
        let store = VocabularyStore(defaults: isolatedDefaults())
        store.addReplacement(heard: "Senten", replacement: "Sinton")
        #expect(store.recognitionTerms.isEmpty)
        #expect(!TranscriptCleanupService.isFaithful(input: "The staff arrived.", output: "The Sinton arrived.", vocabulary: store.preservationTerms))
        #expect(DictionaryCorrection.applyReplacements(in: "The staff spoke to Senten.", rules: store.replacements) == "The staff spoke to Sinton.")
    }

    private func isolatedDefaults() -> UserDefaults {
        let made = ScratchDefaults("yap.vocab.test")
        scratch.append(made)
        return made.defaults
    }

    @Test func addsNewestFirstTrimsAndDedupes() {
        let store = VocabularyStore(defaults: isolatedDefaults())
        store.add("Frigade")
        store.add("  Anthropic  ")
        store.add("frigade") // case-insensitive duplicate, ignored
        store.add("   ")      // blank, ignored
        #expect(store.terms == ["Anthropic", "Frigade"])
    }

    @Test func removesAndPersistsAcrossReload() {
        let defaults = isolatedDefaults()
        let store = VocabularyStore(defaults: defaults)
        store.add("Kubernetes")
        store.add("kubectl")
        store.remove("Kubernetes")
        #expect(store.terms == ["kubectl"])

        let reloaded = VocabularyStore(defaults: defaults)
        #expect(reloaded.terms == ["kubectl"])
    }
}
