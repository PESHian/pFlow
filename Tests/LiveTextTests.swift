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
        let scratch = ScratchDefaults("pflow.livetext.tests")
        defer { withExtendedLifetime(scratch) {} }
        let name = scratch.name
        let defaults = scratch.defaults
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
        let retiredScratch = ScratchDefaults("pflow-live-text-retired-preview")
        defer { withExtendedLifetime(retiredScratch) {} }
        let retired = retiredScratch.defaults
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
        // Type mode with no field to type into: pFlow's own preview shows the words.
        #expect(hud.previews == [false, true])
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
            #expect(hud.previews == [true], "no live field: the words show in pFlow's own preview")
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
            #expect(hud.reasons.last == RecordingCoordinator.keptNote)
            #expect(hud.offers.last == expected, "the kept words are offered on the card")
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

    /// History is in memory only this launch (its file could not be opened): no card says "Saved in
    /// History"; each says the words are kept until pFlow quits (review S3).
    @Test func theCardNeverSaysSavedInHistoryWhenHistoryIsNotSaved() {
        let phases: [HUDPhase] = [.savedToHistory, .typingStopped, .liveTextKept, .liveTextKeptTyped]
        for phase in phases {
            #expect(RecordingHUDView.title(phase, historySaved: true).contains("History"))
            let unsaved = RecordingHUDView.title(phase, historySaved: false)
            #expect(!unsaved.contains("saved in History") && !unsaved.contains("also in History") && unsaved.contains("until pFlow quits"), "\(phase): \(unsaved)")
        }
        #expect(RecordingHUDView.kept(historySaved: true) == "Saved in History")
        #expect(!RecordingHUDView.kept(historySaved: false).contains("Saved in History"))
        let hud = HUDController(pasteboard: NSPasteboard(name: .init("pflow.history.tests.\(UUID().uuidString)")))
        #expect(hud.model.historySaved, "saved unless pFlow says otherwise")
    }

    /// The clipboard refused the words: the button never says "Copied" (hunt H9).
    @Test func copySaysCopiedOnlyWhenTheClipboardTookTheWords() {
        let hud = HUDController(pasteboard: NSPasteboard(name: .init("pflow.copyfail.tests.\(UUID().uuidString)")))
        hud.writeClipboard = { _ in false }
        hud.offerCopy("The harbor opens at dawn.")
        hud.model.onCopy?()
        #expect(!hud.model.copied, "still Copy, to press again")
        hud.writeClipboard = { _ in true }
        hud.model.onCopy?()
        #expect(hud.model.copied)
    }

    /// The capsule is one low pill (70x22 pt) in every phase;
    /// a status after the take is an icon, its words on the card.
    @Test func capsuleIsThePillSizeWhileRecordingAndFinishing() throws {
        #expect(RecordingHUDView.capsuleSize == CGSize(width: 70, height: 22))
        for phase in [HUDPhase.listening, .confirmCancel, .transcribing, .cleaning] {
            for style in WaveformStyle.allCases {
                let model = HUDModel()
                model.phase = phase
                model.waveformStyle = style
                model.levels = (0..<HUDModel.waveformSampleCount).map { Float($0 % 5) / 5 }
                let host = NSHostingView(rootView: RecordingHUDView(model: model))
                #expect(host.fittingSize == NSSize(width: 70, height: 22), "\(phase) \(style): \(host.fittingSize)")
            }
        }
        for phase in [HUDPhase.copied, .pasteUnconfirmed, .savedToHistory, .failed, .liveTextKept, .liveTextKeptTyped,
                      .passwordField, .typingStopped, .typedTextLeft] {
            let model = HUDModel()
            model.phase = phase
            let host = NSHostingView(rootView: RecordingHUDView(model: model))
            #expect(host.fittingSize == NSSize(width: 70, height: 22), "one size, an icon at most: \(phase): \(host.fittingSize)")
        }
    }

    /// A card with only a reason (password field, recording did not start,
    /// cancelled) is one compact row sized to its sentence, with close; a
    /// card with words keeps the words, Copy and close.
    @Test func aReasonOnlyCardIsOneCompactRowWithClose() {
        let model = HUDModel()
        model.livePreview = true
        model.phase = .passwordField
        model.reason = RecordingCoordinator.passwordNote
        var closed = false
        model.onClose = { closed = true }
        let host = NSHostingView(rootView: RecordingHUDView(model: model))
        #expect(host.fittingSize.height <= 56, "one row: \(host.fittingSize)")
        let withWords = HUDModel()
        withWords.livePreview = true
        withWords.phase = .liveTextKept
        withWords.reason = RecordingCoordinator.keptNote
        withWords.partial = "Seven blue kites drift over the dunes."
        withWords.copyOffer = withWords.partial
        #expect(NSHostingView(rootView: RecordingHUDView(model: withWords)).fittingSize.height > 90)
        model.onClose?()
        #expect(closed)
        #expect(!RecordingCoordinator.keptNote.contains("History"), "History is named once, in the card's footer")
    }

    /// A panel macOS no longer keeps on the person's desktop (the owner's Mac:
    /// the reused panel sat on Space 4 while he worked on Space 8) is dropped and
    /// a fresh one shows: when a take starts, and while one shows, on a desktop
    /// switch or a display change.
    @Test func aPanelOffTheActiveDesktopIsReplacedByAFreshOne() throws {
        let scratch = ScratchDefaults("pflow.hud.tests")
        let hud = HUDController(pasteboard: NSPasteboard(name: .init("pflow.space.tests.\(UUID().uuidString)")), defaults: scratch.defaults)
        hud.show(device: nil, livePreview: false)
        let first = try #require(hud.panelForTesting)
        #expect(first.isOnActiveSpace, "a real panel shows on the active desktop")
        hud.hide(after: 0)

        var stuck = Set<ObjectIdentifier>()
        hud.isOnActiveSpace = { !stuck.contains(ObjectIdentifier($0)) }
        stuck.insert(ObjectIdentifier(first))
        hud.show(device: nil, livePreview: false)
        let fresh = try #require(hud.panelForTesting)
        #expect(fresh !== first, "a take starts in a fresh panel")
        #expect(fresh.isVisible && !first.isVisible)
        #expect(fresh.frame.size == NSSize(width: RecordingHUDView.capsuleSize.width, height: RecordingHUDView.capsuleSize.height))

        hud.setLivePreview(true)
        hud.setPartial("The harbor opens at dawn")
        stuck.insert(ObjectIdentifier(fresh))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        let afterSwitch = try #require(hud.panelForTesting)
        #expect(afterSwitch !== fresh && afterSwitch.isVisible && !fresh.isVisible, "a desktop switch mid-take")
        #expect(afterSwitch.frame.height > RecordingHUDView.capsuleSize.height, "still the card, words and all")
        #expect(hud.model.partial == "The harbor opens at dawn")

        stuck.insert(ObjectIdentifier(afterSwitch))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        let afterDisplays = try #require(hud.panelForTesting)
        #expect(afterDisplays !== afterSwitch && afterDisplays.isVisible, "a display change mid-take")

        // On the active desktop: kept as it is.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        #expect(hud.panelForTesting === afterDisplays)
        hud.hide(after: 0)
        // Hidden: nothing to check until the next take.
        stuck.insert(ObjectIdentifier(afterDisplays))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        #expect(hud.panelForTesting === afterDisplays)
    }

    /// Only the person's own drag saves the capsule's spot: never pFlow's moves,
    /// never AppKit's moves on a resize (the owner's capsule was saved over his
    /// text that way). A spot off every screen goes back to bottom center; a spot
    /// saved by an older pFlow is not used.
    @Test func onlyThePersonsDragSavesTheCapsuleSpot() throws {
        let scratch = ScratchDefaults("pflow.hud.tests")
        let defaults = scratch.defaults
        defaults.set(672.0, forKey: "pflow.hud.x")
        defaults.set(129.0, forKey: "pflow.hud.y")
        let hud = HUDController(pasteboard: NSPasteboard(name: .init("pflow.spot.tests.\(UUID().uuidString)")), defaults: defaults)
        hud.show(device: nil, livePreview: false)
        let panel = try #require(hud.panelForTesting)
        let visible = try #require(panel.screen).visibleFrame
        #expect(abs(panel.frame.midX - visible.midX) <= 1 && abs(panel.frame.minY - (visible.minY + 40)) <= 1,
                "a spot saved by an older pFlow is not used: \(panel.frame) in \(visible)")
        #expect(defaults.object(forKey: "pflow.hud.x") == nil && defaults.object(forKey: "pflow.hud.y") == nil)
        func moved() { panel.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel)) }

        // pFlow's own moves: the card and back, and the caret avoided.
        hud.setLivePreview(true)
        hud.setLivePreview(false)
        moved()
        // AppKit moving the window as it resizes, and any move with no drag.
        panel.setFrame(NSRect(x: visible.minX + 30, y: visible.minY + 300, width: 380, height: 140), display: false)
        moved()
        panel.setFrameOrigin(NSPoint(x: visible.minX + 50, y: visible.minY + 60))
        moved()
        #expect(defaults.object(forKey: HUDPanel.spotX) == nil && defaults.object(forKey: HUDPanel.spotY) == nil)

        // The person's drag, from where pFlow put it.
        func saved() -> NSPoint? {
            defaults.object(forKey: HUDPanel.spotX) == nil ? nil
                : NSPoint(x: defaults.double(forKey: HUDPanel.spotX), y: defaults.double(forKey: HUDPanel.spotY))
        }
        func near(_ a: NSPoint?, _ b: NSPoint) -> Bool { a.map { abs($0.x - b.x) < 1 && abs($0.y - b.y) < 1 } ?? false }
        panel.reposition()
        panel.personBeganDrag()
        let dragged = NSPoint(x: (visible.minX + 200).rounded(), y: (visible.minY + 150).rounded())
        panel.setFrameOrigin(dragged)
        moved()
        #expect(near(saved(), dragged), "\(String(describing: saved()))")
        // A resize right after the drag moves the window too: not saved.
        panel.setFrame(NSRect(x: visible.minX + 420, y: visible.minY + 260, width: 380, height: 140), display: false)
        moved()
        #expect(near(saved(), dragged), "\(String(describing: saved()))")
        hud.hide(after: 0)
        // Hidden ends the drag: a move afterwards is not the person's.
        panel.setFrameOrigin(NSPoint(x: visible.minX + 500, y: visible.minY + 300))
        moved()
        #expect(near(saved(), dragged), "\(String(describing: saved()))")

        // The next take shows where the person put it.
        hud.show(device: nil, livePreview: false)
        #expect(near(panel.frame.origin, dragged), "\(panel.frame.origin)")
        hud.hide(after: 0)

        // A spot on a screen that is gone: bottom center.
        defaults.set(-90_000.0, forKey: HUDPanel.spotX)
        defaults.set(-90_000.0, forKey: HUDPanel.spotY)
        hud.show(device: nil, livePreview: false)
        #expect(abs(panel.frame.midX - visible.midX) <= 1 && abs(panel.frame.minY - (visible.minY + 40)) <= 1, "\(panel.frame)")
        hud.hide(after: 0)
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(HUDPanel.display(showing: NSRect(x: 5000, y: 5000, width: 70, height: 22), among: screens) == nil)
        #expect(HUDPanel.display(showing: NSRect(x: 1420, y: 100, width: 70, height: 22), among: screens) == screens[1], "most of it")
        #expect(HUDPanel.display(showing: NSRect(x: CGFloat.nan, y: 100, width: 70, height: 22), among: screens) == nil)
    }

    /// The reason-only card's close button, clicked, hides the panel.
    @Test func aReasonOnlyCardClosesWithItsCloseButton() throws {
        let hud = HUDController(pasteboard: NSPasteboard(name: .init("pflow.close.tests.\(UUID().uuidString)")))
        hud.show(device: nil, livePreview: false)
        hud.setLivePreview(true)
        hud.setPhase(.passwordField)
        hud.setReason(RecordingCoordinator.passwordNote)
        let panel = try #require(hud.panelForTesting)
        panel.reposition()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        #expect(panel.isVisible)
        // The × sits at the row's trailing end, inside the card's padding.
        let size = try #require(panel.contentView).bounds.size
        let point = NSPoint(x: size.width - Theme.s4 - 9, y: size.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        #expect(!panel.isVisible, "Close hides the card")
    }

    /// A status after the take shows only its icon in the capsule; its words
    /// are on the card (Press ⌘V) or in the tooltip.
    @Test func aStatusInTheCapsuleIsAnIconWithoutWords() {
        let mark = NSHostingView(rootView: RecordingHUDView.statusMark("Press ⌘V", "doc.on.clipboard"))
        #expect(mark.fittingSize.width <= 24, "an icon, no words: \(mark.fittingSize)")
    }

    /// Every card after a take says what happened in words beside its icon:
    /// never an icon alone (the owner's screenshot: a tiny logo and a lone icon
    /// read as broken).
    @Test func everyAfterTakeCardHeaderHasWords() {
        let all: [HUDPhase] = [.failed, .pasteUnconfirmed, .copied, .savedToHistory, .listening, .confirmCancel, .transcribing,
                               .cleaning, .restarting, .liveTextKept, .liveTextKeptTyped, .passwordField, .typingStopped, .typedTextLeft]
        let working: Set<String> = ["listening", "confirmCancel", "transcribing", "cleaning", "restarting"]
        for phase in all {
            let shown = RecordingHUDView.afterTake(phase)
            guard !working.contains("\(phase)") else {
                #expect(shown == nil, "\(phase) is not after the take")
                continue
            }
            let words = shown?.words ?? ""
            #expect(words.split(separator: " ").count >= 1 && words.count >= 6, "\(phase): \(words)")
            let header = NSHostingView(rootView: RecordingHUDView.afterTakeHeader(phase))
            #expect(header.fittingSize.width >= 60, "\(phase): words beside the icon, \(header.fittingSize)")
            #expect(header.fittingSize.height <= 20, "\(phase): one line in the 20 pt header, \(header.fittingSize)")
        }
    }

    /// The capsule draws the Appearance picker's own waveform for the person's
    /// style, in their colours, at the picker's density: "Lines" is symmetric
    /// thin bars with dots where it is quiet, "Wave" a smooth mirrored envelope.
    /// No jagged trace.
    @Test func capsuleDrawsWhatThePickerShows() {
        let model = HUDModel()
        model.waveformStyle = .lines
        model.palette = ThemePalette(primary: ThemeColor(hex: "AAAAAA")!, secondary: ThemeColor(hex: "AAAAAA")!)
        model.levels = (0..<HUDModel.waveformSampleCount).map { Float($0 % 5) / 5 }
        let wave = RecordingHUDView.capsuleWaveformView(model)
        #expect(wave.style == .lines && wave.palette == model.palette && wave.size == RecordingHUDView.capsuleWaveform)
        // 25 samples per 100 pt in the picker: 12 across the capsule's 46 pt.
        #expect(wave.shownLevels.count == 12)
        let newest = Array(model.levels.suffix(12))
        #expect(Array(wave.shownLevels[3..<9]) == Array(newest[3..<9]), "the newest levels")
        #expect(wave.shownLevels.first! <= newest.first! * 0.12 && wave.shownLevels.last! <= newest.last! * 0.12,
                "quiet at both ends, as the thumbnail")
        let rect = CGRect(origin: .zero, size: RecordingHUDView.capsuleWaveform)
        let quiet = WaveformLines.bars(AudioLevel.waveformLevels(Array(repeating: 0, count: 12)), in: rect)
        #expect(quiet.count == 12 && quiet.allSatisfy { $0.height == 1.2 }, "quiet is a row of dots")
        let voice = WaveformLines.bars(AudioLevel.waveformLevels(wave.shownLevels), in: rect)
        #expect(voice.allSatisfy { abs($0.midY - rect.midY) < 0.001 }, "every bar symmetric about the middle")
        #expect(voice.allSatisfy { $0.width <= 2 }, "thin bars")
        model.waveformStyle = .wave
        #expect(RecordingHUDView.capsuleWaveformView(model).style == .wave)
        let outline = WaveformOutline(levels: AudioLevel.waveformLevels(wave.shownLevels)).path(in: rect).boundingRect
        #expect(abs(outline.midY - rect.midY) < 0.01, "the wave is mirrored about the middle")
        #expect(RecordingWaveform(levels: [], style: .lines).frame == RecordingWaveform.thumbnailSize, "the picker keeps its size")
    }

    /// The panel is measured again when the card's content changes after it
    /// is on screen: the whole text and the Grant row make it taller, and it
    /// stays inside the screen. The capsule keeps 70x22 in every phase.
    @Test func panelGrowsWithTheCopyCardAndStaysOnScreen() throws {
        let hud = HUDController(pasteboard: NSPasteboard(name: .init("pflow.panel.tests.\(UUID().uuidString)")))
        hud.show(device: nil, livePreview: false)
        let panel = try #require(hud.panelForTesting)
        hud.setPhase(.copied)
        #expect(panel.frame.size == NSSize(width: RecordingHUDView.capsuleSize.width, height: RecordingHUDView.capsuleSize.height),
                "the capsule is one size in every phase: \(panel.frame.size)")
        hud.setLivePreview(true)
        hud.setPhase(.savedToHistory)
        let card = panel.frame.height
        hud.setReason(InsertionBlock.accessibilityOff.reason)
        hud.setNeedsAccessibility(true)
        let withGrant = panel.frame.height
        #expect(withGrant > card + 20, "the reason line and the Grant row add height: \(card) → \(withGrant)")
        let words = (1...600).map { "word\($0)" }.joined(separator: " ")
        hud.offerCopy(words)
        let withText = panel.frame.height
        #expect(withText > withGrant + 60, "the whole text adds height: \(withGrant) → \(withText)")
        let screen = try #require(panel.screen)
        #expect(screen.visibleFrame.contains(panel.frame), "\(panel.frame) in \(screen.visibleFrame)")
        hud.hide(after: 0)
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
