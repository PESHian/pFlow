import AppKit

@MainActor
final class HUDController: HUDControlling {
    let model = HUDModel()
    private var panel: HUDPanel?
    private var hideTask: Task<Void, Never>?
    /// Where Copy writes; tests pass a private pasteboard.
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// The one-press Accessibility Grant, run from the card's button.
    func setGrantAccessibility(_ action: @escaping () -> Void) {
        model.onGrantAccessibility = action
    }

    // Fast attack so speech registers immediately, slower release so bars glide back instead of snapping to zero between words.
    private var smoothedLevel: Float = 0

    func setActions(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        model.onConfirm = onConfirm
        model.onCancel = onCancel
    }

    func offerCopy(_ text: String) {
        hideTask?.cancel()
        model.partial = text
        model.copyOffer = text
        model.copied = false
        model.onCopy = { [weak self] in
            guard let self, let words = model.copyOffer else { return }
            pasteboard.clearContents()
            pasteboard.setString(words, forType: .string)
            model.copied = true
        }
        model.onClose = { [weak self] in self?.hide(after: 0) }
        remeasure()
    }

    /// The card grew or shrank (whole text, reason line, Grant row): measure
    /// it again so the panel fits its content and stays on the screen.
    private func remeasure() {
        guard model.livePreview, let panel, panel.isVisible else { return }
        panel.reposition(avoidingCaret: true)
    }

    // Built ahead of time: creating it on first use rendered an unlaid-out window for a frame — a flicker before "Listening" appeared.
    func prepare() {
        guard panel == nil else { return }
        let panel = HUDPanel(model: model)
        panel.alphaValue = 0
        panel.reposition()
        self.panel = panel
    }

    func show(device: String?, livePreview: Bool) {
        hideTask?.cancel()

        // Reset state BEFORE the panel is on screen, so no stale frame from the previous session is ever visible.
        model.device = device
        model.partial = ""
        model.liveNote = nil
        model.copyOffer = nil
        model.copied = false
        model.reason = nil
        model.needsAccessibility = false
        model.livePreview = livePreview
        model.colorScheme = AppearanceSettings.shared.mode.colorScheme
        model.waveformStyle = AppearanceSettings.shared.waveformStyle
        model.palette = AppearanceSettings.shared.palette
        model.level = 0
        model.levels = Array(repeating: 0, count: HUDModel.waveformSampleCount)
        model.phase = .listening
        smoothedLevel = 0

        prepare()
        guard let panel else { return }

        panel.alphaValue = 0
        panel.showsCardShadow(livePreview)
        panel.reposition(avoidingCaret: livePreview)
        panel.orderFrontRegardless()

        // Short fade covers any residual first-frame layout settling.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func setPhase(_ phase: HUDPhase) {
        model.phase = phase
    }

    func setLevel(_ level: Float) {
        // Follow consonants and pauses instead of holding each peak over them.
        smoothedLevel = AudioLevel.smoothWaveform(previous: smoothedLevel, input: level)
        model.level = smoothedLevel

        var samples = model.levels
        samples.removeFirst()
        samples.append(smoothedLevel)
        model.levels = samples
    }

    func setPartial(_ text: String) {
        guard model.livePreview else { return }
        let shown = LivePreviewText.tail(of: text)
        if model.partial != shown { model.partial = shown }
    }

    func setLiveNote(_ note: String?) {
        guard model.livePreview else { return }
        model.liveNote = note
    }

    func setReason(_ reason: String?) {
        guard model.reason != reason else { return }
        model.reason = reason
        remeasure()
    }

    func setNeedsAccessibility(_ on: Bool) {
        guard model.needsAccessibility != on else { return }
        model.needsAccessibility = on
        remeasure()
    }

    func setLivePreview(_ on: Bool) {
        guard model.livePreview != on else { return }
        model.livePreview = on
        if !on { model.partial = ""; model.liveNote = nil }
        panel?.showsCardShadow(on)
        panel?.reposition(avoidingCaret: on)
    }

    func hide(after seconds: Double) {
        hideTask?.cancel()
        guard seconds > 0 else {
            close()
            return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    // Dictated words do not stay on screen or in memory after the take.
    private func close() {
        panel?.orderOut(nil)
        model.partial = ""
        model.copyOffer = nil
        model.copied = false
        model.liveNote = nil
        model.reason = nil
        model.needsAccessibility = false
    }

    var panelForTesting: HUDPanel? { panel }
}
