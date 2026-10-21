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
    // The same after live typing put words in the app; those words stay there.
    case liveTextKeptTyped
    // Dictation does not start in a password field.
    case passwordField
    // Live typing stopped during the take, so the finished text went to History only.
    case typingStopped
    // Cancelled, but the app changed, so words pFlow typed were left in place.
    case typedTextLeft
}

// Behind a protocol so the coordinator can be tested without a real window.
@MainActor
protocol HUDControlling: AnyObject {
    /// `livePreview` swaps the small waveform for a text preview for this take.
    func show(device: String?, livePreview: Bool)
    func setPhase(_ phase: HUDPhase)
    func setLevel(_ level: Float)
    func setPartial(_ text: String)
    /// A short status under the live words, or nil. Cleared by `show` and hide.
    func setLiveNote(_ note: String?)
    /// Swaps the capsule for the text card mid-take (Type mode after typing
    /// stopped). The card keeps the words shown so far.
    func setLivePreview(_ on: Bool)
    func hide(after seconds: Double)
    func setActions(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void)
}

extension HUDControlling {
    func show(device: String?) { show(device: device, livePreview: false) }
    func setLiveNote(_ note: String?) {}
    func setLivePreview(_ on: Bool) {}
}
