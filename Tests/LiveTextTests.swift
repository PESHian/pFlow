import AppKit
import SwiftUI
import Testing
@testable import Yap

private final class FixtureBundle {}

/// The shared fixtures in fixtures/live-text/transcript-updates. Windows runs the same files.
private struct TranscriptFixture: Decodable {
    struct Event: Decodable {
        let op: String
        let session: String?
        let sequence: Int?
        let text: String?
        let isFinal: Bool?
    }
    struct Expected: Decodable {
        let shown: [String]
        let text: String
        let phase: String
    }
    let description: String
    let events: [Event]
    let expected: Expected
}

@MainActor
struct LiveTextTests {
    // MARK: Reconciler fixtures

    @Test func sharedFixturesProduceTheirExpectedText() throws {
        let folder = try #require(Bundle(for: FixtureBundle.self).url(forResource: "transcript-updates", withExtension: nil))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count >= 8)
        for file in files {
            let fixture = try JSONDecoder().decode(TranscriptFixture.self, from: Data(contentsOf: file))
            var reconciler = LiveTranscriptReconciler()
            var shown: [String] = []
            for event in fixture.events {
                switch event.op {
                case "begin":
                    reconciler.begin(session: try #require(event.session))
                case "update":
                    let update = TranscriptUpdate(session: try #require(event.session),
                                                  sequence: try #require(event.sequence),
                                                  text: try #require(event.text),
                                                  isFinal: try #require(event.isFinal))
                    if reconciler.apply(update) { shown.append(reconciler.text) }
                case "cancel":
                    reconciler.cancel()
                default:
                    Issue.record("\(file.lastPathComponent): unknown op \(event.op)")
                }
            }
            let name = file.lastPathComponent
            #expect(shown == fixture.expected.shown, "\(name)")
            #expect(reconciler.text == fixture.expected.text, "\(name)")
            #expect(reconciler.phase.rawValue == fixture.expected.phase, "\(name)")
        }
    }

    // MARK: Setting

    @Test func liveTextDefaultsToOffAndKeepsOtherSettings() throws {
        let name = "pflow.livetext.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // An existing install: other choices saved, no Live text key yet.
        defaults.set("whisper", forKey: TranscriptionEngine.defaultsKey)
        defaults.set(false, forKey: "soundsEnabled")
        defaults.set("de-DE", forKey: "dictationLanguage")
        #expect(LiveTextMode.saved(in: defaults) == .off)
        for unknown in ["", "inline", "Preview", "on", "1"] {
            defaults.set(unknown, forKey: LiveTextMode.defaultsKey)
            #expect(LiveTextMode.saved(in: defaults) == .off, "\(unknown)")
        }
        defaults.set(42, forKey: LiveTextMode.defaultsKey)
        #expect(LiveTextMode.saved(in: defaults) == .off)
        for mode in LiveTextMode.allCases {
            mode.save(in: defaults)
            #expect(LiveTextMode.saved(in: UserDefaults(suiteName: name)!) == mode)
        }
        #expect(TranscriptionEngine.saved(in: defaults) == .whisper)
        #expect(defaults.object(forKey: "soundsEnabled") as? Bool == false)
        #expect(defaults.string(forKey: "dictationLanguage") == "de-DE")
        #expect(LiveTextMode.allCases.map(\.title) == ["Off", "Type in the current app"])
        #expect(LiveTextMode.allCases.map(\.showsPreview) == [false, true])
        // Type mode keeps the small capsule while pFlow types in the app; the
        // card appears only when typing could not start or has stopped.
        #expect(LiveTextMode.allCases.map { $0.showsCard(typingLive: true) } == [false, false])
        #expect(LiveTextMode.allCases.map { $0.showsCard(typingLive: false) } == [false, false], "the capsule stays for the whole take")
        let retired = UserDefaults(suiteName: "pflow-live-text-retired-preview-" + UUID().uuidString)!
        retired.set("preview", forKey: LiveTextMode.defaultsKey)
        #expect(LiveTextMode.saved(in: retired) == .typeInApp, "the retired Preview choice loads as Type")
        retired.set("sideways", forKey: LiveTextMode.defaultsKey)
        #expect(LiveTextMode.saved(in: retired) == .off)
    }

    // MARK: Coordinator

    @Test func finalUpdateAfterPartialsIsWhatGetsTyped() async {
        let session = FakeSession()
        session.textToReturn = "The lighthouse keeper whistles at dawn."
        let injector = FakeInjector()
        let history = FakeHistory()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(session: session, injector: injector, history: history, hud: hud,
                                          liveTextMode: { .typeInApp })
        await coordinator.toggle()
        session.emit("The light")
        session.emit("The lighthouse keeper")
        #expect(injector.delivered.isEmpty)
        await coordinator.finish()
        #expect(hud.partials == ["The light", "The lighthouse keeper"])
        #expect(injector.delivered == ["The lighthouse keeper whistles at dawn."])
        #expect(history.saved == ["The lighthouse keeper whistles at dawn."])
    }

    @Test func partialsArrivingAfterFinishOrCancelAreIgnored() async {
        let session = FakeSession()
        let hud = FakeHUD()
        let injector = FakeInjector()
        let history = FakeHistory()
        let coordinator = makeCoordinator(session: session, injector: injector, history: history, hud: hud,
                                          liveTextMode: { .typeInApp })
        await coordinator.toggle()
        session.emit("hello")
        // A partial still on its way when the take ended: older than the final one.
        let stale = session.update("hello wor", isFinal: false)
        await coordinator.finish()
        session.onTranscript?(stale)
        session.emit("hello world again")
        #expect(hud.partials == ["hello"])
        #expect(injector.delivered == ["hello world"])

        await coordinator.toggle()
        session.emit("second take")
        let late = session.update("second take late", isFinal: false)
        await coordinator.cancel()
        session.onTranscript?(late)
        session.emit("after cancel")
        #expect(hud.partials == ["hello", "second take"])
        #expect(injector.delivered == ["hello world"])
        #expect(history.saved == ["hello world"])
    }

    @Test func earlierTakeCannotReachTheNextTake() async {
        let session = FakeSession()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(session: session, hud: hud, liveTextMode: { .typeInApp })
        await coordinator.toggle()
        let old = TranscriptUpdate(session: session.take!, sequence: 99, text: "old take", isFinal: false)
        await coordinator.finish()
        await coordinator.toggle()
        session.onTranscript?(old)
        session.emit("new take")
        #expect(hud.partials == ["new take"])
    }

    @Test func liveTextChangeAppliesOnTheNextTake() async {
        var mode = LiveTextMode.off
        let session = FakeSession()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(session: session, hud: hud, liveTextMode: { mode })
        await coordinator.toggle()
        mode = .typeInApp
        session.emit("not shown")
        await coordinator.finish()
        #expect(hud.partials.isEmpty)
        await coordinator.toggle()
        session.emit("shown")
        mode = .off
        session.emit("shown still")
        await coordinator.finish()
        #expect(hud.previews == [false, false])
        #expect(hud.partials == ["shown", "shown still"])
    }

    @Test func previewAndTypeInAppTypeOnceAfterStopping() async {
        for mode in [LiveTextMode.typeInApp] {
            let session = FakeSession()
            let injector = FakeInjector()
            let history = FakeHistory()
            let hud = FakeHUD()
            let coordinator = makeCoordinator(session: session, injector: injector, history: history, hud: hud,
                                              liveTextMode: { mode })
            await coordinator.toggle()
            for word in ["one", "one two", "one two three", "one two three four", "one two three four five"] {
                session.emit(word)
                #expect(injector.delivered.isEmpty)
            }
            await coordinator.finish()
            #expect(hud.previews == [false])
            #expect(injector.delivered == ["hello world"], "\(mode)")
            #expect(history.saved.count == 1, "\(mode)")
        }
    }

    @Test func offShowsNoLiveText() async {
        let session = FakeSession()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(session: session, hud: hud)
        await coordinator.toggle()
        session.emit("anything")
        await coordinator.finish()
        #expect(hud.previews == [false])
        #expect(hud.partials.isEmpty)
    }

    @Test func recognitionStoppingEarlyKeepsWordsInHistoryWithoutTyping() async {
        let cases: [(Error, String?)] = [
            (TranscriptionError.interrupted(kept: "Seven blue kites over"), "Seven blue kites over"),
            (TranscriptionError.interrupted(kept: ""), "Seven blue"),
            (FakeSession.Failure.stop, "Seven blue"),
        ]
        for (error, expected) in cases {
            let session = FakeSession()
            session.stopError = error
            let injector = FakeInjector()
            let history = FakeHistory()
            let hud = FakeHUD()
            let coordinator = makeCoordinator(session: session, injector: injector, history: history, hud: hud)
            await coordinator.toggle()
            session.emit("Seven blue")
            await coordinator.finish()
            #expect(history.saved == [expected!])
            #expect(injector.delivered.isEmpty)
            #expect(hud.phases.last == .liveTextKept)
            #expect(coordinator.state == .idle)
        }
        // Nothing was recognized: nothing to keep, nothing saved.
        let session = FakeSession()
        session.stopError = FakeSession.Failure.stop
        let history = FakeHistory()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(session: session, history: history, hud: hud)
        await coordinator.toggle()
        await coordinator.finish()
        #expect(history.saved.isEmpty)
        #expect(hud.hideDelays.last == 0)
    }

    @Test func holdAndContinuousEffectsDriveTheSameTake() async {
        for presses in [[RightCommandActivation.Effect.start, .finish],
                        [.start, .pause, .resume, .finish]] {
            let session = FakeSession()
            let injector = FakeInjector()
            let hud = FakeHUD()
            let coordinator = makeCoordinator(session: session, injector: injector, hud: hud, liveTextMode: { .typeInApp })
            for effect in presses.dropLast() { coordinator.handle(effect) }
            await Task.yield()
            while session.startCalled == 0 { await Task.yield() }
            session.emit("live words")
            coordinator.handle(.finish)
            while coordinator.state != .idle { await Task.yield() }
            #expect(hud.partials == ["live words"])
            #expect(injector.delivered == ["hello world"])
        }
    }

    // MARK: Feed and display

    @Test func feedNumbersInOrderCoalescesAndStopsAtFinish() async throws {
        var delivered: [TranscriptUpdate] = []
        let feed = LiveTranscriptFeed(session: "take-a") { delivered.append($0) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                for index in 0..<200 { feed.post("word \(index)") }
                done.resume()
            }
        }
        while delivered.last?.text != "word 199" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(delivered.count < 200)
        #expect(delivered.map(\.sequence) == delivered.map(\.sequence).sorted())
        #expect(Set(delivered.map(\.session)) == ["take-a"])
        feed.post("before finish")
        let final = feed.finish("final words")
        feed.post("after finish")
        try await Task.sleep(for: .milliseconds(50))
        #expect(final.isFinal)
        #expect(final.sequence > 200)
        #expect(!delivered.contains { $0.text == "after finish" || $0.text == "before finish" })
    }

    @Test func previewShowsTheEndOfLongTextAtWholeWords() {
        #expect(LivePreviewText.tail(of: "  short text ") == "short text")
        let words = (1...200).map { "word\($0)" }.joined(separator: " ")
        let tail = LivePreviewText.tail(of: words, limit: 60)
        #expect(tail.hasPrefix("…word"))
        #expect(tail.hasSuffix("word200"))
        #expect(tail.count <= 61)
        let pieces = tail.dropFirst().split(separator: " ")
        #expect(pieces.allSatisfy { words.split(separator: " ").contains($0) })
    }

    @Test func placementMovesOffTheCaret() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let card = NSRect(x: 300, y: 40, width: 380, height: 110)
        #expect(HUDPlacement.origin(for: card, avoiding: nil, in: bounds) == card.origin)
        #expect(HUDPlacement.origin(for: card, avoiding: NSRect(x: 10, y: 700, width: 2, height: 16), in: bounds) == card.origin)
        let caret = NSRect(x: 400, y: 80, width: 2, height: 16)
        let moved = HUDPlacement.origin(for: card, avoiding: caret, in: bounds)
        #expect(moved.y >= caret.maxY)
        #expect(!NSRect(origin: moved, size: card.size).intersects(caret))
        let highCaret = NSRect(x: 400, y: 760, width: 2, height: 16)
        let highCard = NSRect(x: 300, y: 690, width: 380, height: 110)
        let below = HUDPlacement.origin(for: highCard, avoiding: highCaret, in: bounds)
        #expect(below.y + highCard.height <= highCaret.minY)
    }

