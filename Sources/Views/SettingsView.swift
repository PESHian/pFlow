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
            VStack(alignment: .leading, spacing: Theme.s5) {
                PeshHeader()
                AppearanceView()
                templatesSection
                statisticsSection
                historySection
                dictionarySection
                shortcutSection
                transcriptionSection
                intelligenceSection
                languageSection
                generalSection
                inputSection
                if !app.permissions.allGranted {
                    permissionsBanner
                }
                Button("Check for updates…") { MacUpdates.shared.show() }
                aboutSection
            }
            .padding(Theme.s5)
        }
        .onAppear { app.permissions.refresh(); app.launchAtLogin.refresh() }
    }

    private var statisticsSection: some View {
        Button { onOpenStatistics?() } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: "chart.bar.fill").foregroundStyle(Theme.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage statistics").font(.system(size: 13, weight: .medium))
                    Text("Daily words, speaking pace, and activity by app.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(Theme.s4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var templatesSection: some View {
        Button { onOpenTemplates?() } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: "doc.text").foregroundStyle(Theme.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Templates").font(.system(size: 13, weight: .medium))
                    Text(app.templates.active.map { "Active: " + $0.name } ?? "Plain dictation · choose a report format")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(Theme.s4)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var historySection: some View {
        Button {
            onOpenHistory?()
        } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("View history").font(.system(size: 13, weight: .medium))
                    Text("Browse and copy past transcripts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
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

    private var dictionarySection: some View {
        Button {
            onOpenDictionary?()
        } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictionary").font(.system(size: 13, weight: .medium))
                    Text("Teach pFlow names and words it often gets wrong.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
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

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Shortcut")
            Card(padding: Theme.s3) {
                Text("Hold Right Command to dictate. Release to insert. Double-tap for continuous recording; tap again to finish.")
                    .font(.system(size: 13))
            }
        }
    }

    private var languageSection: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Language")
            Card(padding: Theme.s2) {
                HStack(spacing: Theme.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictation language").font(.system(size: 13, weight: .medium))
                        Text("Dictate in a language other than your system's.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.s3)
                    Picker("", selection: $app.dictationLanguage) {
                        Text("System default").tag(AppState.systemLanguage)
                        if !app.availableLocales.isEmpty {
                            Divider()
                            ForEach(app.availableLocales, id: \.identifier) { locale in
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
        @Bindable var app = app
        @Bindable var clipboard = app.clipboardSettings
        return VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("General")
            Card(padding: Theme.s2) {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        title: "Launch at login",
                        subtitle: "Start pFlow automatically when you log in.",
                        isOn: Binding(
                            get: { app.launchAtLogin.isEnabled },
                            set: { app.launchAtLogin.set($0) }
                        )
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Show in Dock",
                        subtitle: app.showInMenuBar
                            ? "Turn off to run from the menu bar only."
                            : "The menu bar icon is off too, so open pFlow from Spotlight to get back here.",
                        isOn: $app.showInDock
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Show in menu bar",
                        subtitle: app.showInDock
                            ? "Turn off to run from the Dock only."
                            : "The Dock icon is off too, so open pFlow from Spotlight to get back here.",
                        isOn: $app.showInMenuBar
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Sound feedback",
                        subtitle: "Play a cue when recording starts and stops.",
                        isOn: $app.soundsEnabled
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Copy dictation to clipboard",
                        subtitle: "Off keeps copied screenshots and text. Your words still go into the current app.",
                        isOn: $clipboard.copyDictation
                    )
                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                    SettingsToggleRow(
                        title: "Clean up transcripts",
                        subtitle: app.cleanup.isAvailable
                            ? "Fix punctuation, format lists, and apply spoken corrections with your selected Apple Intelligence option."
                            : "Requires Apple Intelligence, enabled in System Settings.",
                        isOn: $app.cleanupEnabled
                    )
                    .disabled(!app.cleanup.isAvailable)
                }
            }
        }
    }

    private var intelligenceSection: some View {
        @Bindable var intelligence = intelligence
        return VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Apple Intelligence")
            Card {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    Picker("Cleanup and templates", selection: $intelligence.mode) {
                        Text(IntelligenceMode.onDevice.title).tag(IntelligenceMode.onDevice)
                        Text(IntelligenceMode.privateCloud.title).tag(IntelligenceMode.privateCloud)
                            .disabled(intelligence.cloudUnavailableReason != nil)
                    }
                    .disabled(app.coordinator.state != .idle)
                    Text("On this Mac is the default. Apple Private Cloud Compute sends transcripts, template instructions, and dictionary terms to Apple. Audio stays on this Mac. Cloud processing needs internet access and has Apple usage limits.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let reason = intelligence.cloudUnavailableReason {
                        Text(reason + (intelligence.mode == .privateCloud ? " Using on-device processing instead." : ""))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Link("Apple cloud access requirements", destination: URL(string: "https://developer.apple.com/private-cloud-compute/")!)
                            .font(.system(size: 12))
                    }
                }.padding(Theme.s3)
            }
        }
    }

    private var transcriptionSection: some View {
        @Bindable var app = app
        let model = app.whisperModel
        return VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Speech recognition")
            Card {
                VStack(alignment: .leading, spacing: Theme.s3) {
                    Picker("Transcription engine", selection: $app.transcriptionEngine) {
                        ForEach(TranscriptionEngine.allCases) { engine in Text(engine.title).tag(engine) }
                    }
                    .disabled(app.coordinator.state != .idle)
                    Text("Both run on this Mac. Apple Intelligence handles cleanup with either engine.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if app.transcriptionEngine == .whisper {
                        if model.isReady {
                            Label("Whisper is ready · works offline", systemImage: "checkmark.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if model.isDownloading {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Downloading and checking the model…").font(.system(size: 12))
                                Spacer()
                                Button("Cancel") { model.cancelDownload() }
                            }
                        } else {
                            Text("Whisper Small supports multiple languages. Download it once (488 MB); recordings stay on this Mac.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("Download Whisper model") { model.download() }
                        }
                        if let message = model.errorMessage {
                            Text(message).font(.system(size: 12)).foregroundStyle(.red)
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
                        Text(app.currentInputName ?? "Default microphone")
                            .font(.system(size: 13, weight: .medium))
                        Text("pFlow uses your system default input automatically.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
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
        Button {
            app.openOnboarding()
        } label: {
            HStack(spacing: Theme.s3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Self.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Some permissions are missing")
                        .font(.system(size: 13, weight: .medium))
                    Text("pFlow needs them to hear you and paste into other apps. Review permissions.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            Text("MIT licensed")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

/// Label on the left, switch hard-right. Using `Toggle`'s own label would let
/// each row's text width push its switch to a different x, leaving the column ragged.
private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.s3)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s2 + 2)
    }
}
