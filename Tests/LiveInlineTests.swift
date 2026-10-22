import AppKit
import Testing
@testable import Yap

private final class InlineFixtureBundle {}

/// The shared fixtures in fixtures/live-text/inline-ownership. Windows runs the same files.
private struct InlineFixture: Decodable {
    struct Field: Decodable {
        let app: Int32
        let element: String
        let secure: Bool
        let trusted: Bool
        let value: String?
        let selection: [Int]
    }
    struct Begin: Decodable { let field: Field; let writable: Bool }
    struct Expect: Decodable {
        let action: String
        let range: [Int]?
        let text: String?
        let select: [Int]?
        let confirm: String?
        let reason: String?
    }
    struct Apply: Decodable { let value: String?; let selection: [Int]?; let accepted: Bool? }
    struct FieldCheck: Decodable { let value: String; let selection: [Int] }
    struct Step: Decodable {
        let op: String
        let text: String?
        let range: [Int]?
        let caret: [Int]?
        let pid: Int32?
        let element: String?
        let secure: Bool?
        let trusted: Bool?
        let expect: Expect?
        let apply: Apply?
        let field: FieldCheck?
    }
    let description: String
    let begin: Begin
    let beginResult: String
    let steps: [Step]
}

private func range(_ pair: [Int]) -> NSRange { NSRange(location: pair[0], length: pair[1]) }

/// A field a test owns completely. Writes behave like a well-behaved native
/// text view unless `onReplace` says otherwise.
@MainActor
final class SimulatedTextField: LiveTextField {
    var current: LiveFieldState
    var writable = true
    var replaced: [(NSRange, String)] = []
    /// Return false to fail the write call; may change `current` to model an app that did something else.
    var onReplace: ((SimulatedTextField, NSRange, String) -> Bool)?
    /// Models Chromium and Electron: the write call succeeds but the field
    /// shows the new text only after this many more reads (nil: at once).
    var appliesAfterReads: Int?
    private var pendingApply: (LiveFieldState, Int)?
    /// Runs once, right after the next read, to model a change that lands late.
    var afterNextRead: (() -> Void)?

    init(_ value: String, selection: NSRange? = nil) {
        current = LiveFieldState(app: 1, element: LiveFieldState.target, secure: false, trusted: true, value: value,
                                 selection: selection ?? NSRange(location: (value as NSString).length, length: 0))
    }

    var value: String { current.value ?? "" }

    private(set) var reads = 0
    func state() -> LiveFieldState {
        reads += 1
        if let late = afterNextRead { afterNextRead = nil; defer { late() }; return current }
        if let (applied, after) = pendingApply {
            if after <= 1 { current = applied; pendingApply = nil } else { pendingApply = (applied, after - 1) }
        }
        return current
    }
    func canWriteRanges() -> Bool { writable }
    func replace(_ range: NSRange, with text: String) -> Bool {
        replaced.append((range, text))
        if let onReplace { return onReplace(self, range, text) }
        var applied = current
        applied.value = (value as NSString).replacingCharacters(in: range, with: text)
        applied.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
        if let appliesAfterReads, appliesAfterReads > 0 { pendingApply = (applied, appliesAfterReads) } else { current = applied }
        return true
    }
    func select(_ range: NSRange) -> Bool { current.selection = range; return true }

    /// The person edits the field directly.
    func edit(_ range: NSRange, _ text: String) {
        current.value = (value as NSString).replacingCharacters(in: range, with: text)
        current.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
    }
}

/// An injector whose live typing is the real session and slot, over a simulated field.
@MainActor
final class LiveFakeInjector: TextInjecting {
    var targetApplicationName: String? = "TextEdit"
    var targetApplicationBundleID: String? = "com.apple.TextEdit"
    var targetIsSecure = false
    var field: SimulatedTextField?
    var delivered: [String] = []
    var liveCalls = 0
    /// Models an Electron or Chromium app: `beginLive` finds nothing to type
    /// into and asks for the tree; `retryLive` finds the field after this
    /// many calls (nil: the field is there from the start).
    var fieldReadyAfterRetries: Int?
    /// What `retryLive` finds instead of the field, once it looks.
    var retryStop: LiveInlineOwnership.Stop?
    private(set) var retries = 0
    private var live: LiveInlineSlot = { var slot = LiveInlineSlot(); slot.settle = {}; return slot }()

