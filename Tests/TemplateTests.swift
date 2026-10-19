import Foundation
import Testing
@testable import Yap

@MainActor
struct TemplateTests {
    @Test func fullNarrationSurvivesIncompleteGeneratedFieldsAndSummariesStaySummaries() {
        let source = "My name is Morgan Lee. My badge is 4321. No staff were injured."
        let template = DictationTemplate(name: "Report", sections: [
            ReportSection(title: "Synopsis", summarize: true),
            ReportSection(title: "Narrative", includeFullDictation: true)])
        let result = template.render(["No staff were injured.", "The model omitted the officer."], source: source)
        #expect(result == "Synopsis\nNo staff were injured.\n\nNarrative\n" + source)
        let summary = DictationTemplate(name: "Summary", sections: [ReportSection(title: "Synopsis", summarize: true)])
        #expect(summary.render(["No staff were injured."], source: source) == "Synopsis\nNo staff were injured.")
    }

    @Test func legacySectionDecodeAndFactoryUpgradePreserveUserChoices() throws {
        var legacy = DictationTemplate.policeReport
        legacy.sections[3].includeFullDictation = nil
        legacy.sections[0].instructions = "The reporting officer's name and role, only if stated."
        let encoded = try JSONEncoder().encode(legacy)
        #expect(try JSONDecoder().decode(DictationTemplate.self, from: encoded).sections[3].includeFullDictation == nil)
        let suite = "pflow.fullsource.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var custom = DictationTemplate.supplement
        custom.sections[3].includeFullDictation = false
        var summarized = DictationTemplate.followUp
        summarized.sections[3].includeFullDictation = nil
        summarized.sections[3].summarize = true
        var bulleted = DictationTemplate.policeReport
        bulleted.sections[3].includeFullDictation = nil
        bulleted.sections[3].bullets = true
        defaults.set(try JSONEncoder().encode([legacy, custom, summarized, bulleted]), forKey: "pflow.templates")
        defaults.set(legacy.id.uuidString, forKey: "pflow.template.active")
        let store = TemplateStore(defaults: defaults)
        #expect(store.active?.id == legacy.id)
        #expect(store.active?.sections[3].includeFullDictation == true)
        #expect(store.active?.sections[0].instructions.contains("badge") == true)
        #expect(store.templates.first { $0.id == custom.id }?.sections[3].includeFullDictation == false)
        #expect(store.templates.first { $0.id == summarized.id }?.sections[3].includeFullDictation == nil)
        #expect(store.templates.first { $0.id == bulleted.id }?.sections[3].includeFullDictation == nil)
    }
    @Test func voiceCatalogMigrationPreservesCustomTemplateAndActiveSelection() throws {
        let name = "pflow.template.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let custom = DictationTemplate(name: "My report", sections: [ReportSection(title: "My facts")])
        defaults.set(try JSONEncoder().encode([custom]), forKey: "pflow.templates")
        defaults.set(custom.id.uuidString, forKey: "pflow.template.active")
        let migrated = TemplateStore(defaults: defaults)
        #expect(migrated.active == custom)
        #expect(migrated.templates.contains { $0.name == "Supplement" })
        #expect(migrated.templates.contains { $0.name == "Follow-up report" })
        let ids = migrated.templates.map(\.id)
        #expect(TemplateStore(defaults: defaults).templates.map(\.id) == ids)
    }
    @Test func seededTemplateSelectionAndEditsSurviveRestart() throws {
        let name = "pflow.template.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TemplateStore(defaults: defaults)
        var template = try #require(store.templates.first)
        store.activeID = template.id
        #expect(TemplateStore(defaults: defaults).active?.id == template.id)
        template.name = "My report"
        template.sections.swapAt(0, 2)
        template.headingStyle = .uppercase
        template.missingText = ""
        store.save(template)
        let restored = TemplateStore(defaults: defaults)
        #expect(restored.active == template)
        restored.remove(template.id)
        #expect(TemplateStore(defaults: defaults).active == nil)
    }

    @Test func rendersConfiguredOrderAndMissingFieldsWithoutInventingFacts() {
        var template = DictationTemplate(name: "Test", sections: [ReportSection(title: "Evidence"), ReportSection(title: "Officer")])
        template.headingStyle = .uppercase
        #expect(template.render(["A broken lock.", ""]) == "EVIDENCE\nA broken lock.\n\nOFFICER\nNot provided.")
        template.headingStyle = .markdown
        template.missingText = ""
        #expect(template.render(["One item", ""]).contains("## Officer\n"))
        #expect(TemplateFormatter.removeRepeatedHeading("Officer: Morgan Lee.", title: "Officer") == "Morgan Lee.")
        #expect(TemplateFormatter.removeRepeatedHeading("Officer Morgan Lee.", title: "Officer") == "Officer Morgan Lee.")
        let fields = [ReportSection(title: "Officer"), ReportSection(title: "Date")]
        #expect(TemplateFormatter.normalizeDrafts(["", "", ""], sections: fields) == ["", ""])
        #expect(TemplateFormatter.normalizeDrafts(["Morgan", "", ""], sections: fields) == nil)
    }

