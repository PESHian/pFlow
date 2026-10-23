import AppKit
import SwiftUI
import Testing
@testable import Yap

/// Settings switches and the Live text section. The test host can never be the
/// active app, so every window here draws as a window that is not in front,
/// which is when macOS's own switch looked the same on and off.
@MainActor
struct SettingsLooksTests {
    private static let shots = ProcessInfo.processInfo.environment["PFLOW_SETTINGS_SHOTS"]
    private static let looks: [(String, NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
        ("light-contrast", .accessibilityHighContrastAqua), ("dark-contrast", .accessibilityHighContrastDarkAqua),
    ]

    private func render<V: View>(_ content: V, width: CGFloat, look: NSAppearance.Name) throws -> NSBitmapImageRep {
        let view = NSHostingView(rootView: content.frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: look)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look)
        window.contentView = view
        defer { window.contentView = nil }
        #expect(!window.isKeyWindow)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Pixels clearly green: the "on" track. macOS's grey inactive track has none.
    private func greenPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.greenComponent - c.redComponent > 0.25 && c.greenComponent - c.blueComponent > 0.1 { count += 1 }
            }
        }
        return count
    }

    @Test func switchesShowOnAndOffApartInAWindowThatIsNotInFront() throws {
        for (look, name) in Self.looks {
            func row(_ on: Bool) -> some View {
                SettingsToggleRow(title: "Sound feedback", subtitle: "Play a cue.", isOn: .constant(on))
            }
            let on = greenPixels(try render(row(true), width: 420, look: name))
            let off = greenPixels(try render(row(false), width: 420, look: name))
            #expect(on > 200, "\(look): on track should be green, got \(on) green pixels")
            #expect(off == 0, "\(look): off track should have no green, got \(off)")
        }
    }

    /// All three choices are drawn side by side, no menu to open: selecting
    /// each one in turn changes pixels in its own third of the control, and
    /// the control fits the Settings column.
    @Test func liveTextShowsAllThreeChoicesWithoutOpeningAMenu() throws {
        let width = MainWindowView.minimumSize.width - 2 * Theme.s5 - 2 * Theme.s4
        func controls(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + controls($0) } }
        var reps: [NSBitmapImageRep] = []
        for mode in LiveTextMode.allCases {
            let picker = LiveTextPicker(mode: .constant(mode), engine: .apple)
            let view = NSHostingView(rootView: picker.frame(width: width))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            #expect(controls(view).filter { $0 is NSPopUpButton }.isEmpty, "Live text must not hide its choices in a menu")
            #expect(view.fittingSize.width <= width, "Live text control is \(view.fittingSize.width) wide in a \(width) column")
            reps.append(try render(picker, width: width, look: .aqua))
        }
        let columns = reps[0].pixelsWide / 3
        for (index, mode) in LiveTextMode.allCases.enumerated() {
            let other = reps[(index + 1) % reps.count]
            var changed = 0
            for y in 0..<min(reps[index].pixelsHigh, other.pixelsHigh) {
                for x in (index * columns)..<((index + 1) * columns) where reps[index].colorAt(x: x, y: y) != other.colorAt(x: x, y: y) {
                    changed += 1
                }
            }
            #expect(changed > 50, "\(mode.rawValue): selecting it should change its own third of the control, \(changed) pixels changed")
        }
    }

    private func sectionHeights(_ state: SettingsPageModel.WhisperState, received: Int64 = 0) -> [String: CGFloat] {
        var model = SettingsLayoutTests.fixture(engine: .whisper)
        model.whisper = state
        model.whisperReceivedBytes = received
        model.whisperError = nil
        var heights: [String: CGFloat] = [:]
        for section in SettingsContent(model: model).sections {
            let view = NSHostingView(rootView: section.view.frame(width: MainWindowView.minimumSize.width - 2 * Theme.s5))
            heights[section.name] = view.fittingSize.height
        }
        return heights
    }

    /// One state, one set of controls, in the same card as the engine choice:
    /// before the download one "Download (488 MB)" button; while it runs the
    /// byte count directly under it and one "Cancel"; once it is here a
    /// "Downloaded" line and no button at all. Nothing is shown that cannot
    /// be acted on right now. The progress lives in the Speech recognition
    /// card: that section alone changes height between the states.
    @Test func whisperDownloadShowsOnlyTheControlsThatMakeSenseNow() throws {
        let missing = DownloadControls.describe(.missing, received: 0)
        #expect(missing.button == .download && missing.button?.title == "Download (488 MB)")
        #expect(!missing.bar && !missing.done && !missing.line.contains("Downloading"))

        let downloading = DownloadControls.describe(.downloading, received: 120_000_000)
        #expect(downloading.button == .cancel && downloading.button?.title == "Cancel")
        #expect(downloading.line == "Downloading… 120 MB of 488 MB" && downloading.bar)

        let ready = DownloadControls.describe(.ready, received: 0)
        #expect(ready.button == nil, "nothing to press once the model is here")
        #expect(ready.line == "Downloaded · 488 MB · works offline" && ready.done && !ready.bar)

        let before = sectionHeights(.missing), during = sectionHeights(.downloading, received: 120_000_000), after = sectionHeights(.ready)
        #expect(during["Speech recognition"]! > before["Speech recognition"]! + 4, "the bar appears inside the Speech recognition card")
        #expect(after["Speech recognition"]! < during["Speech recognition"]!, "the bar and Cancel go away once downloaded")
        for name in before.keys where name != "Speech recognition" {
            #expect(before[name] == during[name] && during[name] == after[name], "\(name) must not change with the download")
        }

        if let shots = Self.shots {
            let folder = URL(fileURLWithPath: shots)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (state, name, received) in [(SettingsPageModel.WhisperState.missing, "before", Int64(0)),
                                            (.downloading, "downloading", Int64(120_000_000)), (.ready, "after", Int64(0))] {
                var model = SettingsLayoutTests.fixture(engine: .whisper)
                model.whisper = state
                model.whisperReceivedBytes = received
                model.whisperError = nil
                let section = SettingsContent(model: model).sections.first { $0.name == "Speech recognition" }!
                for (look, appearance) in Self.looks where !look.contains("contrast") {
                    for width in [MainWindowView.minimumSize.width, 760] {
                        let rep = try render(section.view.padding(Theme.s5).background(PeshBackdrop()), width: width, look: appearance)
                        try rep.representation(using: .png, properties: [:])?
                            .write(to: folder.appending(path: "download-\(name)-\(Int(width))-\(look).png"))
                    }
                }
            }
        }
    }

    /// The Live text control is built in one place, under its own heading,
    /// right after Shortcut, and nowhere else.
    @Test func settingsHasLiveTextExactlyOnce() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        var uses: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            uses += Array(repeating: file.lastPathComponent, count: text.components(separatedBy: "LiveTextPicker(").count - 1)
        }
        #expect(uses == ["SettingsView.swift"])
        let names = SettingsContent(model: SettingsLayoutTests.fixture()).sections.map(\.name)
        #expect(names.filter { $0 == "Live text" }.count == 1)
        let shortcut = try #require(names.firstIndex(of: "Shortcut"))
        #expect(names.firstIndex(of: "Live text") == shortcut + 1)
    }

    @Test(.enabled(if: shots != nil)) func renderSettingsLooks() throws {
        let folder = URL(fileURLWithPath: Self.shots!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (look, name) in Self.looks {
            for width in [CGFloat(420), 760] {
                for mode in LiveTextMode.allCases {
                    let content = VStack(alignment: .leading, spacing: Theme.s5) {
                        VStack(alignment: .leading, spacing: Theme.s3) {
                            SectionLabel("Live text")
                            Card { LiveTextPicker(mode: .constant(mode), engine: mode == .typeInApp ? .whisper : .apple) }
                        }
                        VStack(alignment: .leading, spacing: Theme.s3) {
                            SectionLabel("General")
                            Card(padding: Theme.s2) {
                                VStack(spacing: 0) {
                                    SettingsToggleRow(title: "Launch at login", subtitle: "Start pFlow automatically when you log in.", isOn: .constant(true))
                                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                                    SettingsToggleRow(title: "Show in Dock", subtitle: "Turn off to run from the menu bar only.", isOn: .constant(false))
                                    Divider().overlay(Theme.hairline).padding(.horizontal, Theme.s3)
                                    SettingsToggleRow(title: "Clean up transcripts", subtitle: "Requires Apple Intelligence, enabled in System Settings.", isOn: .constant(true))
                                        .disabled(true)
                                }
                            }
                        }
                    }.padding(Theme.s5).background(PeshBackdrop())
                    let rep = try render(content, width: width, look: name)
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: folder.appending(path: "settings-\(Int(width))-\(mode.rawValue)-\(look).png"))
                }
            }
        }
    }
}