    init(field: SimulatedTextField?) { self.field = field }

    func captureTarget() {}
    func deliver(_ text: String) async -> InjectionOutcome {
        delivered.append(text)
        return .pasted
    }
    func beginLive(session: String) -> LiveInlineStart {
        if fieldReadyAfterRetries != nil { return .waiting }
        return live.begin(id: session, field: field)
    }
    func retryLive(session: String) -> LiveInlineStart {
        retries += 1
        guard let after = fieldReadyAfterRetries, retries >= after else { return .waiting }
        if let retryStop { return .preview(retryStop) }
        return live.begin(id: session, field: field)
    }
    func reconcileLive(session: String, transcript: String) -> LiveInlineOwnership.Stop? {
        liveCalls += 1
        return live.reconcile(session: session, transcript: transcript)
    }
    func typedLive(session: String) -> Bool { live.typed(session: session) }
    func finalizeLive(session: String, text: String) -> LiveInlineFinal { live.finalize(session: session, text: text) }
    func cancelLive(session: String) -> LiveInlineCancel { live.cancel(session: session) }
}

@MainActor
struct LiveInlineTests {
    // MARK: Shared ownership fixtures

    @Test func sharedOwnershipFixturesProduceTheirExpectedWrites() throws {
        let folder = try #require(Bundle(for: InlineFixtureBundle.self).url(forResource: "inline-ownership", withExtension: nil))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count >= 28)
        for file in files {
            let name = file.lastPathComponent
            let fixture = try JSONDecoder().decode(InlineFixture.self, from: Data(contentsOf: file))
            let start = fixture.begin.field
            var state = LiveFieldState(app: start.app, element: start.element, secure: start.secure,
                                       trusted: start.trusted, value: start.value, selection: range(start.selection))
            var ownership: LiveInlineOwnership
            switch LiveInlineOwnership.begin(state, writable: fixture.begin.writable) {
            case .success(let ready):
                #expect(fixture.beginResult == "ready", "\(name): began")
                ownership = ready
            case .failure(let stop):
                #expect(stop.rawValue == fixture.beginResult, "\(name): refused with \(stop)")
                continue
            }
            for (index, step) in fixture.steps.enumerated() {
                let label = "\(name) step \(index) \(step.op)"
                var result: LiveInlineOwnership.Step?
                switch step.op {
                case "edit":
                    let r = range(step.range!)
                    state.value = (state.value! as NSString).replacingCharacters(in: r, with: step.text!)
                    state.selection = step.caret.map(range) ?? NSRange(location: r.location + (step.text! as NSString).length, length: 0)
                case "select": state.selection = range(step.range!)
                case "app": state.app = step.pid!
                case "focus": state.element = step.element!
                case "secure": state.secure = step.secure!
                case "trust": state.trusted = step.trusted!
                case "update": result = ownership.update(transcript: step.text!, observed: state)
                case "final": result = ownership.finalize(text: step.text!, observed: state)
                case "cancel": result = ownership.cancel(observed: state)
                default: Issue.record("\(label): unknown op")
                }
                if let result, let expect = step.expect {
                    switch expect.action {
                    case "none":
                        #expect(result == .none, "\(label)")
                    case "stop":
                        #expect(result == .stopped(LiveInlineOwnership.Stop(rawValue: expect.reason!)!), "\(label)")
                    default:
                        let write = LiveInlineOwnership.Write(range: range(expect.range!), text: expect.text!,
                                                              select: expect.select.map(range))
                        #expect(result == .write(write), "\(label): got \(result)")
                        var accepted = true
                        if let apply = step.apply {
                            state.value = apply.value ?? state.value
                            state.selection = apply.selection.map(range) ?? state.selection
                            accepted = apply.accepted ?? true
                        } else {
                            state.value = (state.value! as NSString).replacingCharacters(in: write.range, with: write.text)
                            state.selection = write.select ?? NSRange(location: write.range.location + (write.text as NSString).length, length: 0)
                        }
                        let confirmed = ownership.confirm(accepted: accepted, observed: state)
                        #expect(confirmed == (expect.confirm == "uncertain" ? .stopped(.uncertain) : .none), "\(label): confirm")
                    }
                }
                if let field = step.field {
                    #expect(state.value.map { Array($0.utf16) } == Array(field.value.utf16), "\(label): value")
                    #expect(state.selection == range(field.selection), "\(label): selection")
                }
            }
        }
    }

