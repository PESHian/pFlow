import AppKit
import SwiftUI
import Testing
@testable import Yap

/// Renders the live typing notes and Settings text to PNG files for a person
/// to look at. Runs only when PFLOW_SHOTS names a folder.
@MainActor
struct LiveInlineLooksTests {
    private static let folder = ProcessInfo.processInfo.environment["PFLOW_SHOTS"]

    /// `hosted` draws through AppKit (a window and cacheDisplay), which is
    /// what shows an AppKit text view inside the card; ImageRenderer skips those.
    private func save<V: View>(_ view: V, _ name: String, scheme: ColorScheme, hosted: Bool = false) throws {
        let framed = view.padding(16)
            .background(Color(nsColor: scheme == .dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.94, alpha: 1)))
            .environment(\.colorScheme, scheme)
        let rep: NSBitmapImageRep
        if hosted {
            let host = NSHostingView(rootView: framed)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
        } else {
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        }
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: Self.folder!).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    @Test(.enabled(if: folder != nil))
    func renderTypingNotesAndSettings() throws {
        for scheme in [ColorScheme.light, .dark] {
            for (index, (width, note)) in [(CGFloat(380), "Typing in TextEdit"), (288, "Stopped: cursor moved"),
                                           (288, "Can't type in this app"), (288, "Stopped: couldn't check"),
                                           (288, "Stopped: password field"), (288, "Typing in Microsoft PowerPoint")].enumerated() {
                let model = HUDModel()
                model.livePreview = true
                model.previewMaxWidth = width
                model.colorScheme = scheme
                model.partial = "The harbor opens at dawn and the boats go out"
                model.liveNote = note
                try save(RecordingHUDView(model: model), "note\(index)-\(Int(width))", scheme: scheme)
            }
            for phase in [HUDPhase.passwordField, .typingStopped, .typedTextLeft, .liveTextKept, .liveTextKeptTyped] {
                let model = HUDModel()
                model.phase = phase
                try save(RecordingHUDView(model: model), "compact-\(phase)", scheme: scheme)
                let card = HUDModel()
                card.livePreview = true
                card.colorScheme = scheme
                card.phase = phase
                card.partial = "The harbor opens at dawn"
                try save(RecordingHUDView(model: card), "card-\(phase)", scheme: scheme)
            }
            for engine in [TranscriptionEngine.apple, .whisper] {
                try save(LiveTextPicker(mode: .constant(.typeInApp), engine: engine).frame(width: 440),
                         "settings-type-\(engine)", scheme: scheme)
            }
            // The Copy card with the reason line, the Grant row and all of a long text.
            let long = HUDModel()
            long.livePreview = true
            long.colorScheme = scheme
            long.phase = .savedToHistory
            long.reason = InsertionBlock.accessibilityOff.reason
            long.needsAccessibility = true
            long.partial = (1...120).map { "fictional\($0)" }.joined(separator: " ")
            long.copyOffer = long.partial
            try save(RecordingHUDView(model: long), "card-copy-accessibility-long", scheme: scheme, hosted: true)
            let typing = HUDModel()
            typing.livePreview = true
            typing.colorScheme = scheme
            typing.liveNote = RecordingCoordinator.needsAccessibilityNote
            typing.needsAccessibility = true
            typing.partial = "The harbor opens at dawn and the boats go out"
            try save(RecordingHUDView(model: typing), "card-typing-needs-accessibility", scheme: scheme)
            let stopped = HUDModel()
            stopped.livePreview = true
            stopped.colorScheme = scheme
            stopped.phase = .typingStopped
            stopped.reason = LiveInlineOwnership.Stop.app.cardReason
            stopped.partial = "The harbor opens at dawn and the boats go out."
            stopped.copyOffer = stopped.partial
            try save(RecordingHUDView(model: stopped), "card-copy-app-changed", scheme: scheme, hosted: true)
        }
    }

    /// The recording capsule in every phase, both waveform styles, every
    /// built-in palette and a custom one, light and dark: one solid black
    /// control with a hairline outline in the palette, one size. Reduce
    /// Transparency is not a branch any more, so it renders the same.
    @Test(.enabled(if: folder != nil))
    func renderCapsuleInEveryPhase() throws {
        let phases: [HUDPhase] = [.listening, .confirmCancel, .transcribing, .cleaning, .copied, .pasteUnconfirmed,
                                  .savedToHistory, .failed, .restarting, .liveTextKept, .liveTextKeptTyped,
                                  .passwordField, .typingStopped, .typedTextLeft]
        let palettes: [(String, ThemePalette)] = [
            ("pesh", .pesh), ("aurora", .aurora), ("solar", .solar),
            ("custom", ThemePalette(primary: ThemeColor(hex: "3366FF")!, secondary: ThemeColor(hex: "FF3366")!)),
        ]
        let levels = (0..<HUDModel.waveformSampleCount).map { Float(0.2 + 0.6 * abs(sin(Double($0) * 0.7))) }
        for scheme in [ColorScheme.light, .dark] {
            for (name, palette) in palettes {
                for style in WaveformStyle.allCases {
                    for phase in name == "pesh" ? phases : [.listening, .transcribing, .copied] {
                        let model = HUDModel()
                        model.phase = phase
                        model.waveformStyle = style
                        model.palette = palette
                        model.levels = levels
                        try save(RecordingHUDView(model: model), "capsule-\(name)-\(style.rawValue)-\(phase)", scheme: scheme, hosted: true)
                    }
                }
            }
        }
    }
}
