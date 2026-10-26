import SwiftUI

struct RecordingHUDView: View {
    @Bindable var model: HUDModel

    var body: some View {
        if model.livePreview {
            LivePreviewCard(model: model, title: title, isRecordingPhase: isRecordingPhase) { status }
        } else {
            compact
        }
    }

    /// The recording capsule, the same control for every Live text choice:
    /// a low pill, 70x22 pt (shorter and a little wider than Superwhisper's
    /// 58x30, as the owner asked after 0.3.14), dark Liquid Glass (an opaque
    /// dark fill with Reduce Transparency), with a hairline outline in the
    /// person's colour palette and the waveform or the sweep inside. One
    /// size in every phase; a status after the take is an icon only.
    static let capsuleSize = CGSize(width: 70, height: 22)
    static let capsuleOutlineOpacity = 0.65
    /// The capsule draws exactly what the Appearance picker shows for the
    /// person's style (RecordingWaveform), in their colours, from live levels.
    static func capsuleWaveformView(_ model: HUDModel) -> RecordingWaveform {
        RecordingWaveform(levels: model.levels, style: model.waveformStyle, palette: model.palette, size: capsuleWaveform)
    }

    /// The capsule's waveform, inside its rounded ends.
    static let capsuleWaveform = CGSize(width: 46, height: 14)

    /// The Copy card shows all of the text up to this many lines, then scrolls.
    static let wholeTextLines = 10

    /// The height `text` needs at `size` in `width`, capped at `wholeTextLines`.
    static func wholeTextHeight(_ text: String, width: CGFloat, size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        let line = ceil(font.ascender - font.descender + font.leading)
        let needed = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return min(ceil(needed) + 2, line * CGFloat(wholeTextLines))
    }

    private var compact: some View {
        status
        .foregroundStyle(.white.opacity(0.9))
        // One size in every phase; a status after the take is an icon only,
        // its words are on the card or in the tooltip and VoiceOver label.
        .frame(width: Self.capsuleSize.width, height: Self.capsuleSize.height)
        .contentShape(Capsule())
        .background { CapsuleBackground(palette: model.palette) }
        // Everything inside draws for the capsule's dark glass. Not
        // preferredColorScheme: that turns the whole panel dark and the card
        // shown after the take in the same panel would stay dark in light mode.
        .environment(\.colorScheme, .dark)
        .accessibilityLabel(title)
    }

    private var status: some View {
        Group {
            if isRecordingPhase {
                Self.capsuleWaveformView(model)
            } else if model.phase == .pasteUnconfirmed {
                capsuleLabel("Check paste", "info.circle")
                    .help("The app could not verify the paste. Check your text before pasting again.")
            } else if model.phase == .copied {
                capsuleLabel("Press ⌘V", "doc.on.clipboard")
            } else if model.phase == .savedToHistory {
                capsuleLabel("In History", "clock.arrow.circlepath")
                    .help(title)
            } else if model.phase == .failed {
                capsuleLabel("Failed", "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(title)
            } else if model.phase == .liveTextKept || model.phase == .liveTextKeptTyped {
                capsuleLabel(model.phase == .liveTextKeptTyped ? "Words stay" : "In History",
                             "clock.arrow.circlepath")
                    .help(title)
            } else if model.phase == .passwordField {
                capsuleLabel("Password", "lock")
                    .help(title)
            } else if model.phase == .typingStopped {
                capsuleLabel("Not put in", "exclamationmark.circle")
                    .help(title)
            } else if model.phase == .typedTextLeft {
                capsuleLabel("Words stay", "info.circle")
                    .help(title)
            } else {
                // The system spinner draws for the window's light or dark
                // look, which is dark on the capsule's dark glass.
                ProcessingSweep(palette: model.palette)
                    .frame(width: Self.capsuleWaveform.width, height: Self.capsuleWaveform.height)
            }
        }
    }

    /// A status after the take: its icon in the capsule; the words in the
    /// tooltip and the VoiceOver label (the card carries them when it shows).
    private func capsuleLabel(_ text: String, _ systemImage: String) -> some View {
        Self.statusMark(text, systemImage)
    }

    /// The one thing a status shows in the capsule: its icon. No words.
    static func statusMark(_ text: String, _ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .medium))
            .accessibilityLabel(text)
            .help(text)
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
        case .liveTextKept: return "pFlow stopped listening early. The words so far are saved in History."
        case .liveTextKeptTyped:
            return "pFlow stopped listening early. The words already typed stay in your app, and the words so far are saved in History."
        case .passwordField: return "Dictation is off in password fields."
        case .typingStopped: return "Typing stopped, so the finished text was not put in. Copy it here; it is also in History."
        case .typedTextLeft: return "Cancelled. Words pFlow already typed are still in the app."
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

