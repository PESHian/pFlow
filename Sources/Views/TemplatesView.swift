import SwiftUI

struct TemplatesView: View {
    @Environment(AppState.self) private var app
    var onBack: () -> Void
    @State private var editing: DictationTemplate?

    var body: some View {
        if let draft = editing {
            TemplateEditor(draft: draft, onSave: { app.templates.save($0); editing = nil }, onCancel: { editing = nil })
                .id(draft.id)
        } else {
            VStack(spacing: 0) {
                PageHeader(title: "Templates", onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.s4) {
                        Text("Choose how your next dictations are formatted. The selected template stays active until you change it.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("Say ‘This is a police report, so use the police report template’ or ‘Write this as an initial report’, then narrate. Supplement, follow-up, and custom template names work too. Say only the command to keep that format for following dictations.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button { app.templates.activeID = nil } label: {
                            Label("Plain dictation", systemImage: app.templates.active == nil ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.plain)
                        ForEach(app.templates.templates) { template in
                            Card {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Button { app.templates.activeID = template.id } label: {
                                            Label(template.name, systemImage: app.templates.activeID == template.id ? "checkmark.circle.fill" : "circle")
                                        }.buttonStyle(.plain)
                                        Spacer()
                                        Button("Edit") { editing = template }
                                        Button { app.templates.remove(template.id) } label: { Image(systemName: "trash") }
                                            .help("Delete template")
                                    }
                                    Text(template.sections.map(\.title).joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("New template", systemImage: "plus") {
                            editing = DictationTemplate(name: "New template", sections: [ReportSection(title: "Narrative")])
                        }
                        Text("Formatting uses your selected Apple Intelligence option; on-device is the default. If it cannot format a report, your dictation is pasted as plain text. Reports paste into your current app; fonts, page layout, and printing are controlled there.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(Theme.s5)
                }
            }
        }
    }
}

private struct TemplateEditor: View {
    @State var draft: DictationTemplate
    @State private var voicePhrases: String
    let onSave: (DictationTemplate) -> Void
    let onCancel: () -> Void

    init(draft: DictationTemplate, onSave: @escaping (DictationTemplate) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        _voicePhrases = State(initialValue: draft.voiceTriggers?.joined(separator: ", ") ?? "")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Edit template", onBack: onCancel)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    TextField("Template name", text: $draft.name)
                    TextField("Voice phrases · separate alternatives with commas", text: $voicePhrases)
                    TextField("Report title · optional", text: $draft.title)
                    TextField("Overall instructions", text: $draft.instructions, axis: .vertical).lineLimit(2...5)
                    Picker("Headings", selection: $draft.headingStyle) {
                        ForEach(ReportHeadingStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Bold headings", isOn: Binding(
                        get: { draft.boldHeadings == true },
                        set: { draft.boldHeadings = $0 }))
                    if draft.boldHeadings == true {
                        Text("Bold headings work in apps that accept formatted text. Plain text fields keep the headings without bold.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Text for missing information · leave empty for blank fields", text: $draft.missingText)
                    Text("Headings are printed in your report. The instructions below each heading tell Apple Intelligence what to put in that section.")
                        .font(.caption).foregroundStyle(.secondary)
                    SectionLabel("Sections · in output order")
                    ForEach(Array(draft.sections.enumerated()), id: \.element.id) { index, section in
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Section \(index + 1)").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { draft.sections.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                        .disabled(index == 0).help("Move section up")
                                    Button { draft.sections.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                        .disabled(index + 1 == draft.sections.count).help("Move section down")
                                    Button { draft.sections.remove(at: index) } label: { Image(systemName: "trash") }
                                        .disabled(draft.sections.count == 1).help("Remove section")
                                }
                                TextField("Heading", text: sectionBinding(section, \.title))
                                TextField("What belongs in this section?", text: sectionBinding(section, \.instructions), axis: .vertical)
                                    .lineLimit(2...5)
                                HStack {
                                    Toggle("Bullet points", isOn: sectionBinding(section, \.bullets))
                                    Toggle("Summarize", isOn: sectionBinding(section, \.summarize))
                                }.font(.caption).disabled(section.includeFullDictation == true)
                                Toggle("Include full dictation", isOn: Binding(
                                    get: { sectionBinding(section, \.includeFullDictation).wrappedValue == true },
                                    set: { sectionBinding(section, \.includeFullDictation).wrappedValue = $0 }))
                                    .font(.caption)
                                if section.includeFullDictation == true {
                                    Text("Keeps the full account without summarizing. Adds paragraphs and uses light cleanup when Clean up transcripts is on.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button("Add section", systemImage: "plus") { draft.sections.append(ReportSection(title: "New section")) }
                    Button("Save template") {
                        draft.voiceTriggers = voicePhrases.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        onSave(draft)
                    }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draft.sections.contains { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    Text("Only facts you dictate will be filled in. Review the generated report in your destination app.")
                        .font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(Theme.s5)
            }
        }
    }

    private func sectionBinding<Value>(_ section: ReportSection, _ keyPath: WritableKeyPath<ReportSection, Value>) -> Binding<Value> {
        Binding(get: { draft.sections.first { $0.id == section.id }?[keyPath: keyPath] ?? section[keyPath: keyPath] }, set: { value in
            if let index = draft.sections.firstIndex(where: { $0.id == section.id }) { draft.sections[index][keyPath: keyPath] = value }
        })
    }
}
