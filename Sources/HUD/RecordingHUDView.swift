import SwiftUI

struct RecordingHUDView: View {
    @Bindable var model: HUDModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if model.livePreview {
            LivePreviewCard(model: model, title: title, isRecordingPhase: isRecordingPhase) { status }
        } else {
            compact
        }
    }

    // Live text Off: the waveform capsule, unchanged.
    private var compact: some View {
        status
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 120, height: 32)
        .contentShape(Rectangle())
        .background {
            if isRecordingPhase {
                if reduceTransparency {
                    Capsule().fill(Color(white: 0.08))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.65))
                } else {
                    Capsule().fill(.clear)
                        .glassEffect(.regular, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.gradient.opacity(0.4), lineWidth: 0.65))
                        .allowsHitTesting(false)
                }
            } else {
                RoundedRectangle(cornerRadius: 11)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(Theme.gradient.opacity(0.45), lineWidth: 0.75))
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityLabel(title)
    }

    private var status: some View {
        Group {
            if isRecordingPhase {
                RecordingWaveform(levels: Array(model.levels.suffix(25)),
                                  style: AppearanceSettings.shared.waveformStyle)
            } else if model.phase == .pasteUnconfirmed {
                Label("Check paste", systemImage: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .help("The app could not verify the paste. Check your text before pasting again.")
            } else if model.phase == .copied {
                Label("Press ⌘V", systemImage: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
            } else if model.phase == .savedToHistory {
                Label("Saved in History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
            } else if model.phase == .failed {
                Label("Dictation failed", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            } else if model.phase == .liveTextKept || model.phase == .liveTextKeptTyped {
                Label(model.phase == .liveTextKeptTyped ? "Typed words stay" : "Kept in History",
                      systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .help(title)
            } else if model.phase == .passwordField {
                Label("Password field", systemImage: "lock")
                    .font(.system(size: 11, weight: .medium))
                    .help(title)
            } else if model.phase == .typingStopped {
                Label("Saved in History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .help(title)
            } else if model.phase == .typedTextLeft {
                Label("Typed words kept", systemImage: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                    .help(title)
            } else {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
        }
    }

    static let shadowInsets = EdgeInsets()

    private var isRecordingPhase: Bool {
        model.phase == .listening || model.phase == .confirmCancel
    }

    // Working states with no waveform, so a spinner shows they're still running.
    private var isProcessingPhase: Bool {
        model.phase == .transcribing || model.phase == .cleaning
    }

    private var title: String {
        switch model.phase {
        case .listening: return "Listening"
        case .confirmCancel: return "Press esc again to cancel"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Cleaning up…"
        case .failed: return "Dictation could not finish."
        case .pasteUnconfirmed: return "Paste could not be verified. Check your text before pasting again."
        case .copied: return "Text copied. Press Command V to paste."
        case .savedToHistory: return "Text saved in History. Clipboard unchanged."
        case .restarting: return "Restarting pFlow"
        case .liveTextKept: return "Speech recognition stopped early. The words so far are saved in History."
        case .liveTextKeptTyped:
            return "Speech recognition stopped early. The words already typed stay in your app, and the words so far are saved in History."
        case .passwordField: return "Dictation is off in password fields."
        case .typingStopped: return "Typing stopped, so the finished text is saved in History. Check the words already typed."
        case .typedTextLeft: return "Cancelled. The app changed, so words pFlow already typed are still there."
        }
    }
}

/// Live text: the newest words in a calm floating card. It never takes focus
/// (the panel cannot become key) and keeps the same size for the whole take.
/// Header: Pesh mark, recording dot and a short caption leading, the live
/// waveform trailing. Below a hairline, the transcript fills from the bottom
/// of a fixed box; the top of the box fades so older lines dissolve instead
/// of being cut.
private struct LivePreviewCard<Status: View>: View {
    @Bindable var model: HUDModel
    let title: String
    let isRecordingPhase: Bool
    @ViewBuilder let status: () -> Status
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Lines of transcript kept in view, plus the headroom that fades out.
    private var visibleLines: CGFloat { 3 }
    private var fadeLines: CGFloat { 0.5 }
    private var headerHeight: CGFloat { 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: headerHeight)
                .padding(.horizontal, Theme.s4)
                .padding(.top, Theme.s3)
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2)
            transcript
                .padding(.horizontal, Theme.s4)
                .padding(.bottom, Theme.s3)
        }
        .frame(width: model.previewMaxWidth)
        .contentShape(Rectangle())
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                shape.fill(.regularMaterial)
            }
            shape.strokeBorder(contrast == .increased ? Theme.switchOffStrong : Theme.hairlineStrong,
                               lineWidth: contrast == .increased ? 1 : 0.75)
        }
        .environment(\.colorScheme, model.colorScheme ?? systemScheme)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(model.partial)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.s2) {
            PeshMark(size: 16)
            if isRecordingPhase {
                RecordingDot(pulsing: model.phase == .listening && !reduceMotion)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.liveNote == nil ? title : "pFlow still finishes your words when you stop.")
                Spacer(minLength: Theme.s2)
                RecordingWaveform(levels: Array(model.levels.suffix(25)),
                                  style: AppearanceSettings.shared.waveformStyle, compact: true)
            } else if isProcessingPhase {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                status()
                Spacer(minLength: 0)
            }
        }
    }

    private var caption: String {
        if model.phase == .confirmCancel { return title }
        return model.liveNote ?? "Listening"
    }

    private var isProcessingPhase: Bool {
        model.phase == .transcribing || model.phase == .cleaning
    }

    // A fixed box, filled from the bottom: the newest words stay in view and
    // older lines rise into the fade at the top. The box never changes size
    // while the words grow, so the card does not jitter.
    private var transcript: some View {
        let box = lineHeight * (visibleLines + fadeLines)
        return Text(model.partial)
            .font(textFont)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: box, alignment: .bottomLeading)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: fadeLines * 2 / (visibleLines + fadeLines))],
                               startPoint: .top, endPoint: .bottom)
            }
    }

    // macOS text styles do not grow with the text size setting on their own,
    // so the preview scales its own body size.
    private var textSize: CGFloat {
        let scale: CGFloat = switch typeSize {
        case .xSmall: 0.85
        case .small: 0.92
        case .medium: 0.96
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.24
        case .xxxLarge: 1.36
        case .accessibility1: 1.6
        case .accessibility2: 1.9
        case .accessibility3: 2.2
        case .accessibility4: 2.6
        case .accessibility5: 3
        @unknown default: 1
        }
        return NSFont.systemFontSize * scale
    }

    private var textFont: Font { .system(size: textSize) }

    private var lineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: textSize)
        return ceil(font.ascender - font.descender + font.leading)
    }
}