    @Test func fieldsTooLongToReadOnEveryUpdateUsePreview() {
        let long = String(repeating: "a", count: LiveInlineOwnership.maxFieldLength + 1)
        let state = LiveFieldState(app: 1, element: LiveFieldState.target, secure: false, trusted: true,
                                   value: long, selection: NSRange(location: 0, length: 0))
        guard case .failure(.unsupported) = LiveInlineOwnership.begin(state, writable: true) else {
            Issue.record("a field over the limit began live typing")
            return
        }
        var fits = state
        fits.value = String(long.dropLast())
        guard case .success = LiveInlineOwnership.begin(fits, writable: true) else {
            Issue.record("a field at the limit did not begin")
            return
        }
    }

    // MARK: Settled words

    @Test func onlyWordsTwoUpdatesAgreeOnAreSettled() {
        #expect(LiveStableText.agreed(previous: nil, current: "The harbor") == "")
        #expect(LiveStableText.agreed(previous: "The harb", current: "The harbor opens") == "The")
        #expect(LiveStableText.agreed(previous: "The harbor", current: "The harbor opens") == "The harbor")
        #expect(LiveStableText.agreed(previous: "Hello world.", current: "Hello world, how") == "Hello world")
        #expect(LiveStableText.agreed(previous: "I don", current: "I don't know") == "I")
        #expect(LiveStableText.agreed(previous: "你好世", current: "你好世界") == "你好世")
        #expect(LiveStableText.agreed(previous: "Same words", current: "Same words") == "Same words")
        #expect(LiveStableText.agreed(previous: "On the first cold night.", current: "The harbor") == "")
    }

    // MARK: Coordinator with typing

    private func typingCoordinator(_ field: SimulatedTextField?, session: FakeSession? = nil,
                                   history: FakeHistory? = nil, hud: FakeHUD? = nil,
                                   formatter: TemplateFormatting? = nil,
                                   templates: [DictationTemplate] = [],
                                   retryDeadline: TimeInterval = 1) -> (RecordingCoordinator, LiveFakeInjector) {
        let injector = LiveFakeInjector(field: field)
        let coordinator = RecordingCoordinator(
            session: session ?? FakeSession(), injector: injector, history: history ?? FakeHistory(),
            hud: hud ?? FakeHUD(), sounds: FakeSounds(),
            cleaner: FakeCleaner(), cleanupEnabled: { false }, vocabulary: { [] }, deviceName: { nil },
            formatter: formatter, availableTemplates: { templates }, liveTextMode: { .typeInApp },
            typingRetryEvery: .milliseconds(5), typingRetryDeadline: retryDeadline)
        return (coordinator, injector)
    }

    // MARK: Electron and Chromium apps: the field arrives after the ask

    @Test func typesIntoAWebAppOnceItsAccessibilityTreeIsThere() async {
        let field = SimulatedTextField("Note: ")
        let session = FakeSession()
        let hud = FakeHUD()
        session.textToReturn = "the lighthouse keeper waved"
        let (coordinator, injector) = typingCoordinator(field, session: session, hud: hud)
        injector.fieldReadyAfterRetries = 2
        coordinator.begin()
        await Task.yield()
        #expect(hud.typeInApps == [false], "the capsule shows while the app builds its tree")
        #expect(hud.notes.last == "Typing in TextEdit")
        session.emit("the light")
        #expect(field.replaced.isEmpty, "nothing is typed before the field is there")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(injector.retries == 2)
        session.emit("the lighthouse")
        session.emit("the lighthouse keeper")
        #expect(field.value == "Note: the lighthouse")
        await coordinator.finish()
        #expect(field.value == "Note: the lighthouse keeper waved")
        #expect(injector.delivered.isEmpty)
        #expect(hud.cards.isEmpty, "the card never showed")
    }

