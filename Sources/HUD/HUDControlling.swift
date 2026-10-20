import Foundation

enum HUDPhase: Equatable {
    case failed
    case pasteUnconfirmed
    case copied
    case savedToHistory
    case listening
    case confirmCancel
    case transcribing
    // Running the transcript through the on-device cleanup model.
    case cleaning
    // Relaunching to pick up newly granted Accessibility rights.
    case restarting
    // Recognition stopped partway; the words so far went to History.
    case liveTextKept
}

// Behind a protocol so the coordinator can be tested without a real window.
@MainActor
protocol HUDControlling: AnyObject {
    /// `livePreview` swaps the small waveform for a text preview for this take.
    func show(device: String?, livePreview: Bool)
    func setPhase(_ phase: HUDPhase)
    func setLevel(_ level: Float)
    func setPartial(_ text: String)
    func hide(after seconds: Double)
    func setActions(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void)
}

extension HUDControlling {
    func show(device: String?) { show(device: device, livePreview: false) }
}
