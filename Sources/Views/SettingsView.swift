import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var intelligence = IntelligenceSettings.shared
    var onOpenHistory: (() -> Void)?
    var onOpenDictionary: (() -> Void)?
    var onOpenStatistics: (() -> Void)?
    var onOpenTemplates: (() -> Void)?

    var body: some View {
        ScrollView {
            SettingsContent(model: model)
        }
        .onAppear { app.permissions.refresh(); app.launchAtLogin.refresh() }
    }

    /// Everything the page shows, read from the app once per draw. The page
    /// itself (`SettingsContent`) never touches `AppState`, so the layout check
    /// can draw it with fictional values.
    private var model: SettingsPageModel {
        @Bindable var app = app
        @Bindable var clipboard = app.clipboardSettings
        @Bindable var intelligence = intelligence
        let whisper = app.whisperModel
        return SettingsPageModel(
            activeTemplate: app.templates.active?.name,
            openTemplates: { onOpenTemplates?() },
            openStatistics: { onOpenStatistics?() },
            openHistory: { onOpenHistory?() },
            openDictionary: { onOpenDictionary?() },
            liveTextMode: $app.liveTextMode,
            engine: $app.transcriptionEngine,
            idle: app.coordinator.state == .idle,
            whisper: whisper.isReady ? .ready : whisper.isDownloading ? .downloading : .missing,
            whisperError: whisper.errorMessage,
            downloadWhisper: { whisper.download() },
            cancelWhisperDownload: { whisper.cancelDownload() },
            intelligenceMode: $intelligence.mode,
            cloudUnavailableReason: intelligence.cloudUnavailableReason,
            language: $app.dictationLanguage,
            locales: app.availableLocales,
            launchAtLogin: Binding(get: { app.launchAtLogin.isEnabled }, set: { app.launchAtLogin.set($0) }),
            showInDock: $app.showInDock,
            showInMenuBar: $app.showInMenuBar,
            sounds: $app.soundsEnabled,
            copyDictation: $clipboard.copyDictation,
            cleanup: $app.cleanupEnabled,
            cleanupAvailable: app.cleanup.isAvailable,
            inputName: app.currentInputName,
            permissionsMissing: !app.permissions.allGranted,
            reviewPermissions: { app.openOnboarding() },
            checkForUpdates: { MacUpdates.shared.show() }
        )
    }
}

/// Plain values and bindings for one draw of the Settings page.
struct SettingsPageModel {
    enum WhisperState { case ready, downloading, missing }

    var activeTemplate: String?
    var openTemplates: () -> Void = {}
    var openStatistics: () -> Void = {}
    var openHistory: () -> Void = {}
    var openDictionary: () -> Void = {}
    var liveTextMode: Binding<LiveTextMode>
    var engine: Binding<TranscriptionEngine>
    var idle = true
    var whisper: WhisperState = .missing
    var whisperError: String?
    var downloadWhisper: () -> Void = {}
    var cancelWhisperDownload: () -> Void = {}
    var intelligenceMode: Binding<IntelligenceMode>
    var cloudUnavailableReason: String?
    var language: Binding<String>
    var locales: [Locale] = []
    var launchAtLogin: Binding<Bool>
    var showInDock: Binding<Bool>
    var showInMenuBar: Binding<Bool>
    var sounds: Binding<Bool>
    var copyDictation: Binding<Bool>
    var cleanup: Binding<Bool>
    var cleanupAvailable = true
    var inputName: String?
    var permissionsMissing = false
    var reviewPermissions: () -> Void = {}
    var checkForUpdates: () -> Void = {}
}