    @Test func showsTheCardWhenAWebAppNeverOffersAField() async {
        let field = SimulatedTextField("Note: ")
        let session = FakeSession()
        let hud = FakeHUD()
        session.textToReturn = "the lighthouse keeper waved"
        let (coordinator, injector) = typingCoordinator(field, session: session, hud: hud, retryDeadline: 0.05)
        injector.fieldReadyAfterRetries = 1_000
        coordinator.begin()
        await Task.yield()
        #expect(hud.typeInApps == [false])
        try? await Task.sleep(for: .milliseconds(150))
        #expect(hud.cards.last == true, "time ran out, so the card shows")
        #expect(hud.notes.last == "Can't type in this app")
        let retries = injector.retries
        #expect(retries >= 1)
        session.emit("the light")
        #expect(field.replaced.isEmpty)
        await coordinator.finish()
        #expect(injector.delivered == ["the lighthouse keeper waved"], "the finished text goes in the normal way")
        #expect(injector.retries == retries, "no more looking once the card shows")
    }

    @Test func stopsLookingForTheFieldWhenTheTakeEnds() async {
        let field = SimulatedTextField("Note: ")
        let session = FakeSession()
        session.textToReturn = "the lighthouse keeper waved"
        let (coordinator, injector) = typingCoordinator(field, session: session, retryDeadline: 10)
        injector.fieldReadyAfterRetries = 1_000
        coordinator.begin()
        await Task.yield()
        await coordinator.finish()
        #expect(injector.delivered == ["the lighthouse keeper waved"])
        let retries = injector.retries
        try? await Task.sleep(for: .milliseconds(40))
        #expect(injector.retries == retries, "the take ended, so no more looking")
        #expect(field.replaced.isEmpty)
    }

    @Test func aPasswordFieldFoundAfterTheAskShowsTheCard() async {
        let field = SimulatedTextField("Note: ")
        let session = FakeSession()
        let hud = FakeHUD()
        session.textToReturn = "the lighthouse keeper waved"
        let (coordinator, injector) = typingCoordinator(field, session: session, hud: hud)
        injector.fieldReadyAfterRetries = 1
        injector.retryStop = .secure
        coordinator.begin()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(hud.cards.last == true)
        #expect(hud.notes.last == "Secure input is on")
        await coordinator.finish()
        #expect(field.replaced.isEmpty)
        #expect(injector.delivered == ["the lighthouse keeper waved"])
    }

    @Test func typesSettledWordsThenReplacesThemWithTheFinishedTextOnce() async {
        let field = SimulatedTextField("Note: ")
        let session = FakeSession()
        let history = FakeHistory()
        let hud = FakeHUD()
        session.textToReturn = "the lighthouse keeper waved"
        let (coordinator, injector) = typingCoordinator(field, session: session, history: history, hud: hud)
        coordinator.begin()
        await Task.yield()
        #expect(hud.notes.last == "Typing in TextEdit")
        #expect(hud.typeInApps == [false], "while pFlow types in the app only the capsule shows")
        #expect(hud.cards.isEmpty)
        session.emit("the light")
        session.emit("the lighthouse")
        #expect(field.value == "Note: the")
        session.emit("the lighthouse keeper")
        #expect(field.value == "Note: the lighthouse")
        await coordinator.finish()
        #expect(field.value == "Note: the lighthouse keeper waved")
        #expect(field.current.selection == NSRange(location: 33, length: 0))
        #expect(injector.delivered.isEmpty)
        #expect(history.saved == ["the lighthouse keeper waved"])
        #expect(hud.phases.last == .transcribing)
    }

