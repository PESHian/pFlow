import Observation
import SwiftUI

@MainActor
@Observable
final class HUDModel {
    static let waveformSampleCount = 32

    var phase: HUDPhase = .listening
    var level: Float = 0
    // Rolling window, oldest first: drawn as a scrolling waveform so the meter reads as a timeline rather than a single bouncing bar.
    var levels: [Float] = Array(repeating: 0, count: HUDModel.waveformSampleCount)
    /// Display text only: the end of a long transcript. History keeps it all.
    var partial: String = ""
    /// Live words stopped early, for example; shown in the preview header.
    var liveNote: String?
    /// Set for a whole take when Live text is on. Off keeps the waveform capsule.
    var livePreview = false
    /// Widest the preview may be on the current screen.
    var previewMaxWidth: CGFloat = HUDModel.previewWidth
    static let previewWidth: CGFloat = 380
    /// The app's Appearance choice for the preview; nil follows the system.
    var colorScheme: ColorScheme?
    var device: String?

    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Finished words pFlow could not put in: shown with a Copy button until
    /// closed or the next take. The clipboard is written only when Copy is pressed.
    var copyOffer: String?
    var copied = false
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
}
