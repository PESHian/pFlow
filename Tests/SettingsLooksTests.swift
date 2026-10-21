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

    @Test func liveTextShowsAllThreeChoicesWithoutOpeningAMenu() throws {
        let view = NSHostingView(rootView: LiveTextPicker(mode: .constant(.preview), engine: .apple).frame(width: 420))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        func controls(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + controls($0) } }
        let all = controls(view)
        let segmented = all.compactMap { $0 as? NSSegmentedControl }
        #expect(segmented.count == 1, "views: \(all.map { String(describing: type(of: $0)) })")
        #expect(all.filter { $0 is NSPopUpButton }.isEmpty, "Live text must not hide its choices in a menu")
        let control = try #require(segmented.first)
        #expect((0..<control.segmentCount).map { control.label(forSegment: $0) } == LiveTextMode.allCases.map(\.title))
        #expect(control.selectedSegment == LiveTextMode.allCases.firstIndex(of: .preview))
    }

    /// Settings needs the whole app to draw, so this reads the source: the Live
    /// text control is built in one place, under its own heading, right after
    /// Shortcut, and nowhere else.
    @Test func settingsHasLiveTextExactlyOnce() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        var uses: [String] = []
        var headings = 0
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            uses += Array(repeating: file.lastPathComponent, count: text.components(separatedBy: "LiveTextPicker(").count - 1)
            headings += text.components(separatedBy: "SectionLabel(\"Live text\")").count - 1
        }
        #expect(uses == ["SettingsView.swift"])
        #expect(headings == 1)
        let settings = try String(contentsOf: sources.appending(path: "Views/SettingsView.swift"), encoding: .utf8)
        let body = try #require(settings.range(of: "shortcutSection\n                liveTextSection\n"))
        #expect(!body.isEmpty)
        let section = try #require(settings.range(of: "private var liveTextSection"))
        let picker = try #require(settings.range(of: "LiveTextPicker("))
        let next = try #require(settings.range(of: "private var", range: section.upperBound..<settings.endIndex))
        #expect(picker.lowerBound > section.lowerBound && picker.lowerBound < next.lowerBound)
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