    /// Whole lines of transcript in the box; the top one fades out.
    private var boxLines: Int { 4 }
    private var headerHeight: CGFloat { 20 }

    /// Only a reason to give (password field, recording did not start,
    /// cancelled): one compact row, sized to the sentence, with close.
    private var messageOnly: Bool {
        model.reason != nil && model.copyOffer == nil && !model.needsAccessibility && !isRecordingPhase && !isProcessingPhase
    }

    @ViewBuilder private var content: some View {
        if messageOnly, let reason = model.reason {
            HStack(alignment: .center, spacing: Theme.s2) {
                PeshMark(size: 16)
                status()
                Text(reason)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("reason")
                HUDButton(systemName: "xmark", tint: .secondary) { model.onClose?() }
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        } else {
            fullCard
        }
    }

    var body: some View {
        content
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
        .accessibilityValue(messageOnly ? (model.reason ?? "") : model.partial)
    }

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: headerHeight)
                .padding(.horizontal, Theme.s4)
                .padding(.top, Theme.s3)
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s2)
            if let reason = model.reason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.s4)
                    .padding(.bottom, Theme.s2)
                    .accessibilityIdentifier("reason")
            }
            if model.needsAccessibility {
                accessibilityRow
                    .padding(.horizontal, Theme.s4)
                    .padding(.bottom, Theme.s2)
            }
            if model.copyOffer != nil {
                wholeText
                    .padding(.horizontal, Theme.s4)
                    .padding(.bottom, Theme.s3)
                copyRow
                    .padding(.horizontal, Theme.s4)
                    .padding(.bottom, Theme.s3)
            } else {
                transcript
                    .padding(.horizontal, Theme.s4)
                    .padding(.bottom, Theme.s3)
            }
        }
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
                                  style: model.waveformStyle, compact: true, palette: model.palette)
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

    /// The finished words pFlow could not put in: Copy writes them to the
    /// clipboard once, on press; close dismisses the card. The panel never
    /// takes focus, so the app the person was in keeps it.
    private var copyRow: some View {
        HStack(spacing: Theme.s2) {
            Text(model.reason == nil ? title : "Saved in History")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.s2)
            Button(model.copied ? "Copied" : "Copy") { model.onCopy?() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.regular)
                .accessibilityLabel(model.copied ? "Copied" : "Copy the finished text")
            HUDButton(systemName: "xmark", tint: .secondary) { model.onClose?() }
                .accessibilityLabel("Close")
        }
    }

    /// This build is not trusted for Accessibility: say so where the person
    /// is looking, with the one-press Grant right there.
    private var accessibilityRow: some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: "accessibility")
                .foregroundStyle(Theme.accent)
            Text("pFlow needs Accessibility to type. Press Grant, then turn on pFlow.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.s2)
            Button("Grant") { model.onGrantAccessibility?() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .accessibilityLabel("Grant Accessibility")
        }
        .accessibilityIdentifier("needsAccessibility")
    }

    /// Words that could not go in: all of them, scrollable and selectable,
    /// from the top, so nothing is hidden behind the live-tail box. The box
    /// is as tall as the text up to about ten lines; longer text scrolls.
    private var wholeText: some View {
        SelectableText(text: model.partial, size: textSize, scheme: model.colorScheme ?? systemScheme)
            .frame(height: RecordingHUDView.wholeTextHeight(model.partial, width: model.previewMaxWidth - 2 * Theme.s4, size: textSize))
            .accessibilityLabel("Finished text")
            .accessibilityValue(model.partial)
    }

    private var caption: String {
        if model.phase == .confirmCancel { return title }
        return model.liveNote ?? "Listening"
    }

    private var isProcessingPhase: Bool {
        model.phase == .transcribing || model.phase == .cleaning
    }

    // A fixed box of whole lines, filled from the bottom: the newest words stay
    // in view and the oldest visible line fades out. The box is a hidden text
    // of the same font laid out the same way, so its top always falls between
    // two lines and no glyph is ever cut; it never changes size while the
    // words grow, so the card does not jitter.
    private var transcript: some View {
        Text(verbatim: String(repeating: "\n", count: boxLines - 1))
            .font(textFont)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomLeading) {
                Text(model.partial.isEmpty ? placeholder : model.partial)
                    .font(textFont)
                    .textSelection(.enabled)
                    .foregroundStyle(model.partial.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 1 / CGFloat(boxLines))],
                               startPoint: .top, endPoint: .bottom)
            }
    }

    private var placeholder: String { isRecordingPhase ? "Your words will show here" : "" }

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
}