    @Test func movingTheCaretStopsTypingAndKeepsTheFinishedTextInHistoryOnly() async {
        let field = SimulatedTextField("Dear Sam, ")
        let session = FakeSession()
        let history = FakeHistory()
        let hud = FakeHUD()
        session.textToReturn = "thanks for the map and the compass"
        let (coordinator, injector) = typingCoordinator(field, session: session, history: history, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("thanks for")
        session.emit("thanks for the map")
        #expect(field.value == "Dear Sam, thanks for")
        field.current.selection = NSRange(location: 0, length: 0)
        #expect(hud.typeInApps == [false] && hud.cards.isEmpty, "capsule only while typing works")
        session.emit("thanks for the map and")
        #expect(hud.notes.last == "Stopped: cursor moved")
        #expect(hud.cards.first == true, "typing stopped, so the card shows the words and the note")
        #expect(hud.partials.last == "thanks for the map and")
        field.current.selection = NSRange(location: 20, length: 0)
        session.emit("thanks for the map and the")
        await coordinator.finish()
        #expect(field.value == "Dear Sam, thanks for")
        #expect(field.replaced.count == 1)
        #expect(injector.delivered.isEmpty)
        #expect(history.saved == ["thanks for the map and the compass"])
        #expect(hud.phases.last == .typingStopped)
        #expect(hud.offers == ["thanks for the map and the compass"], "the card keeps the finished text with Copy")
        #expect(hud.hideDelays.last != 4, "the card stays until closed or the next take")
    }

    /// An app that refuses every write call (returns an error, field
    /// unchanged) typed nothing, so the finished text goes in the normal way,
    /// exactly as in Preview mode, not History only.
    @Test func writesTheAppRefusedMeanNothingWasTypedSoTheFinishedTextIsInsertedNormally() async {
        let field = SimulatedTextField("Chat: ")
        field.onReplace = { _, _, _ in false }
        let session = FakeSession()
        let history = FakeHistory()
        let hud = FakeHUD()
        session.textToReturn = "meet at the lighthouse at noon"
        let (coordinator, injector) = typingCoordinator(field, session: session, history: history, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("meet at")
        session.emit("meet at the lighthouse")
        #expect(field.value == "Chat: " && field.replaced.count == 1)
        #expect(hud.cards.first == true, "typing stopped, so the card shows the words")
        await coordinator.finish()
        #expect(injector.delivered == ["meet at the lighthouse at noon"], "the final goes in like Preview mode")
        #expect(history.saved == ["meet at the lighthouse at noon"])
        #expect(hud.phases.last != .typingStopped)
        #expect(field.replaced.count == 1, "no second write into a field that refuses writes")
    }

    /// A write call that succeeded may have put words in even when the field
    /// still reads back the old text (Chromium, Electron apply it later): the
    /// finished text must not be pasted on top. It stays on the card with Copy.
    @Test func aSuccessfulWriteWithStaleReadBackCountsAsTypedSoNothingIsPastedOnTop() async {
        let field = SimulatedTextField("Chat: ")
        field.onReplace = { _, _, _ in true }   // says yes, never shows it
        let session = FakeSession()
        let history = FakeHistory()
        let hud = FakeHUD()
        session.textToReturn = "meet at the lighthouse at noon"
        let (coordinator, injector) = typingCoordinator(field, session: session, history: history, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("meet at")
        session.emit("meet at the lighthouse")
        #expect(field.replaced.count == 1)
        await coordinator.finish()
        #expect(injector.delivered.isEmpty, "never paste on top of words that may be there")
        #expect(history.saved == ["meet at the lighthouse at noon"])
        #expect(hud.phases.last == .typingStopped)
        #expect(hud.offers == ["meet at the lighthouse at noon"] && hud.livePreview, "the card keeps the words with Copy")
    }

    /// A write the app accepted but shows only later is judged by its
    /// read-back at once: typing stops, and because the call succeeded the
    /// finished text is never pasted on top; it stays on the card with Copy.
    @Test func aWriteShownAFewReadsLaterKeepsTyping() async {
        let field = SimulatedTextField("Note: ")
        field.appliesAfterReads = 3
        let session = FakeSession()
        let hud = FakeHUD()
        session.textToReturn = "the lighthouse keeper waved"
        let (coordinator, injector) = typingCoordinator(field, session: session, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("the light")
        session.emit("the lighthouse")
        #expect(field.value == "Note: the")
        session.emit("the lighthouse keeper")
        #expect(field.value == "Note: the lighthouse")
        #expect(hud.cards.isEmpty, "typing went on")
        await coordinator.finish()
        #expect(field.value == "Note: the lighthouse keeper waved")
        #expect(injector.delivered.isEmpty)
        #expect(hud.offers.isEmpty)
    }

    @Test func aWriteShownTooLateStopsTypingWithoutPastingOnTop() async {
        let field = SimulatedTextField("Note: ")
        field.appliesAfterReads = LiveInlineSession.applyReads + 2
        let session = FakeSession()
        let hud = FakeHUD()
        session.textToReturn = "the lighthouse keeper waved"
        let (coordinator, injector) = typingCoordinator(field, session: session, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("the light")
        session.emit("the lighthouse")
        #expect(hud.cards.first == true, "typing stopped")
        await coordinator.finish()
        #expect(injector.delivered.isEmpty)
        #expect(hud.offers == ["the lighthouse keeper waved"] && hud.livePreview)
    }

    /// A write call that returned failure can still land (an Accessibility
    /// call that timed out). The field no longer matches its snapshot, so
    /// the take is typed: no paste on top, the words stay on the card.
    @Test func aRefusedWriteThatStillLandedCountsAsTyped() async {
        for late in [false, true] {
            let field = SimulatedTextField("Chat: ")
            var landed = false
            field.onReplace = { field, range, text in
                let apply = { field.current.value = (field.value as NSString).replacingCharacters(in: range, with: text) }
                if late { field.afterNextRead = apply } else { apply() }
                landed = true
                return false
            }
            let session = FakeSession()
            let hud = FakeHUD()
            session.textToReturn = "meet at the lighthouse at noon"
            let (coordinator, injector) = typingCoordinator(field, session: session, hud: hud)
            coordinator.begin()
            await Task.yield()
            session.emit("meet at")
            session.emit("meet at the lighthouse")
            #expect(landed)
            await coordinator.finish()
            #expect(injector.delivered.isEmpty, "late=\(late): never paste on top of words that landed")
            #expect(hud.offers == ["meet at the lighthouse at noon"] && hud.livePreview, "late=\(late)")
        }
    }

    /// Typing worked all take; only the final write fails (the person clicked
    /// elsewhere during cleanup). The capsule was showing: the words and Copy
    /// must come up on the card, not a stuck capsule.
    @Test func aFinalWriteThatFailsAfterLiveTypingShowsTheCardWithCopy() async {
        let field = SimulatedTextField("Note: ")
        let session = FakeSession()
        let history = FakeHistory()
        let hud = FakeHUD()
        session.textToReturn = "the lighthouse keeper waved"
        let (coordinator, injector) = typingCoordinator(field, session: session, history: history, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("the light")
        session.emit("the lighthouse")
        #expect(field.value == "Note: the" && hud.livePreview == false, "capsule while typing works")
        session.onStop = { field.current.selection = NSRange(location: 0, length: 0) }
        await coordinator.finish()
        #expect(field.value == "Note: the", "nothing more is written after the caret moved")
        #expect(injector.delivered.isEmpty)
        #expect(hud.phases.last == .typingStopped)
        #expect(hud.livePreview && hud.offers == ["the lighthouse keeper waved"], "the card, with the words and Copy")
        #expect(hud.partials.last == "the lighthouse keeper waved")
    }

    @Test func typingRefusedAtStartInsertsTheFinishedTextNormally() async {
        let field = SimulatedTextField("Chat: ")
        field.writable = false
        let session = FakeSession()
        session.textToReturn = "meet at noon"
        let (coordinator, injector) = typingCoordinator(field, session: session)
        coordinator.begin()
        await Task.yield()
        session.emit("meet at")
        await coordinator.finish()
        #expect(injector.delivered == ["meet at noon"])
        #expect(field.replaced.isEmpty)
    }

    @Test func recognitionFailingAfterTypedWordsSaysTheyStayInTheApp() async {
        for typedFirst in [true, false] {
            let field = SimulatedTextField("Note: ")
            let session = FakeSession()
            session.stopError = TranscriptionError.interrupted(kept: "harbor lights glow")
            let history = FakeHistory()
            let hud = FakeHUD()
            let (coordinator, injector) = typingCoordinator(field, session: session, history: history, hud: hud)
            coordinator.begin()
            await Task.yield()
            session.emit("harbor lights")
            if typedFirst { session.emit("harbor lights glow") }
            #expect(field.value == (typedFirst ? "Note: harbor lights" : "Note: "))
            await coordinator.finish()
            #expect(field.value == (typedFirst ? "Note: harbor lights" : "Note: "), "nothing more is typed")
            #expect(injector.delivered.isEmpty)
            #expect(history.saved == ["harbor lights glow"])
            #expect(hud.phases.last == (typedFirst ? .liveTextKeptTyped : .liveTextKept))
        }
    }

    @Test func afterTypingStopsLaterUpdatesNeverReadTheField() {
        let field = SimulatedTextField("Dear Sam, ")
        var slot = LiveInlineSlot()
        #expect(slot.begin(id: "t", field: field) == .typing)
        _ = slot.reconcile(session: "t", transcript: "thanks for")
        _ = slot.reconcile(session: "t", transcript: "thanks for the map")
        #expect(field.value == "Dear Sam, thanks for")
        field.current.selection = NSRange(location: 0, length: 0)
        #expect(slot.reconcile(session: "t", transcript: "thanks for the map and") == .caret)
        let reads = field.reads
        #expect(slot.reconcile(session: "t", transcript: "thanks for the map and the") == nil)
        #expect(slot.reconcile(session: "t", transcript: "thanks for the map and the compass") == nil)
        #expect(field.reads == reads)
        #expect(field.replaced.count == 1)
    }

    @Test func unsupportedFieldUsesPreviewAndTheNormalFinalInsertion() async {
        let field = SimulatedTextField("Notes")
        field.writable = false
        let session = FakeSession()
        let hud = FakeHUD()
        session.textToReturn = "buy rope"
        let (coordinator, injector) = typingCoordinator(field, session: session, hud: hud)
        coordinator.begin()
        await Task.yield()
        #expect(hud.typeInApps == [true])
        #expect(hud.notes.last == "Can't type in this app")
        session.emit("buy")
        session.emit("buy rope")
        #expect(field.replaced.isEmpty)
        #expect(injector.liveCalls == 0)
        await coordinator.finish()
        #expect(injector.delivered == ["buy rope"])
        #expect(field.value == "Notes")
    }

    @Test func cancelRemovesTypedWordsOnlyWhileTheFieldIsExactlyAsLeft() async {
        for userEdits in [false, true] {
            let field = SimulatedTextField("Pack the old tent today", selection: NSRange(location: 9, length: 8))
            let session = FakeSession()
            let hud = FakeHUD()
            let history = FakeHistory()
            let (coordinator, _) = typingCoordinator(field, session: session, history: history, hud: hud)
            coordinator.begin()
            await Task.yield()
            session.emit("new")
            session.emit("new canvas")
            #expect(field.value == "Pack the new today")
            if userEdits { field.edit(NSRange(location: 0, length: 4), "Load") }
            await coordinator.cancel()
            if userEdits {
                #expect(field.value == "Load the new today")
                #expect(hud.phases.last == .typedTextLeft)
            } else {
                #expect(field.value == "Pack the old tent today")
                #expect(field.current.selection == NSRange(location: 9, length: 8))
                #expect(hud.hideDelays.last == 0)
            }
            #expect(history.saved.isEmpty)
        }
    }

    @Test func passwordFieldNeverStartsDictationInAnyMode() async {
        for mode in LiveTextMode.allCases {
            let session = FakeSession()
            let hud = FakeHUD()
            let injector = LiveFakeInjector(field: SimulatedTextField(""))
            injector.targetIsSecure = true
            let coordinator = RecordingCoordinator(
                session: session, injector: injector, history: FakeHistory(), hud: hud, sounds: FakeSounds(),
                cleaner: FakeCleaner(), cleanupEnabled: { false }, vocabulary: { [] }, deviceName: { nil },
                liveTextMode: { mode })
            coordinator.begin()
            await Task.yield()
            #expect(coordinator.state == .idle, "\(mode)")
            #expect(session.startCalled == 0, "\(mode)")
            #expect(hud.phases == [.passwordField], "\(mode)")
        }
    }

    @Test func spokenTemplateCommandIsReplacedByTheFormattedTextOnce() async {
        let field = SimulatedTextField("")
        let session = FakeSession()
        let history = FakeHistory()
        let formatter = FakeFormatter()
        formatter.output = "Narrative\nOfficer Pesh arrived."
        session.textToReturn = "Use the police report template. Officer Pesh arrived."
        let (coordinator, injector) = typingCoordinator(field, session: session, history: history,
                                                        formatter: formatter, templates: [.policeReport])
        coordinator.begin()
        await Task.yield()
        session.emit("Use the police report")
        session.emit("Use the police report template. Officer")
        #expect(field.value == "Use the police report")
        await coordinator.finish()
        #expect(field.value == "Narrative\nOfficer Pesh arrived.")
        #expect(injector.delivered.isEmpty)
        #expect(history.saved == ["Narrative\nOfficer Pesh arrived."])
    }

    @Test func aTakeThatEndsWithNoTextRemovesItsProvisionalWords() async {
        let field = SimulatedTextField("Keep this. ")
        let session = FakeSession()
        let history = FakeHistory()
        session.textToReturn = "um uh"
        let (coordinator, injector) = typingCoordinator(field, session: session, history: history)
        coordinator.begin()
        await Task.yield()
        session.emit("um uh")
        session.emit("um uh")
        #expect(field.value == "Keep this. um uh")
        await coordinator.finish()
        #expect(field.value == "Keep this. ")
        #expect(injector.delivered.isEmpty)
        #expect(history.saved.isEmpty)
    }

    @Test func anUncertainWriteIsNeverRetriedAndTheFinalStaysInHistory() async {
        let field = SimulatedTextField("")
        field.onReplace = { field, range, text in
            field.current.value = (field.value as NSString).replacingCharacters(in: range, with: text + " ")
            field.current.selection = NSRange(location: range.location + (text as NSString).length + 1, length: 0)
            return true
        }
        let session = FakeSession()
        let history = FakeHistory()
        let hud = FakeHUD()
        session.textToReturn = "rain soon then sun"
        let (coordinator, injector) = typingCoordinator(field, session: session, history: history, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("rain")
        session.emit("rain soon")
        #expect(hud.notes.last == "Stopped: couldn't check")
        session.emit("rain soon then")
        await coordinator.finish()
        #expect(field.replaced.count == 1)
        #expect(injector.delivered.isEmpty)
        #expect(history.saved == ["rain soon then sun"])
        #expect(hud.phases.last == .typingStopped)
    }

    @Test func updatesFromAnEarlierTakeNeverWriteIntoTheNextOne() async {
        let session = FakeSession()
        let first = SimulatedTextField("")
        let (coordinator, injector) = typingCoordinator(first, session: session)
        session.textToReturn = "first take"
        coordinator.begin()
        await Task.yield()
        let oldUpdate = session.update("stale words here", isFinal: false)
        await coordinator.finish()
        let second = SimulatedTextField("Second: ")
        injector.field = second
        coordinator.begin()
        await Task.yield()
        session.onTranscript?(oldUpdate)
        session.onTranscript?(TranscriptUpdate(session: oldUpdate.session, sequence: 99, text: "stale words here", isFinal: false))
        #expect(second.replaced.isEmpty)
        #expect(second.value == "Second: ")
        await coordinator.cancel()
    }

    @Test func cleanupAndDictionaryRulesShapeTheTypedFinal() async {
        let field = SimulatedTextField("")
        let session = FakeSession()
        let history = FakeHistory()
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "Senten met us at the dock.\nThen we left." }
        session.textToReturn = "um senten met us at the dock then we left"
        let injector = LiveFakeInjector(field: field)
        let coordinator = RecordingCoordinator(
            session: session, injector: injector, history: history, hud: FakeHUD(), sounds: FakeSounds(),
            cleaner: cleaner, cleanupEnabled: { true }, vocabulary: { [] }, deviceName: { nil },
            replacements: { [DictionaryReplacement(heard: "Senten", replacement: "Sinton")] },
            liveTextMode: { .typeInApp })
        coordinator.begin()
        await Task.yield()
        session.emit("um senten met")
        session.emit("um senten met us")
        #expect(field.value == "um senten met")
        await coordinator.finish()
        #expect(field.value == "Sinton met us at the dock.\nThen we left.")
        #expect(cleaner.cleaned.count == 1)
        #expect(history.saved == ["Sinton met us at the dock.\nThen we left."])
        #expect(injector.delivered.isEmpty)
    }

    @Test func previewModeNeverAsksForLiveTyping() async {
        let field = SimulatedTextField("")
        let injector = LiveFakeInjector(field: field)
        let session = FakeSession()
        session.textToReturn = "plain preview"
        let coordinator = RecordingCoordinator(
            session: session, injector: injector, history: FakeHistory(), hud: FakeHUD(), sounds: FakeSounds(),
            cleaner: FakeCleaner(), cleanupEnabled: { false }, vocabulary: { [] }, deviceName: { nil },
            liveTextMode: { .typeInApp })
        coordinator.begin()
        await Task.yield()
        session.emit("plain")
        session.emit("plain preview")
        await coordinator.finish()
        #expect(field.replaced.isEmpty)
        #expect(injector.liveCalls == 0)
        #expect(injector.delivered == ["plain preview"])
    }
}