    // MARK: Native panel (real AppKit window on this Mac)

    @Test func previewPanelNeverTakesFocusOrTouchesTheClipboard() async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clipboard = NSPasteboard.general.changeCount
        let hud = HUDController()
        hud.show(device: nil, livePreview: false)
        let panel = try #require(hud.panelForTesting)
        #expect(panel.frame.size == NSSize(width: RecordingHUDView.capsuleSize.width, height: RecordingHUDView.capsuleSize.height))
        hud.hide(after: 0)

        hud.show(device: nil, livePreview: true)
        for index in 1...60 { hud.setPartial((1...index).map { "kite\($0)" }.joined(separator: " ")) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isKeyWindow)
        #expect(NSApp.keyWindow !== panel)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.isVisible)
        #expect(panel.frame.width > RecordingHUDView.capsuleSize.width && panel.frame.height > RecordingHUDView.capsuleSize.height)
        let screen = try #require(panel.screen)
        #expect(screen.visibleFrame.contains(panel.frame))
        #expect(hud.model.partial.hasSuffix("kite60"))
        #expect(hud.model.partial.count <= 241)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        #expect(NSPasteboard.general.changeCount == clipboard)

        hud.hide(after: 0)
        #expect(hud.model.partial.isEmpty)
        #expect(!panel.isVisible)
        hud.show(device: nil, livePreview: false)
        #expect(hud.model.partial.isEmpty)
        #expect(!hud.model.livePreview)
        #expect(panel.frame.size == NSSize(width: RecordingHUDView.capsuleSize.width, height: RecordingHUDView.capsuleSize.height))
        hud.setPartial("must not appear when Off")
        #expect(hud.model.partial.isEmpty)
        hud.hide(after: 0)
    }

    /// Words that could not go in are offered whole: the card holds all of
    /// them (the live tail is for live words only), the text scrolls instead
    /// of growing past about ten lines, and Copy puts all of it on the clipboard.
    @Test func copyCardShowsAllOfTheTextAndCopiesAllOfIt() throws {
        let board = NSPasteboard(name: .init("pflow.copycard.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let words = (1...600).map { "word\($0)" }.joined(separator: " ")
        let hud = HUDController(pasteboard: board)
        hud.show(device: nil, livePreview: false)
        hud.setLivePreview(true)
        hud.setPartial(words)
        #expect(hud.model.partial.hasPrefix("…"), "live words show as a tail")
        hud.setReason("Accessibility is off, so pFlow could not put the text in.")
        hud.offerCopy(words)
        #expect(hud.model.partial == words, "the card holds every word once they are offered")
        hud.model.onCopy?()
        #expect(board.string(forType: .string) == words, "Copy puts the whole text on the clipboard")
        #expect(hud.model.copied)

        let view = NSHostingView(rootView: RecordingHUDView(model: hud.model))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + all($0) } }
        let scroll = try #require(all(view).compactMap { $0 as? NSScrollView }.first, "the whole text scrolls")
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(text.string == words && text.isSelectable && !text.isEditable, "all of the words, selectable")
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let line = ceil(font.ascender - font.descender + font.leading)
        #expect(text.frame.height > scroll.contentView.bounds.height + line, "600 words are taller than the box, so it scrolls: \(text.frame.height) in \(scroll.contentView.bounds.height)")
        #expect(scroll.frame.height <= line * CGFloat(RecordingHUDView.wholeTextLines) + 1, "the box holds about ten lines: \(scroll.frame.height)")
        #expect(view.fittingSize.height < line * CGFloat(RecordingHUDView.wholeTextLines) + 160, "the card never grows past the box plus its rows: \(view.fittingSize.height)")
        hud.hide(after: 0)
        #expect(hud.model.reason == nil && hud.model.copyOffer == nil)
    }

    @Test func cardKeepsOneSizeWhileWordsGrowAndShowsTheNoteInItsHeader() throws {
        var heights: [CGFloat] = []
        for words in ["", "Seven", "The lighthouse keeper counted seven blue kites over the quiet harbor, then waved goodbye to the pelicans and walked home along the sea wall, where the orchard lanterns glowed."] {
            let model = HUDModel()
            model.livePreview = true
            model.partial = LivePreviewText.tail(of: words)
            model.liveNote = words.isEmpty ? nil : "Stopped: cursor moved"
            let view = NSHostingView(rootView: RecordingHUDView(model: model))
            heights.append(view.fittingSize.height)
        }
        #expect(Set(heights).count == 1, "the card must not change height as words arrive: \(heights)")
        // Four whole lines: the box top falls between lines, so the fade never cuts a glyph.
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let line = ceil(font.ascender - font.descender + font.leading)
        #expect(heights[0] >= line * 4 + 20, "room for four lines and the header")
        #expect(heights[0] < line * 5 + 20 + 3 * Theme.s3, "not more than four lines")
    }

    @Test func previewFitsSmallScreensAndLargeTextInLightAndDark() throws {
        let shots = ProcessInfo.processInfo.environment["PFLOW_HUD_SHOTS"].map { URL(fileURLWithPath: $0) }
        let text = "The lighthouse keeper counted seven blue kites over the quiet harbor, then waved goodbye to the pelicans and walked home along the sea wall, where the orchard lanterns glowed."
        var heights: [String: CGFloat] = [:]
        for width in [HUDModel.previewWidth, 288] {
            for (sizeName, size) in [("normal", DynamicTypeSize.large), ("large", .accessibility2)] {
                for (look, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light),
                                                   ("dark", .darkAqua, .dark)] {
                    let model = HUDModel()
                    model.livePreview = true
                    model.colorScheme = scheme
                    model.previewMaxWidth = width
                    model.partial = LivePreviewText.tail(of: text)
                    let view = NSHostingView(rootView: RecordingHUDView(model: model)
                        .environment(\.dynamicTypeSize, size))
                    view.appearance = NSAppearance(named: appearance)
                    let fitting = view.fittingSize
                    view.frame = NSRect(origin: .zero, size: fitting)
                    view.layoutSubtreeIfNeeded()
                    #expect(fitting.width == width)
                    #expect(fitting.height < 400)
                    heights["\(Int(width))-\(sizeName)"] = fitting.height
                    if let shots, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
                        try rep.representation(using: .png, properties: [:])?
                            .write(to: shots.appending(path: "preview-\(Int(width))-\(sizeName)-\(look).png"))
                    }
                }
            }
        }
        if let shots {
            for (look, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
                for (name, note, phase, words) in [("listening", nil, HUDPhase.listening, text),
                                                   ("empty", nil, .listening, ""),
                                                   ("typing-stopped", "Stopped: cursor moved", .listening, text),
                                                   ("cannot-type", "Can't type in this app", .listening, "Buy rope and a lantern"),
                                                   ("finishing", nil, .transcribing, text),
                                                   ("kept", nil, .liveTextKept, text)] {
                    let model = HUDModel()
                    model.livePreview = true
                    model.colorScheme = scheme
                    model.phase = phase
                    model.partial = LivePreviewText.tail(of: words)
                    model.liveNote = note
                    model.levels = (0..<HUDModel.waveformSampleCount).map { Float(0.15 + 0.6 * abs(sin(Double($0) * 0.7))) }
                    let view = NSHostingView(rootView: RecordingHUDView(model: model))
                    view.appearance = NSAppearance(named: appearance)
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try rep.representation(using: .png, properties: [:])?
                            .write(to: shots.appending(path: "card-\(name)-\(look).png"))
                    }
                }
                for (mode, engine) in [(LiveTextMode.off, TranscriptionEngine.apple), (.typeInApp, .apple),
                                       (.typeInApp, .whisper)] {
                    let view = NSHostingView(rootView: Card {
                        LiveTextPicker(mode: .constant(mode), engine: engine)
                    }.frame(width: 460).padding(Theme.s4).background(Color(nsColor: .windowBackgroundColor)))
                    view.appearance = NSAppearance(named: appearance)
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try rep.representation(using: .png, properties: [:])?
                            .write(to: shots.appending(path: "settings-\(mode.rawValue)-\(engine.rawValue)-\(look).png"))
                    }
                }
            }
        }
        print("pflow-hud-heights \(heights.sorted { $0.key < $1.key })")
        #expect(heights["380-large"]! > heights["380-normal"]!)
    }
}