/// The Settings page content, in order. Each section must fit the window at
/// its minimum width (`MainWindowView.minimumSize`): the vertical scroll view
/// takes the widest section's own width, and anything wider than the window
/// is centred and cut off on both sides.
struct SettingsContent: View {
    let model: SettingsPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s5) {
            ForEach(Array(sections.enumerated()), id: \.offset) { $0.element.view }
        }
        .padding(Theme.s5)
    }

    /// Every section the page draws, by name, in page order. The layout check
    /// draws each one on its own and all of them together.
    var sections: [(name: String, view: AnyView)] {
        var sections: [(name: String, view: AnyView)] = [
            ("Header", AnyView(PeshHeader())),
            ("Make it yours", AnyView(AppearanceView())),
            ("Templates", AnyView(SettingsLinkRow(
                icon: "doc.text", title: "Templates",
                subtitle: model.activeTemplate.map { "Active: " + $0 } ?? "Plain dictation · choose a report format",
                action: model.openTemplates))),
            ("Usage statistics", AnyView(SettingsLinkRow(
                icon: "chart.bar.fill", title: "Usage statistics",
                subtitle: "Daily words, speaking pace, and activity by app.",
                action: model.openStatistics))),
            ("View history", AnyView(SettingsLinkRow(
                icon: "clock.arrow.circlepath", title: "View history",
                subtitle: "Browse and copy past transcripts.",
                action: model.openHistory))),
            ("Dictionary", AnyView(SettingsLinkRow(
                icon: "character.book.closed", title: "Dictionary",
                subtitle: "Teach pFlow names and words it often gets wrong.",
                action: model.openDictionary))),
            ("Shortcut", AnyView(shortcutSection)),
            ("Live text", AnyView(liveTextSection)),
            ("Speech recognition", AnyView(transcriptionSection)),
            ("Apple Intelligence", AnyView(intelligenceSection)),
            ("Language", AnyView(languageSection)),
            ("General", AnyView(generalSection)),
            ("Microphone", AnyView(inputSection)),
        ]
        if model.permissionsMissing {
            sections.append(("Permissions", AnyView(permissionsBanner)))
        }
        sections.append(("Updates", AnyView(Button("Check for updates…", action: model.checkForUpdates))))
        sections.append(("About", AnyView(aboutSection)))
        return sections
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Shortcut")
            Card(padding: Theme.s3) {
                Text("Hold Right Command to dictate. Release to insert. Double-tap for continuous recording; tap again to finish.")
                    .peshText(13)
            }
        }
    }

    private var liveTextSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Live text")
            Card {
                LiveTextPicker(mode: model.liveTextMode, engine: model.engine.wrappedValue)
            }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Language")
            Card(padding: Theme.s2) {
                HStack(spacing: Theme.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictation language").peshText(13, .medium)
                        Text("Dictate in a language other than your system's.")
                            .peshText(12).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.s3)
                    Picker("", selection: model.language) {
                        Text("System default").tag(AppState.systemLanguage)
                        if !model.locales.isEmpty {
                            Divider()
                            ForEach(model.locales, id: \.identifier) { locale in
                                Text(AppState.languageName(for: locale))
                                    .tag(locale.identifier(.bcp47))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 168)
                }
                .padding(.horizontal, Theme.s3)
                .padding(.vertical, Theme.s2 + 2)
            }
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("General")
            Card(padding: Theme.s2) {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        title: "Launch at login",
                        subtitle: "Start pFlow automatically when you log in.",
                        isOn: model.launchAtLogin
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Show in Dock",
                        subtitle: model.showInMenuBar.wrappedValue
                            ? "Turn off to run from the menu bar only."
                            : "The menu bar icon is off too, so open pFlow from Spotlight to get back here.",
                        isOn: model.showInDock
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Show in menu bar",
                        subtitle: model.showInDock.wrappedValue
                            ? "Turn off to run from the Dock only."
                            : "The Dock icon is off too, so open pFlow from Spotlight to get back here.",
                        isOn: model.showInMenuBar
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Sound feedback",
                        subtitle: "Play a cue when recording starts and stops.",
                        isOn: model.sounds
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Copy dictation to clipboard",
                        subtitle: "Off keeps copied screenshots and text. Your words still go into the current app.",
                        isOn: model.copyDictation
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Clean up transcripts",
                        subtitle: model.cleanupAvailable
                            ? "Fix punctuation, format lists, and apply spoken corrections with your selected Apple Intelligence option."
                            : "Requires Apple Intelligence, enabled in System Settings.",
                        isOn: model.cleanup
                    )
                    .disabled(!model.cleanupAvailable)
                }
            }
        }
    }

    private var intelligenceSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Apple Intelligence")
            Card {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    Picker("Cleanup and templates", selection: model.intelligenceMode) {
                        Text(IntelligenceMode.onDevice.title).tag(IntelligenceMode.onDevice)
                        Text(IntelligenceMode.privateCloud.title).tag(IntelligenceMode.privateCloud)
                            .disabled(model.cloudUnavailableReason != nil)
                    }
                    .disabled(!model.idle)
                    Text("On this Mac is the default. Apple Private Cloud Compute sends transcripts, template instructions, and dictionary terms to Apple. Audio stays on this Mac. Cloud processing needs internet access and has Apple usage limits.")
                        .peshText(12).foregroundStyle(.secondary)
                    if let reason = model.cloudUnavailableReason {
                        Text(reason + (model.intelligenceMode.wrappedValue == .privateCloud ? " Using on-device processing instead." : ""))
                            .peshText(12).foregroundStyle(.secondary)
                        Link("Apple cloud access requirements", destination: URL(string: "https://developer.apple.com/private-cloud-compute/")!)
                            .peshText(12)
                    }
                }.padding(Theme.s3)
            }
        }
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Speech recognition")
            Card {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    Picker("Transcription engine", selection: model.engine) {
                        ForEach(TranscriptionEngine.allCases) { engine in Text(engine.title).tag(engine) }
                    }
                    .disabled(!model.idle)
                    Text("Both run on this Mac. Apple Intelligence handles cleanup with either engine.")
                        .peshText(12).foregroundStyle(.secondary)
                    if model.engine.wrappedValue == .whisper {
                        switch model.whisper {
                        case .ready:
                            Label("Whisper is ready · works offline", systemImage: "checkmark.circle")
                                .peshText(12).foregroundStyle(.secondary)
                        case .downloading:
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Downloading and checking the model…").peshText(12)
                                Spacer()
                                Button("Cancel", action: model.cancelWhisperDownload)
                            }
                        case .missing:
                            Text("Whisper Small supports multiple languages. Download it once (488 MB); recordings stay on this Mac.")
                                .peshText(12).foregroundStyle(.secondary)
                            Button("Download Whisper model", action: model.downloadWhisper)
                        }
                        if let message = model.whisperError {
                            Text(message).peshText(12).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Microphone")
            Card {
                HStack(spacing: Theme.s3) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.inputName ?? "Default microphone")
                            .peshText(13, .medium)
                        Text("pFlow uses your system default input automatically.")
                            .peshText(12).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    // Shown only when something is missing. Tapping it reopens onboarding, which
    // is where permissions are actually granted, so Settings stays uncluttered
    // once everything is in place.
    private var permissionsBanner: some View {
        Button(action: model.reviewPermissions) {
            HStack(spacing: Theme.s3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .peshText(15)
                    .foregroundStyle(Self.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Some permissions are missing")
                        .peshText(13, .medium)
                    Text("pFlow needs them to hear you and paste into other apps. Review permissions.")
                        .peshText(12).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .peshText(11, .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Self.warning.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static let warning = Color(red: 0.95, green: 0.64, blue: 0.16)

    private var aboutSection: some View {
        HStack {
            Text("pFlow · by Pesh")
                .peshText(11).foregroundStyle(.tertiary)
            Spacer()
            Text("MIT licensed")
                .peshText(11).foregroundStyle(.tertiary)
        }
    }
}

/// One row that opens another page: Templates, Usage statistics, View history,
/// Dictionary. One look, and a fixed icon column so the titles line up.
struct SettingsLinkRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s3) {
                Image(systemName: icon)
                    .peshText(15)
                    .foregroundStyle(Theme.gradient)
                    .frame(minWidth: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).peshText(13, .medium)
                    Text(subtitle).peshText(12).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .peshText(11, .semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Label on the left, switch hard-right. Using `Toggle`'s own label would let
/// each row's text width push its switch to a different x, leaving the column ragged.
struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).peshText(13, .medium)
                Text(subtitle).peshText(12).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.s3)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.peshSwitch)
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2 + 2)
    }
}

/// The Live text choice, all three options in view as tiles, and a plain note
/// on what the selected one does. Settings shows it once, in its own section.
/// A segmented control cannot shrink below its labels and made the whole page
/// wider than the window; tiles wrap their titles.
struct LiveTextPicker: View {
    @Binding var mode: LiveTextMode
    let engine: TranscriptionEngine
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            // Wraps to more rows when the text size makes the tiles too wide.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110 * Theme.textScale(typeSize)), spacing: 10)], spacing: 10) {
                ForEach(LiveTextMode.allCases) { choice in
                    ChoiceTile(title: choice.title, selected: mode == choice) { mode = choice }
                        .accessibilityLabel("Live text: \(choice.title)")
                }
            }
            Text(note)
                .peshText(12).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: String {
        var note: String
        switch mode {
        case .off:
            return "Words appear in your app after you stop talking."
        case .typeInApp:
            note = "Types your words into the app as you talk, a little behind, and puts in the finished text when you stop. If you move the cursor, type, or switch apps, typing stops and the finished text is saved in History. Apps that don't allow this show the preview instead. Template styles such as bold arrive as plain text."
        }
        if engine == .whisper {
            note += " With Whisper, words show about a second behind, and the finished text can differ a little from the preview."
        }
        return note
    }
}
