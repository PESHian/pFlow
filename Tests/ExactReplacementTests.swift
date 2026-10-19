import Testing
@testable import Yap

struct ExactReplacementTests {
    @Test func correctsRequestedNamesAndPhrasesWithoutTouchingOtherWords() {
        let rules = [DictionaryReplacement(heard: "Senten", replacement: "Sinton"),
                     DictionaryReplacement(heard: "sent in", replacement: "Sinton")]
        #expect(DictionaryCorrection.applyReplacements(in: "SENTEN said sent  in. Sentences and Sentenland stay.", rules: rules)
            == "Sinton said Sinton. Sentences and Sentenland stay.")
    }

    @Test func longestPhraseWinsAndReplacementTextDoesNotCascade() {
        let rules = [DictionaryReplacement(heard: "sent", replacement: "mailed"),
                     DictionaryReplacement(heard: "sent in", replacement: "Sinton"),
                     DictionaryReplacement(heard: "Sinton", replacement: "Other")]
        #expect(DictionaryCorrection.applyReplacements(in: "sent in, then sent.", rules: rules) == "Sinton, then mailed.")
    }

    @Test func treatsRegexAndReplacementCharactersLiterallyAndRespectsUnicode() {
        let rules = [DictionaryReplacement(heard: "C++", replacement: "$1\\SDK"),
                     DictionaryReplacement(heard: "Senten", replacement: "Sinton")]
        #expect(DictionaryCorrection.applyReplacements(in: "C++ and éSenten and Senten's.", rules: rules)
            == "$1\\SDK and éSenten and Sinton's.")
        #expect(DictionaryCorrection.applyReplacements(in: "keep me", rules: [.init(heard: " ", replacement: "oops")]) == "keep me")
    }

    @Test func explicitSourceIsProtectedFromAutomaticFirstLetterCorrection() {
        #expect(DictionaryCorrection.correctFirstLetterMisses(in: "brigade and genten", terms: ["Frigade", "Senten"], excluding: ["brigade"])
            == "brigade and Senten")
    }
}
