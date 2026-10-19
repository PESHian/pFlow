import Testing
@testable import Yap

struct SpokenTemplateCommandTests {
    @Test func understandsNaturalReportRequestsAndKeepsTheNarration() throws {
        let template = DictationTemplate.policeReport
        for opening in ["This is a police report. So use the police report template.",
                        "This is a police report, so use the police report template.",
                        "This is an initial report, and use the police report template.",
                        "Use the police report template.", "Please use the initial report template.",
                        "This is a police report."] {
            let route = try #require(SpokenTemplateCommand.parse(opening + " Officer Pesh arrived. No staff were injured.", templates: [template]))
            #expect(route.template.id == template.id)
            #expect(route.text == "Officer Pesh arrived. No staff were injured.")
        }
        let route = try #require(SpokenTemplateCommand.parse("This is a police report. So use the police report template. -.5 grams were found.", templates: [template]))
        #expect(route.text == "-.5 grams were found.")
        #expect(SpokenTemplateCommand.parse("The witness said this is a police report. Use the police report template.", templates: [template]) == nil)
        #expect(SpokenTemplateCommand.parse("This is a police reporter speaking.", templates: [template]) == nil)
    }
    @Test func routesInitialSupplementFollowUpAndCustomNamesAndRemovesOnlyThePrefix() throws {
        let initial = DictationTemplate.policeReport
        let supplement = DictationTemplate.supplement
        let followup = DictationTemplate.followUp
        let custom = DictationTemplate(name: "Field notes", sections: [ReportSection(title: "Notes")])
        let all = [initial, supplement, followup, custom]
        for (phrase, expected) in [("Write this as an initial report. Officer Pesh arrived.", initial),
                                   ("Please write this as a supplement: Officer Pesh arrived.", supplement),
                                   ("Format this as a follow up, Officer Pesh arrived.", followup),
                                   ("Write this as field notes. Officer Pesh arrived.", custom)] {
            let route = try #require(SpokenTemplateCommand.parse(phrase, templates: all))
            #expect(route.template.id == expected.id)
            #expect(route.text == "Officer Pesh arrived.")
        }
        #expect(SpokenTemplateCommand.parse("Write this as a supplement.", templates: all)?.text == "")
        for body in ["-5 degrees was recorded.", ".5 grams were found.", "+5 degrees was recorded.", "- 5 degrees was recorded.",
                     "-.5 degrees was recorded.", "- .5 degrees was recorded.", "–.5 degrees was recorded.", "-,5 degrees was recorded.", ",5 grams were found."] {
            for separator in [". ", ": ", " "] {
                let route = try #require(SpokenTemplateCommand.parse("Write this as an initial report" + separator + body, templates: all))
                #expect(route.text == body)
            }
        }
    }

    @Test func doesNotInterpretMidNarrativeMentionsOrAmbiguousCommands() {
        let first = DictationTemplate.policeReport
        var duplicate = DictationTemplate.policeReport
        duplicate.name = "Another report"
        #expect(SpokenTemplateCommand.parse("I asked him to write this as an initial report.", templates: [first]) == nil)
        #expect(SpokenTemplateCommand.parse("Write this as an initial reporter arrived.", templates: [first]) == nil)
        #expect(SpokenTemplateCommand.parse("Write this as an initial report. Details.", templates: [first, duplicate]) == nil)
    }
}
