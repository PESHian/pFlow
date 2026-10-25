import SwiftUI

struct AppearanceView: View {
    @Bindable private var appearance = AppearanceSettings.shared
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            SectionLabel("Make it yours")
            Card {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    HStack {
                        Text("Appearance").peshText(13, .medium)
                        Spacer()
                        Picker("Appearance", selection: $appearance.mode) {
                            ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 205)
                    }
                    // Wraps to a second row when the text size makes four tiles too wide.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84 * Theme.textScale(typeSize)), spacing: 10)], spacing: 10) {
                        ForEach(ColorTheme.allCases) { theme in
                            Button { appearance.theme = theme } label: {
                                VStack(spacing: 7) {
                                    Capsule().fill(palette(for: theme).gradient).frame(height: 7)
                                    Text(theme.title).peshText(11, .medium)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(appearance.theme == theme ? Theme.accent : Theme.hairline, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(theme.title) colors")
                            .accessibilityAddTraits(appearance.theme == theme ? .isSelected : [])
                        }
                    }
                    if appearance.theme == .custom {
                        HStack {
                            ColorPicker("Accent", selection: Binding(
                                get: { appearance.customPrimary.color },
                                set: { appearance.customPrimary = ThemeColor(color: $0) }), supportsOpacity: false)
                            ColorPicker("Wave blend", selection: Binding(
                                get: { appearance.customSecondary.color },
                                set: { appearance.customSecondary = ThemeColor(color: $0) }), supportsOpacity: false)
                        }.peshText(12)
                    }
                    Text("Colors follow you from the app to the recording waveform.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Waveform").peshText(13, .medium)
                    HStack(spacing: 10) {
                        ForEach(WaveformStyle.allCases) { style in
                            Button { appearance.waveformStyle = style } label: {
                                VStack(spacing: 9) {
                                    RecordingWaveform(levels: Self.previewLevels, style: style)
                                    Text(style.title).peshText(11, .medium)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(appearance.waveformStyle == style ? Theme.accent : Theme.hairline, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(style.title) waveform")
                            .accessibilityAddTraits(appearance.waveformStyle == style ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    static let previewLevels: [Float] = [
        0.02, 0.05, 0.12, 0.24, 0.38, 0.24, 0.14, 0.07, 0.16, 0.29, 0.46, 0.33, 0.20,
        0.10, 0.16, 0.28, 0.40, 0.29, 0.16, 0.08, 0.13, 0.23, 0.15, 0.07, 0.02
    ]

    private func palette(for theme: ColorTheme) -> ThemePalette {
        switch theme {
        case .pesh: .pesh
        case .aurora: .aurora
        case .solar: .solar
        case .custom: ThemePalette(primary: appearance.customPrimary, secondary: appearance.customSecondary)
        }
    }
}
