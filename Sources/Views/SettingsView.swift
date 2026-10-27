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
        // A take started while a key was being learned: stop listening, the key stays.
        .onChange(of: app.coordinator.state == .idle) { _, idle in
            if !idle { app.keyLearning.stop() }
        }
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
            activationKey: $app.activationKey,
            learningKey: app.keyLearning.listening,
            learningNote: app.keyLearning.note,
            learnKey: { app.learnActivationKey() },
            cancelLearning: { app.keyLearning.stop() },
            liveTextMode: $app.liveTextMode,
            engine: $app.transcriptionEngine,
            idle: app.coordinator.state == .idle,
            whisper: whisper.isReady ? .ready : whisper.isDownloading ? .downloading : .missing,
            whisperReceivedBytes: whisper.receivedBytes,
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
    var activationKey: Binding<ActivationKey> = .constant(.rightCommand)
    /// Settings → Shortcut → Press a key is listening.
    var learningKey = false
    /// Why the last key pressed can't be used.
    var learningNote: String?
    var learnKey: () -> Void = {}
    var cancelLearning: () -> Void = {}
    var liveTextMode: Binding<LiveTextMode>
    var engine: Binding<TranscriptionEngine>
    var idle = true
    var whisper: WhisperState = .missing
    /// Bytes downloaded so far, for the progress line while `.downloading`.
    var whisperReceivedBytes: Int64 = 0
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

/// The one rule for every download control in Settings: what the Speech
/// recognition card shows for the Whisper model in each state. Before the
/// download, one "Download (488 MB)" button; while it runs, the bar and the
/// plain byte count directly under it and one "Cancel"; once it is here, a
/// "Downloaded" line and no button. Nothing is shown that cannot be acted on
/// right now: the person may be tired or in a hurry.
struct DownloadControls: Equatable {
    enum Button: Equatable {
        case download, cancel
        var title: String {
            switch self {
            case .download: return "Download (\(DownloadControls.size))"
            case .cancel: return "Cancel"
            }
        }
    }

    let line: String
    let button: Button?
    /// The progress bar is drawn above the line.
    let bar: Bool
    let done: Bool

    static let total = WhisperModelStore.expectedBytes
    static var size: String { megabytes(total) }

    static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    static func describe(_ state: SettingsPageModel.WhisperState, received: Int64) -> DownloadControls {
        switch state {
        case .missing:
            return DownloadControls(line: "Whisper Small supports multiple languages. Download it once; recordings stay on this Mac.",
                                    button: .download, bar: false, done: false)
        case .downloading:
            return DownloadControls(line: "Downloading… \(megabytes(received)) of \(size)", button: .cancel, bar: true, done: false)
        case .ready:
            return DownloadControls(line: "Downloaded · \(size) · works offline", button: nil, bar: false, done: true)
        }
    }
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

    /// The list, with a learned key in it while that key is chosen.
    private var keyChoices: [ActivationKey] {
        let key = model.activationKey.wrappedValue
        return ActivationKey.presets.contains(key) ? ActivationKey.presets : ActivationKey.presets + [key]
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Shortcut")
            Card(padding: Theme.s2) {
                VStack(spacing: 0) {
                    HStack(spacing: Theme.s3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Activation key").peshText(13, .medium)
                            Text("Hold \(model.activationKey.wrappedValue.name) to dictate. Release to insert. Double-tap it for continuous recording; tap again to finish.")
                                .peshText(12).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.s3)
                        Picker("", selection: model.activationKey) {
                            ForEach(keyChoices) { key in Text(key.name).tag(key) }
                        }
                        .labelsHidden()
                        .frame(width: 168)
                        .disabled(!model.idle || model.learningKey)
                    }
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, Theme.s2 + 2)
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    HStack(spacing: Theme.s3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.learningKey ? "Press the key you want to use" : "Use another key").peshText(13, .medium)
                            Text(model.learningKey
                                 ? model.learningNote ?? "Press it and let go. On a laptop, hold fn for an F key. Escape cancels."
                                 : "Press a key that doesn't type, like an F key, and pFlow learns it.")
                                .peshText(12).foregroundStyle(model.learningNote == nil ? .secondary : .primary)
                        }
                        Spacer(minLength: Theme.s3)
                        if model.learningKey {
                            Button("Cancel", action: model.cancelLearning)
                        } else {
                            Button("Press a key…", action: model.learnKey)
                                .disabled(!model.idle)
                        }
                    }
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, Theme.s2 + 2)
                }
            }
        }
    }

    private var liveTextSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Live text")
            Card {
                LiveTextPicker(mode: model.liveTextMode, engine: model.engine.wrappedValue)
            }
            if model.liveTextMode.wrappedValue == .typeInApp {
                InputMethodSetupRow()
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
                        // One state, one set of controls: nothing is shown
                        // that cannot be acted on right now (no Cancel unless
                        // a download is running, no Download once it is here).
                        let controls = DownloadControls.describe(model.whisper, received: model.whisperReceivedBytes)
                        if controls.bar {
                            ProgressView(value: Double(min(model.whisperReceivedBytes, DownloadControls.total)),
                                         total: Double(DownloadControls.total))
                                .progressViewStyle(.linear)
                                .tint(Theme.accent)
                        }
                        HStack {
                            if controls.done {
                                Label(controls.line, systemImage: "checkmark.circle").peshText(12).foregroundStyle(.secondary)
                            } else {
                                Text(controls.line).peshText(12).foregroundStyle(controls.bar ? .primary : .secondary)
                            }
                            Spacer()
                            if let button = controls.button {
                                Button(button.title, action: button == .cancel ? model.cancelWhisperDownload : model.downloadWhisper)
                            }
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
            note = "Types your words into the app as you talk, a little behind, and puts in the finished text when you stop. If you move the cursor, type, or switch apps, typing stops and the finished text is saved in History. If the words cannot go in, a card with Copy shows them when you stop. Template styles such as bold arrive as plain text."
        }
        if engine == .whisper {
            note += " With Whisper, words show about a second behind, and the finished text can differ a little from the words typed as you talk."
        }
        return note
    }
}