    @Test func reportGuardAllowsReorderedRepeatedDatesButRejectsNewNumbersAndUnrelatedAnswers() {
        let input = "Officer Morgan reported theft on October 15 at 14:30 near 12 Oak Street."
        #expect(TemplateFormatter.isGrounded(input: input, output: "October 15, 14:30. Officer Morgan reported theft near 12 Oak Street. At 14:30."))
        #expect(!TemplateFormatter.isGrounded(input: input, output: "Officer Morgan reported theft on October 16."))
        #expect(!TemplateFormatter.isGrounded(input: input, output: "Here is a joke about dancing elephants and flying bicycles."))
        #expect(!TemplateFormatter.isGrounded(input: "Speed was 45.6.", output: "Speed was 6.45."))
        #expect(!TemplateFormatter.isGrounded(input: "At 14:30.", output: "At 30:14."))
        #expect(!TemplateFormatter.isGrounded(input: "On 10/15/2026.", output: "On 15/10/2026."))
        #expect(!TemplateFormatter.isGrounded(input: "The value was -45.6.", output: "The value was 45.6."))
        #expect(TemplateFormatter.isGrounded(input: "Speed was 45.6 at 14:30.", output: "At 14:30, speed was 45.6. Speed was 45.6."))
        #expect(!TemplateFormatter.isGrounded(input: "Counts were 3, 500.", output: "Counts were 3,500."))
        #expect(!TemplateFormatter.isGrounded(input: "Value was 45,6.", output: "Value was 6,45."))
        #expect(!TemplateFormatter.isGrounded(input: "Value was .5.", output: "Value was 5."))
    }
}

@MainActor final class FakeFormatter: TemplateFormatting {
    var output: String? = "Narrative\nSenten was present."
    var receivedTemplates: [DictationTemplate] = []
    var receivedTexts: [String] = []
    func format(_ text: String, using template: DictationTemplate, vocabulary: [String]) async -> String? {
        receivedTemplates.append(template)
        receivedTexts.append(text)
        return output
    }
}

@MainActor
struct TemplateCoordinatorTests {
    @Test func naturalPoliceReportRequestFormatsOnlyTheNarration() async {
        let session = FakeSession()
        session.textToReturn = "This is a police report. So use the police report template. Officer Pesh arrived. No staff were injured."
        let template = DictationTemplate.policeReport
        let formatter = FakeFormatter()
        let injector = FakeInjector()
        let coordinator = makeCoordinator(session: session, injector: injector, formatter: formatter,
            availableTemplates: { [template] })
        await coordinator.toggle()
        await coordinator.finish()
        #expect(formatter.receivedTemplates == [template])
        #expect(formatter.receivedTexts == ["Officer Pesh arrived. No staff were injured."])
        #expect(injector.delivered == [formatter.output!])
    }
    @Test func spokenPrefixChoosesAReportAndDoesNotPasteTheCommand() async {
        let session = FakeSession()
        session.textToReturn = "Write this as a supplement. Officer Pesh arrived."
        let formatter = FakeFormatter()
        let injector = FakeInjector()
        let template = DictationTemplate.supplement
        let coordinator = makeCoordinator(session: session, injector: injector, formatter: formatter,
                                          availableTemplates: { [template] })
        await coordinator.toggle()
        await coordinator.finish()
        #expect(formatter.receivedTemplates == [template])
        #expect(injector.delivered == [formatter.output!])
    }

    @Test func commandAloneSelectsNextFormatWithoutPastingOrLosingIdleState() async {
        let session = FakeSession()
        session.textToReturn = "Write this as a follow up."
        let injector = FakeInjector()
        let template = DictationTemplate.followUp
        var selected: DictationTemplate?
        let coordinator = makeCoordinator(session: session, injector: injector,
            availableTemplates: { [template] }, selectTemplate: { selected = $0 })
        await coordinator.toggle()
        await coordinator.finish()
        #expect(selected == template)
        #expect(injector.delivered.isEmpty)
        #expect(coordinator.state == .idle)
    }
    @Test func capturesSelectedTemplateAtStartAndAppliesDictionaryAfterFormatting() async {
        let formatter = FakeFormatter()
        let injector = FakeInjector()
        let history = FakeHistory()
        let first = DictationTemplate.policeReport
        var selected: DictationTemplate? = first
        let coordinator = makeCoordinator(injector: injector, history: history,
            replacements: [.init(heard: "Senten", replacement: "Sinton")], formatter: formatter,
            activeTemplate: { selected })
        await coordinator.toggle()
        selected = nil
        await coordinator.finish()
        #expect(formatter.receivedTemplates == [first])
        #expect(injector.delivered == ["Narrative\nSinton was present."])
        #expect(history.saved == injector.delivered)
    }

    @Test func failedFormattingKeepsOriginalDictationAndPlainModeSkipsFormatter() async {
        let formatter = FakeFormatter()
        formatter.output = nil
        let injector = FakeInjector()
        var selected: DictationTemplate? = .policeReport
        let coordinator = makeCoordinator(injector: injector, formatter: formatter, activeTemplate: { selected })
        await coordinator.toggle()
        await coordinator.finish()
        #expect(injector.delivered == ["hello world"])
        #expect(formatter.receivedTemplates.count == 1)
        selected = nil
        await coordinator.toggle()
        await coordinator.finish()
        #expect(injector.delivered == ["hello world", "hello world"])
        #expect(formatter.receivedTemplates.count == 1)
    }
}
