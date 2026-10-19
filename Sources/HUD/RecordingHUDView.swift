import SwiftUI

struct RecordingHUDView: View {
    @Bindable var model: HUDModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
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
            } else {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
        }
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
        }
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

    var body: some View {
        switch style {
        case .wave:
            Waveform(levels: levels)
        case .lines:
            WaveformLines(levels: AudioLevel.waveformLevels(levels))
                .fill(Theme.gradient)
                .frame(width: 100, height: 20)
                .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
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

    var body: some View {
        let outline = WaveformOutline(levels: AudioLevel.waveformLevels(levels))
        outline
            .fill(Theme.gradient)
            .overlay(outline.stroke(.black.opacity(0.5), lineWidth: 0.75))
            .frame(width: 100, height: 20)
            .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
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
