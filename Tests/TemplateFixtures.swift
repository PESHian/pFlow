@testable import Yap

/// The report templates pFlow 0.3.20 and older shipped. pFlow no longer ships
/// them; tests use them as realistic saved templates of a person upgrading.
extension DictationTemplate {
    static var policeReport: DictationTemplate {
        DictationTemplate(name: "Police report", title: "Incident report",
            instructions: "Write a factual report. Preserve the speaker's perspective. Do not infer facts or include advice.",
            sections: [
                ReportSection(title: "Narrated by", instructions: "The reporting officer's full name, role, agency, and badge number, only if stated. Include the name and badge, not just the agency."),
                ReportSection(title: "Synopsis", instructions: "One or two short sentences summarizing the overall incident and outcome.", summarize: true),
                ReportSection(title: "Date and time", instructions: "The event's date and time, only if stated. Do not use today's date."),
                ReportSection(title: "Narrative", instructions: "All incident details in the order reported. Preserve names, actions, locations, and uncertainty.", includeFullDictation: true),
                ReportSection(title: "Evidence", instructions: "Only evidence explicitly described. Do not assume collection, custody, or test results.", bullets: true)
            ], voiceTriggers: ["initial report", "police report"])
    }

    static var supplement: DictationTemplate {
        var value = policeReport
        value.name = "Supplement"
        value.title = "Supplemental report"
        value.instructions = "Document only the additional information dictated. Do not assume facts from an earlier report."
        value.voiceTriggers = ["supplement", "supplemental report"]
        return value
    }

    static var followUp: DictationTemplate {
        var value = policeReport
        value.name = "Follow-up report"
        value.title = "Follow-up report"
        value.instructions = "Document the follow-up actions and findings dictated. Do not assume earlier incident facts."
        value.voiceTriggers = ["follow up", "follow-up report"]
        return value
    }
}
