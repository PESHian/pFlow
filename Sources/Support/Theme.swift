import SwiftUI

/// A shadcn-like design token set.
enum Theme {
    static let radiusLarge: CGFloat = 16
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8

    static let hairline = Color.primary.opacity(0.10)
    static let hairlineStrong = Color.primary.opacity(0.14)
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.102, green: 0.082, blue: 0.149, alpha: 0.85)
            : NSColor.white.withAlphaComponent(0.78)
    })
    static let surfaceHover = Color.primary.opacity(0.06)
    static let switchOff = Color.primary.opacity(0.22)
    static let switchOffStrong = Color.primary.opacity(0.38)

    static let recording = Color(red: 0.90, green: 0.29, blue: 0.35)
    static let success = Color(red: 0.20, green: 0.68, blue: 0.45)
    @MainActor static var accent: Color { AppearanceSettings.shared.palette.primary.color }
    @MainActor static var gradient: LinearGradient { AppearanceSettings.shared.palette.gradient }

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 28
}

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.s4
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.75)
            )
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .peshText(10, .medium, design: .monospaced)
            .tracking(2)
            .foregroundStyle(.tertiary)
    }
}

extension Theme {
    /// How much larger the person asked text to be (System Settings >
    /// Accessibility > Display > Text size, per app). The page's point sizes
    /// are multiplied by this, so every row must still fit at the largest.
    static func textScale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.85
        case .small: 0.9
        case .medium: 0.95
        case .large: 1
        case .xLarge: 1.1
        case .xxLarge: 1.2
        case .xxxLarge: 1.3
        case .accessibility1: 1.45
        case .accessibility2: 1.6
        case .accessibility3: 1.8
        case .accessibility4: 2
        case .accessibility5: 2.2
        @unknown default: 1
        }
    }
}

/// A point size that follows the person's text size setting.
private struct ScaledText: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.font(.system(size: size * Theme.textScale(typeSize), weight: weight, design: design))
    }
}

extension View {
    /// Text at `size` points at the normal text size, larger when the person asked for larger text.
    func peshText(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledText(size: size, weight: weight, design: design))
    }
}

/// One choice among a few shown side by side, the look of the palette and
/// waveform tiles. It shrinks with the window: the label wraps instead of
/// holding a width, so a row of tiles never grows wider than its column.
struct ChoiceTile: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .peshText(11, .medium)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Theme.accent : Theme.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .peshText(13, .semibold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .background(Color.primary.opacity(configuration.isPressed ? 0.75 : 0.9),
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .peshText(13, .medium)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Theme.surfaceHover : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

/// The app's on/off switch: green track with a white knob when on, grey when off.
/// macOS draws an "on" switch grey whenever its window is not in front, which
/// in dark mode looks exactly like "off". This one looks the same either way.
struct PeshSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        PeshSwitch(configuration: configuration)
    }
}

extension ToggleStyle where Self == PeshSwitchStyle {
    static var peshSwitch: PeshSwitchStyle { PeshSwitchStyle() }
}

private struct PeshSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.labelsVisibility) private var labels

    var body: some View {
        HStack(spacing: Theme.s2) {
            if labels != .hidden { configuration.label }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
            } label: { track }
                .buttonStyle(.plain)
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private var track: some View {
        let on = configuration.isOn
        let strong = contrast == .increased
        return Capsule()
            .fill(on ? Theme.success : (strong ? Theme.switchOffStrong : Theme.switchOff))
            .overlay(Capsule().strokeBorder(strong ? Color.primary.opacity(0.7) : Theme.hairline,
                                            lineWidth: strong ? 1 : 0.5))
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(strong ? 0.5 : 0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .frame(width: 40, height: 22)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}
