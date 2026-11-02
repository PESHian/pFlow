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

    /// The one example a new install starts with. Upgrades never get it:
    /// pFlow adds, changes or removes no template a person already has.
    static var general: DictationTemplate {
        DictationTemplate(name: "General notes", title: "Notes",
            instructions: "Organize what the speaker said. Keep their words, names and numbers. Do not add facts or advice.",
            missingText: "None.",
            sections: [
                ReportSection(title: "Summary", instructions: "One or two short sentences on what this is about.", summarize: true),
                ReportSection(title: "Details", instructions: "Everything the speaker said, in order.", includeFullDictation: true),
                ReportSection(title: "Next steps", instructions: "Only actions or to-dos the speaker stated.", bullets: true)
            ], voiceTriggers: ["notes"])
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var isNewInstall = false
        if let data = defaults.data(forKey: Self.savedKey) {
            if let saved = try? JSONDecoder().decode([DictationTemplate].self, from: data) {
                templates = saved
            } else {
                // Never write over templates pFlow cannot read: keep the bytes aside.
                if defaults.data(forKey: Self.unreadableKey) == nil { defaults.set(data, forKey: Self.unreadableKey) }
                templates = []
            }
        } else {
            templates = [.general]
            isNewInstall = true
        }
        activeID = defaults.string(forKey: "pflow.template.active").flatMap(UUID.init(uuidString:))
        // A new install only. Saved before it can be selected, so its ID lasts.
        if isNewInstall { persist() }
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
