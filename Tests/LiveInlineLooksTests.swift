import AppKit
import SwiftUI
import Testing
@testable import Yap

/// Renders the live typing notes and Settings text to PNG files for a person
/// to look at. Runs only when PFLOW_SHOTS names a folder.
@MainActor
struct LiveInlineLooksTests {
    private static let folder = ProcessInfo.processInfo.environment["PFLOW_SHOTS"]

    private func save<V: View>(_ view: V, _ name: String, scheme: ColorScheme) throws {
        let framed = view.padding(16)
            .background(Color(nsColor: scheme == .dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.94, alpha: 1)))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
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
            for phase in [HUDPhase.passwordField, .typingStopped, .typedTextLeft] {
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
        }
    }
}
