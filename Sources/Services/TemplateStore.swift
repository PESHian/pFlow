import Foundation
import Observation

enum ReportHeadingStyle: String, Codable, CaseIterable, Identifiable {
    case plain, uppercase, markdown
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ReportSection: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var instructions = ""
    var bullets = false
    var summarize = false
    var includeFullDictation: Bool?
}

struct DictationTemplate: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var title = ""
    var instructions = ""
    var headingStyle: ReportHeadingStyle = .plain
    var boldHeadings: Bool?
    var missingText = "Not provided."
    var sections: [ReportSection]
    var voiceTriggers: [String]?

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

    /// Titles/order/formatting come from the user's template, never the model.
    func render(_ bodies: [String], source: String? = nil) -> String {
        renderStyled(bodies, source: source).string
    }

    func renderStyled(_ bodies: [String], source: String? = nil) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        func append(_ heading: String, body: String? = nil) {
            if output.length > 0 { output.append(NSAttributedString(string: "\n\n")) }
            let start = output.length
            output.append(NSAttributedString(string: heading))
            if boldHeadings == true, !heading.isEmpty {
                output.addAttribute(TemplateTextStyle.heading, value: true,
                                    range: NSRange(location: start, length: (heading as NSString).length))
            }
            if let body { output.append(NSAttributedString(string: "\n" + body)) }
        }
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { append(title) }
        for (index, section) in sections.enumerated() {
            let body = section.includeFullDictation == true && source != nil
                ? source! : (index < bodies.count ? bodies[index].trimmingCharacters(in: .whitespacesAndNewlines) : "")
            let heading: String
            switch headingStyle {
            case .plain: heading = section.title
            case .uppercase: heading = section.title.uppercased()
            case .markdown: heading = "## " + section.title
            }
            append(heading, body: body.isEmpty ? missingText : body)
        }
        return NSAttributedString(attributedString: output)
    }
}

@MainActor
@Observable
final class TemplateStore {
    private let defaults: UserDefaults
    private(set) var templates: [DictationTemplate]
    var activeID: UUID? {
        didSet {
            if let activeID { defaults.set(activeID.uuidString, forKey: "pflow.template.active") }
            else { defaults.removeObject(forKey: "pflow.template.active") }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "pflow.templates"),
           let saved = try? JSONDecoder().decode([DictationTemplate].self, from: data) {
            templates = saved
        } else { templates = [.policeReport] }
        activeID = defaults.string(forKey: "pflow.template.active").flatMap(UUID.init(uuidString:))
        if defaults.integer(forKey: "pflow.templates.voiceCatalog") < 1 {
            for index in templates.indices where templates[index].name == "Police report" && templates[index].voiceTriggers == nil {
                templates[index].voiceTriggers = ["initial report", "police report"]
            }
            for example in [DictationTemplate.supplement, .followUp] {
                if !templates.contains(where: { $0.name.caseInsensitiveCompare(example.name) == .orderedSame }) {
                    templates.append(example)
                }
            }
        }
        // Update only unchanged factory sections. Explicit choices and edited
        // templates remain intact, including an explicit false for full text.
        let factory = DictationTemplate.policeReport
        for index in templates.indices where ["Police report", "Supplement", "Follow-up report"].contains(templates[index].name) {
            for field in templates[index].sections.indices {
                let section = templates[index].sections[field]
                if section.title == "Narrative", section.includeFullDictation == nil,
                   !section.summarize, !section.bullets,
                   section.instructions == factory.sections[3].instructions {
                    templates[index].sections[field].includeFullDictation = true
                }
                if section.title == "Narrated by", section.instructions == "The reporting officer's name and role, only if stated." {
                    templates[index].sections[field].instructions = factory.sections[0].instructions
                }
            }
        }
        // Persist the seeded example's UUID before it can be selected. Otherwise
        // the active template would disappear on the next launch.
        persist()
        defaults.set(1, forKey: "pflow.templates.voiceCatalog")
        if activeID != nil, active == nil { activeID = nil; defaults.removeObject(forKey: "pflow.template.active") }
    }

    var active: DictationTemplate? { templates.first { $0.id == activeID } }

    func save(_ template: DictationTemplate) {
        guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !template.sections.isEmpty else { return }
        if let index = templates.firstIndex(where: { $0.id == template.id }) { templates[index] = template }
        else { templates.append(template) }
        persist()
    }

    func remove(_ id: UUID) {
        templates.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: "pflow.templates")
    }
}