/// All of a text, selectable and scrolling: an AppKit text view, because a
/// SwiftUI ScrollView lays out nothing in an offscreen render and reports
/// no size to the panel. Read-only; the system label colour for the scheme.
struct SelectableText: NSViewRepresentable {
    let text: String
    let size: CGFloat
    let scheme: ColorScheme

    /// Scrolls to the top on the next layout after new words arrive, so the
    /// card opens on the first line whatever size the box settles at.
    final class TopScrollView: NSScrollView {
        var wantsTop = false
        override func layout() {
            super.layout()
            if wantsTop {
                wantsTop = false
                contentView.scroll(to: .zero)
                reflectScrolledClipView(contentView)
            }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TopScrollView()
        let view = NSTextView(frame: .zero)
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        guard let view = scroll.documentView as? NSTextView else { return }
        let changed = view.string != text
        if changed { view.string = text }
        view.font = NSFont.systemFont(ofSize: size)
        view.textColor = .labelColor
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.frame.size.width = scroll.contentSize.width
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        // New words read from the top; the person scrolls down for the rest.
        if changed {
            (scroll as? TopScrollView)?.wantsTop = true
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.needsLayout = true
        }
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
    /// The palette read when the take started; nil draws the app's current one.
    var palette: ThemePalette?
    /// Another size than the picker's 100x20 (the capsule): the same drawing
    /// at the same density, so it holds the newest levels that fit.
    var size: CGSize?

    /// The picker's thumbnail: 25 samples across 100 pt.
    static let thumbnailSamples = 25
    static let thumbnailSize = CGSize(width: 100, height: 20)

    var frame: CGSize { size ?? (compact ? CGSize(width: 84, height: 16) : Self.thumbnailSize) }

    /// The levels drawn: all of them, or at another size the newest that keep
    /// the picker's spacing, eased to quiet at both ends as the picker's
    /// thumbnail is (its pointed wave ends and dotted bar ends).
    var shownLevels: [Float] {
        guard let size else { return levels }
        let count = max(2, Int((Double(Self.thumbnailSamples) * size.width / Self.thumbnailSize.width).rounded()))
        let newest = Array(levels.suffix(count))
        let padded = newest.count == count ? newest : Array(repeating: 0, count: count - newest.count) + newest
        return padded.enumerated().map { index, level in
            let edge = min(index, count - 1 - index)
            return level * (edge < Self.endEase.count ? Self.endEase[edge] : 1)
        }
    }

    /// How much of the level the outermost samples keep, from each end inward.
    static let endEase: [Float] = [0.12, 0.45, 0.8]

    var body: some View {
        switch style {
        case .wave:
            Waveform(levels: shownLevels, compact: compact, gradient: palette?.gradient ?? Theme.gradient, frame: frame)
        case .lines:
            WaveformLines(levels: AudioLevel.waveformLevels(shownLevels))
                .fill(palette?.gradient ?? Theme.gradient)
                .frame(width: frame.width, height: frame.height)
                .shadow(color: .black.opacity(compact ? 0 : 0.25), radius: 1.5, x: 0, y: 1)
        }
    }
}

/// "Lines": symmetric thin bars, one per level, never shorter than a dot.
struct WaveformLines: Shape {
    let levels: [Float]

