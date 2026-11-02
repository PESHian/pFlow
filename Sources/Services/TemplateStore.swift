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

    /// The one example pFlow offers: on a new install, and once on an update
    /// to someone who has no template by that name.
    static var general: DictationTemplate {
        // Uses every option a template has, so it shows what templates can do:
        // voice phrases, a title, overall instructions, heading style, bold
        // headings, text for missing parts, and sections that summarize, list
        // or keep the full dictation.
        DictationTemplate(name: "General notes", title: "Notes",
            instructions: "Organize what the speaker said. Keep their words, names, numbers and dates. Do not add facts or advice.",
            headingStyle: .uppercase,
            boldHeadings: true,
            missingText: "None mentioned.",
            sections: [
                ReportSection(title: "Summary", instructions: "One or two short sentences on what this is about.", summarize: true),
                ReportSection(title: "Key points", instructions: "The main points, one per line, in the speaker's words.", bullets: true),
                ReportSection(title: "Details", instructions: "Everything the speaker said, in order.", includeFullDictation: true),
                ReportSection(title: "Next steps", instructions: "Only actions or to-dos the speaker stated, with who and when if they said it.", bullets: true)
            ],
            // Never a bare "notes": "Use the notes from Tuesday..." must stay plain dictation.
            voiceTriggers: ["quick notes", "notes template"])
    }

    /// The report examples pFlow 0.3.20 and older put in for everyone. Never
    /// installed again; kept only to recognise a copy nobody has changed.
    static var legacyReportExamples: [DictationTemplate] {
        let police = DictationTemplate(name: "Police report", title: "Incident report",
            instructions: "Write a factual report. Preserve the speaker's perspective. Do not infer facts or include advice.",
            sections: [
                ReportSection(title: "Narrated by", instructions: "The reporting officer's full name, role, agency, and badge number, only if stated. Include the name and badge, not just the agency."),
                ReportSection(title: "Synopsis", instructions: "One or two short sentences summarizing the overall incident and outcome.", summarize: true),
                ReportSection(title: "Date and time", instructions: "The event's date and time, only if stated. Do not use today's date."),
                ReportSection(title: "Narrative", instructions: "All incident details in the order reported. Preserve names, actions, locations, and uncertainty.", includeFullDictation: true),
                ReportSection(title: "Evidence", instructions: "Only evidence explicitly described. Do not assume collection, custody, or test results.", bullets: true)
            ], voiceTriggers: ["initial report", "police report"])
        var supplement = police
        supplement.name = "Supplement"
        supplement.title = "Supplemental report"
        supplement.instructions = "Document only the additional information dictated. Do not assume facts from an earlier report."
        supplement.voiceTriggers = ["supplement", "supplemental report"]
        var followUp = police
        followUp.name = "Follow-up report"
        followUp.title = "Follow-up report"
        followUp.instructions = "Document the follow-up actions and findings dictated. Do not assume earlier incident facts."
        followUp.voiceTriggers = ["follow up", "follow-up report"]
        return [police, supplement, followUp]
    }

    /// True only for one of those examples exactly as pFlow put it in (an
    /// older copy's wording or settings included). Any change the person
    /// made, even one word or the bold setting, makes it theirs.
    var isUntouchedLegacyExample: Bool {
        func shape(_ value: DictationTemplate) -> DictationTemplate {
            var value = value
            value.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            for index in value.sections.indices { value.sections[index].id = value.id }
            return value
        }
        let mine = shape(self)
        for example in Self.legacyReportExamples {
            var older = example
            older.sections[0].instructions = "The reporting officer's name and role, only if stated."
            older.sections[3].includeFullDictation = nil
            var noTriggers = example
            noTriggers.voiceTriggers = nil
            var oldest = older
            oldest.voiceTriggers = nil
            if [example, older, noTriggers, oldest].contains(where: { shape($0) == mine }) { return true }
        }
        return false
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

    static let savedKey = "pflow.templates"
    /// Saved templates this version could not read, kept as they were.
    static let unreadableKey = "pflow.templates.unreadable"

    /// 2: the report examples nobody changed are gone and General notes was
    /// offered once. Never runs again, so a removed General notes stays removed.
    static let catalogKey = "pflow.templates.catalog"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var changed = false
        if let data = defaults.data(forKey: Self.savedKey) {
            if let saved = try? JSONDecoder().decode([DictationTemplate].self, from: data) {
                templates = saved
                if defaults.integer(forKey: Self.catalogKey) < 2 {
                    // An update: drop only the untouched old examples; the person's own
                    // templates, and any example they changed, stay exactly as saved.
                    templates.removeAll { $0.isUntouchedLegacyExample }
                    if !templates.contains(where: { $0.name.caseInsensitiveCompare(DictationTemplate.general.name) == .orderedSame }) {
                        templates.append(.general)
                    }
                    changed = templates != saved
                }
            } else {
                // Never write over templates pFlow cannot read: keep the bytes aside.
                if defaults.data(forKey: Self.unreadableKey) == nil { defaults.set(data, forKey: Self.unreadableKey) }
                templates = []
            }
        } else {
            templates = [.general]
            changed = true
        }
        activeID = defaults.string(forKey: "pflow.template.active").flatMap(UUID.init(uuidString:))
        // Saved before General notes can be selected, so its ID lasts.
        if changed { persist() }
        defaults.set(2, forKey: Self.catalogKey)
        // pFlow 0.3.20 and older add their report examples when this is unset.
        // Set it so going back to an older copy adds nothing either.
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
        defaults.set(data, forKey: Self.savedKey)
    }
}
