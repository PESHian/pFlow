import Testing
@testable import Yap

struct FillerRemovalTests {
    private func strip(_ text: String) -> String { FillerRemoval.strip(text) }

    @Test func removesLeadingFillerAndCapitalizes() {
        #expect(strip("um so I think") == "So I think")
    }

    @Test func removesMidSentenceFiller() {
        #expect(strip("I think um we should go") == "I think we should go")
    }

    @Test func removesFillerWithCommas() {
        #expect(strip("so, um, yeah") == "So, yeah")
    }

    @Test func removesSeveralDifferentFillers() {
        #expect(strip("uh hello uhh there hmm") == "Hello there")
    }

    @Test func isCaseInsensitive() {
        #expect(strip("Um okay UH sure") == "Okay sure")
    }

    @Test func leavesRealWordsThatContainFillerLetters() {
        // "human" contains "um", "summary" contains "umm" — both must survive, and
        // with no filler removed the text is returned untouched (not re-capitalized).
        #expect(strip("the human summary") == "the human summary")
    }

    @Test func capitalizesAfterSentenceEnd() {
        #expect(strip("yeah. um okay") == "Yeah. Okay")
    }

    @Test func doesNotLowercaseExistingCapitals() {
        #expect(strip("um I met Anna today") == "I met Anna today")
    }

    /// A unit after a number is never a filler: dropping it silently changes the number (hunt H1).
    @Test func keepsUnitsAfterNumbers() {
        #expect(strip("the bolt is 10 mm long") == "the bolt is 10 mm long")
        #expect(strip("um the bolt is 10 mm long") == "The bolt is 10 mm long")
        #expect(strip("set it to 2.5 mm, um, then 40 hm and 5 um") == "Set it to 2.5 mm, then 40 hm and 5 um")
        #expect(strip("mm that's 10mm") == "That's 10mm")
        #expect(strip("hmm, mm, okay") == "Okay", "real fillers still go")
    }

    /// Only a real sentence start is capitalized: not inside a web address or a number, not after
    /// an abbreviation (hunt H8).
    @Test func capitalizesOnlyRealSentenceStarts() {
        #expect(strip("um, go to pesh.tech, i.e. the site") == "Go to pesh.tech, i.e. the site")
        #expect(strip("uh it costs 3.50 now. um see Dr. smith e.g. today! uh ok") == "It costs 3.50 now. See Dr. smith e.g. today! Ok")
        #expect(strip("um no. we can't") == "No. We can't", "\"No.\" ends a sentence (review M2)")
    }

    @Test func allFillerBecomesEmpty() {
        #expect(strip("um uh hmm") == "")
    }
}