    static func bars(_ levels: [Float], in rect: CGRect) -> [CGRect] {
        let samples = levels.isEmpty ? Array(repeating: Float(0), count: 25) : levels
        let spacing = rect.width / CGFloat(samples.count)
        let width = min(2, spacing * 0.65)
        return samples.enumerated().map { index, level in
            let height = max(1.2, CGFloat(level) * rect.height * 0.92)
            return CGRect(x: rect.minX + (CGFloat(index) + 0.5) * spacing - width / 2,
                          y: rect.midY - height / 2, width: width, height: height)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for bar in Self.bars(levels, in: rect) {
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: bar.width / 2, height: bar.width / 2))
        }
        return path
    }
}

/// A connected envelope of real microphone levels, newest on the right.
private struct Waveform: View {
    let levels: [Float]
    var compact = false
    var gradient: LinearGradient = Theme.gradient
    var frame = RecordingWaveform.thumbnailSize

    var body: some View {
        let outline = WaveformOutline(levels: AudioLevel.waveformLevels(levels))
        outline
            .fill(gradient)
            .overlay(outline.stroke(.black.opacity(compact ? 0 : 0.5), lineWidth: 0.75))
            .frame(width: frame.width, height: frame.height)
            .shadow(color: .black.opacity(compact ? 0 : 0.25), radius: 1.5, x: 0, y: 1)
    }
}

/// "Wave": a smooth filled envelope, mirrored about the middle.
struct WaveformOutline: Shape {
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

/// The capsule's material: dark Liquid Glass, as Superwhisper's pill uses
/// (SwiftUI glassEffect, regular), tinted so the white waveform and labels
/// read over any background; with Reduce Transparency an opaque dark fill.
/// The outline is the person's palette.
private struct CapsuleBackground: View {
    let palette: ThemePalette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Superwhisper's pill reads #2B2B2A over a light desktop.
    static let solidFill = Color(red: 0x2B / 255, green: 0x2B / 255, blue: 0x2A / 255)
    static let glassTint = Color.black.opacity(0.72)

    var body: some View {
        let shape = Capsule()
        Group {
            if reduceTransparency {
                shape.fill(Self.solidFill)
            } else {
                // Glass alone follows the window's light appearance; the dark
                // layer over it gives the pill's near-black read, the glass
                // its blur and edge light.
                Color.clear.glassEffect(.regular, in: shape)
                    .overlay(shape.fill(Self.glassTint))
            }
        }
        .overlay(shape.strokeBorder(palette.gradient.opacity(RecordingHUDView.capsuleOutlineOpacity), lineWidth: 1))
    }
}

/// The capsule's "still working" sign, as on Windows: a short line in the
/// palette sweeping back and forth. With Reduce Motion it rests in the middle.
private struct ProcessingSweep: View {
    let palette: ThemePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // About 30 frames a second is smooth for a slow sweep; the display's
        // 120 Hz would redraw four times as often for nothing.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let sweep = reduceMotion ? Double.pi / 2 : context.date.timeIntervalSinceReferenceDate * 2.6
            SweepShape(sweep: sweep)
                .stroke(palette.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .accessibilityHidden(true)
    }

    private struct SweepShape: Shape {
        let sweep: Double
        func path(in rect: CGRect) -> Path {
            let length = rect.width * 0.32
            let x = rect.minX + (rect.width - length) * (1 - cos(sweep)) / 2
            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.midY))
            path.addLine(to: CGPoint(x: x + length, y: rect.midY))
            return path
        }
    }
}
