import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import Yap

/// Every page and every Settings section fits the main window at its minimum
/// width, light and dark, at the normal and the largest text size. A vertical
/// scroll view takes the width of its widest child, so one control that cannot
/// shrink makes the whole page wider than the window, centred and cut off on
/// both sides. 0.3.8 and 0.3.9 shipped exactly that.
@MainActor
@Suite(.serialized)
struct SettingsLayoutTests {
    private static let shots = ProcessInfo.processInfo.environment["PFLOW_SETTINGS_SHOTS"]
    private static let widths: [CGFloat] = Array(Set([MainWindowView.minimumSize.width, MainWindowView.defaultSize.width])).sorted()
    private static let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    private static let textSizes: [(String, DynamicTypeSize)] = [("normal", .large), ("largest", .accessibility5)]

    static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: Transcript.self, configurations: config)
    }()

    /// Fictional values only; the page never reads the app.
    static func fixture(mode: LiveTextMode = .preview, engine: TranscriptionEngine = .apple) -> SettingsPageModel {
        SettingsPageModel(
            activeTemplate: "Fictional radiology report",
            liveTextMode: .constant(mode),
            engine: .constant(engine),
            whisper: .missing,
            whisperError: "Fictional download problem.",
            intelligenceMode: .constant(.privateCloud),
            cloudUnavailableReason: "Apple cloud processing is not available on this Mac.",
            language: .constant(AppState.systemLanguage),
            locales: [Locale(identifier: "de-DE"), Locale(identifier: "fr-FR")],
            launchAtLogin: .constant(true),
            showInDock: .constant(false),
            showInMenuBar: .constant(false),
            sounds: .constant(true),
            copyDictation: .constant(false),
            cleanup: .constant(true),
            cleanupAvailable: true,
            inputName: "Fictional USB microphone",
            permissionsMissing: true
        )
    }

    private struct Fit { let width: CGFloat; let clipped: Bool; let detail: String }

    /// Hosts `content` the way the main window does (hosting controller in a
    /// window of this content width) and reports whether any scroll view or
    /// its content ended up wider than the window.
    private func fit<V: View>(_ content: V, width: CGFloat, look: NSAppearance.Name, text: DynamicTypeSize,
                              shot: String? = nil) throws -> Fit {
        let root = content
            .frame(minWidth: MainWindowView.minimumSize.width, maxWidth: .infinity,
                   minHeight: MainWindowView.minimumSize.height, maxHeight: .infinity)
            .modifier(PeshAppearance())
            .environment(\.dynamicTypeSize, text)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        defer { window.contentView = nil }
        window.appearance = NSAppearance(named: look)
        window.setContentSize(NSSize(width: width, height: MainWindowView.defaultSize.height))
        let view = hosting.view
        view.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        let scrolls = all(view).compactMap { $0 as? NSScrollView }
        var detail: [String] = []
        var clipped = false
        for scroll in scrolls {
            let frame = view.convert(scroll.bounds, from: scroll)
            let document = scroll.documentView?.frame.width ?? 0
            let clip = scroll.contentView.bounds.width
            if frame.minX < -0.5 || frame.maxX > width + 0.5 || document > clip + 0.5 {
                clipped = true
            }
            detail.append("scroll \(Int(frame.minX))…\(Int(frame.maxX)) of \(Int(width)), content \(Int(document)) in \(Int(clip))")
        }
        if let shot, let folder = Self.shots {
            // Tall enough to show the whole content, so every section is in the picture.
            let height = max(window.contentLayoutRect.height, (scrolls.first?.documentView?.frame.height ?? 0) + 2)
            window.setContentSize(NSSize(width: width, height: height))
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: folder).appending(path: shot + ".png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        return Fit(width: scrolls.map { view.convert($0.bounds, from: $0).width }.max() ?? view.frame.width,
                   clipped: clipped, detail: detail.joined(separator: "; "))
    }

    @Test func everySettingsSectionFitsTheWindow() throws {
        for (mode, engine) in [(LiveTextMode.off, TranscriptionEngine.apple), (.preview, .apple), (.typeInApp, .whisper)] {
            let sections = SettingsContent(model: Self.fixture(mode: mode, engine: engine)).sections
            #expect(sections.count >= 15)
            for section in sections {
                for width in Self.widths {
                    for (look, name) in Self.looks {
                        for (size, text) in Self.textSizes {
                            let shot = (look == "light" || look == "dark") && size == "normal" && mode == .preview
                                ? "section-\(section.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(Int(width))-\(look)" : nil
                            let fit = try fit(ScrollView { section.view.padding(Theme.s5) }, width: width, look: name, text: text, shot: shot)
                            #expect(!fit.clipped, "\(section.name) (\(mode.rawValue)) at \(Int(width)) \(look) \(size): \(fit.detail)")
                        }
                    }
                }
            }
        }
    }

    @Test func theWholeSettingsPageFitsTheWindow() throws {
        for (mode, engine) in [(LiveTextMode.preview, TranscriptionEngine.apple), (.typeInApp, .whisper)] {
            for width in Self.widths {
                for (look, name) in Self.looks {
                    for (size, text) in Self.textSizes {
                        let shot = mode == .preview ? "settings-\(Int(width))-\(look)-\(size)" : nil
                        let fit = try fit(ScrollView { SettingsContent(model: Self.fixture(mode: mode, engine: engine)) },
                                          width: width, look: name, text: text, shot: shot)
                        #expect(!fit.clipped, "Settings (\(mode.rawValue)) at \(Int(width)) \(look) \(size): \(fit.detail)")
                    }
                }
            }
        }
    }

    @Test func historyAndStatisticsPagesFitTheWindow() throws {
        let store = HistoryStore(context: Self.container.mainContext)
        store.save(text: "A fictional dictated sentence that runs on for a while so the row has to wrap instead of widening the page.",
                   duration: 9, device: "Fictional microphone", spokenWordCount: 21,
                   applicationName: "Fictional Notes", applicationBundleID: "com.fictional.notes")
        let pages: [(String, AnyView)] = [
            ("history", AnyView(HistoryView(onBack: {}).modelContainer(Self.container))),
            ("statistics", AnyView(StatisticsView(onBack: {}).modelContainer(Self.container))),
        ]
        for (page, view) in pages {
            for width in Self.widths {
                for (look, name) in Self.looks {
                    for (size, text) in Self.textSizes {
                        let fit = try fit(view, width: width, look: name, text: text,
                                          shot: size == "normal" ? "\(page)-\(Int(width))-\(look)" : nil)
                        #expect(!fit.clipped, "\(page) at \(Int(width)) \(look) \(size): \(fit.detail)")
                    }
                }
            }
        }
    }

    @Test func mainWindowCannotShrinkUnderItsContent() {
        #expect(MainWindowView.minimumSize.width <= MainWindowView.defaultSize.width)
        #expect(MainWindowView.minimumSize.height <= MainWindowView.defaultSize.height)
        let window = WindowManager.makeWindow(title: "Fictional", size: MainWindowView.defaultSize,
                                              minSize: MainWindowView.minimumSize, resizable: true) { Text("Fictional") }
        defer { window.contentView = nil }
        #expect(window.contentMinSize == MainWindowView.minimumSize)
        #expect(window.contentLayoutRect.size == MainWindowView.defaultSize)
        let fixed = WindowManager.makeWindow(title: "Fictional", size: NSSize(width: 360, height: 440),
                                             minSize: nil, resizable: false) { Text("Fictional") }
        defer { fixed.contentView = nil }
        #expect(fixed.contentMinSize == NSSize(width: 360, height: 440))
    }
}