/// The recording indicator in the card header: a small dot in the recording
/// colour that breathes while pFlow listens (still under Reduce Motion).
private struct RecordingDot: View {
    let pulsing: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.recording)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .onAppear { if pulsing { dim = true } }
            .onChange(of: pulsing) { _, now in dim = now }
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: dim)
            .accessibilityHidden(true)
    }
}

private struct HUDButton: View {
    let systemName: String
    var tint: Color = .secondary
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(prominent ? Color.white : tint)
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(
                        prominent
                            ? Theme.success.opacity(hovering ? 1.0 : 0.9)
                            : Color.primary.opacity(hovering ? 0.14 : 0.08)
                    )
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct RecordingWaveform: View {
    let levels: [Float]
    let style: WaveformStyle
    /// The card header's small waveform: no outline or shadow, 84x16. The
    /// capsule keeps its chrome.
    var compact = false

    var body: some View {
        switch style {
        case .wave:
            Waveform(levels: levels, compact: compact)
        case .lines:
            WaveformLines(levels: AudioLevel.waveformLevels(levels))
                .fill(Theme.gradient)
                .frame(width: compact ? 84 : 100, height: compact ? 16 : 20)
                .shadow(color: .black.opacity(compact ? 0 : 0.25), radius: 1.5, x: 0, y: 1)
        }
    }
}

private struct WaveformLines: Shape {
    let levels: [Float]

    func path(in rect: CGRect) -> Path {
        let samples = levels.isEmpty ? Array(repeating: Float(0), count: 25) : levels
        let spacing = rect.width / CGFloat(samples.count)
        let width = min(2, spacing * 0.65)
        var path = Path()
        for (index, level) in samples.enumerated() {
            let height = max(1.2, CGFloat(level) * rect.height * 0.92)
            let bar = CGRect(x: rect.minX + (CGFloat(index) + 0.5) * spacing - width / 2,
                             y: rect.midY - height / 2, width: width, height: height)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: width / 2, height: width / 2))
        }
        return path
    }
}

/// A connected envelope of real microphone levels, newest on the right.
private struct Waveform: View {
    let levels: [Float]
    var compact = false

    var body: some View {
        let outline = WaveformOutline(levels: AudioLevel.waveformLevels(levels))
        outline
            .fill(Theme.gradient)
            .overlay(outline.stroke(.black.opacity(compact ? 0 : 0.5), lineWidth: 0.75))
            .frame(width: compact ? 84 : 100, height: compact ? 16 : 20)
            .shadow(color: .black.opacity(compact ? 0 : 0.25), radius: 1.5, x: 0, y: 1)
    }
}

private struct WaveformOutline: Shape {
    let levels: [Float]

    func path(in rect: CGRect) -> Path {
        let samples = levels.count > 1 ? levels : [0, 0]
        let upper = samples.enumerated().map { index, level in
            CGPoint(x: rect.minX + CGFloat(index) * rect.width / CGFloat(samples.count - 1),
                    y: rect.midY - max(0.6, CGFloat(level) * rect.height * 0.46))
        }
        let lower = upper.reversed().map { CGPoint(x: $0.x, y: 2 * rect.midY - $0.y) }
        var path = Path()
        path.move(to: upper[0])
        appendCurve(upper, to: &path)
        path.addLine(to: lower[0])
        appendCurve(lower, to: &path)
        path.closeSubpath()
        return path
    }

    private func appendCurve(_ points: [CGPoint], to path: inout Path) {
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + current.x) / 2,
                                         y: (previous.y + current.y) / 2), control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
    }
}
