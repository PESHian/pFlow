import AppKit
import Testing
@testable import Yap

/// A field typed into with keys (Chrome, Electron, Word): append only, and
/// pFlow's own words are selected at the end for the checked paste.
@MainActor
final class SimulatedKeyField: LiveTextField {
    var current: LiveFieldState
    /// Every write that went out as keys.
    var typed: [String] = []
    var refusal: InsertionBlock?
    var refuseNext: InsertionBlock?
    var selects: [NSRange] = []
    var collapses = 0
    var personActed = false
    var appendOnly: Bool { true }

    init(_ value: String) {
        current = LiveFieldState(app: 1, element: LiveFieldState.target, secure: false, trusted: true, value: value,
                                 selection: NSRange(location: (value as NSString).length, length: 0))
    }

    var value: String { current.value ?? "" }
    func state() -> LiveFieldState { current }
    func canWriteRanges() -> Bool { true }
    func replace(_ range: NSRange, with text: String) -> Bool {
        // Keys can only add at the caret; anything else is a test failure.
        guard range.length == 0, current.selection == NSRange(location: range.location, length: 0) else {
            Issue.record("a key write that is not an append: \(range) \(text)")
            return false
        }
        if let block = refuseNext { refusal = block; refuseNext = nil; return false }
        typed.append(text)
        current.value = (value as NSString).replacingCharacters(in: range, with: text)
        current.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
        return true
    }
    func select(_ range: NSRange) -> Bool { selects.append(range); current.selection = range; return true }
    func collapse() {
        collapses += 1
        if let selection = current.selection { current.selection = NSRange(location: NSMaxRange(selection), length: 0) }
    }
    func personActedSinceSelect() -> Bool { personActed }

    func paste(_ text: String, over range: NSRange) {
        current.value = (value as NSString).replacingCharacters(in: range, with: text)
        current.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
    }

    /// The person types into the field.
    func edit(_ range: NSRange, _ text: String) {
        current.value = (value as NSString).replacingCharacters(in: range, with: text)
        current.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
    }
}

@MainActor
struct InsertionGuardTests {
    // MARK: The one guard rule

    @Test func cleanFactsLetTheTextGo() {
        #expect(InsertionGuard.block(InsertionFacts()) == nil)
    }

    @Test func eachFactStopsTheWriteWithItsOwnReason() {
        func block(_ change: (inout InsertionFacts) -> Void) -> InsertionBlock? {
            var facts = InsertionFacts()
            change(&facts)
            return InsertionGuard.block(facts)
        }
        #expect(block { $0.place = .terminal } == .terminal)
        #expect(block { $0.place = .remote } == .remoteViewer)
        #expect(block { $0.sameApp = false } == .appChanged)
        #expect(block { $0.sameField = false } == .fieldChanged)
        #expect(block { $0.password = true } == .passwordField)
        #expect(block { $0.secureInput = true } == .secureInput)
        #expect(block { $0.modifiersHeld = true } == .interrupted)
        #expect(block { $0.keyDown = true } == .personActed)
        #expect(block { $0.personActed = true } == .personActed)
        #expect(block { $0.composing = true } == .inputMethod)
    }

    @Test func aTerminalIsRefusedWhateverElseHolds() {
        var facts = InsertionFacts()
        facts.place = .terminal
        facts.sameApp = false
        facts.personActed = true
        #expect(InsertionGuard.block(facts) == .terminal)
    }

    // MARK: Places pFlow never types into

    @Test func terminalsAndRemoteViewersAreNoTypePlaces() {
        #expect(NoTypePlaces.place(bundleID: "com.apple.Terminal", elementClasses: []) == .terminal)
        #expect(NoTypePlaces.place(bundleID: "com.googlecode.iterm2", elementClasses: []) == .terminal)
        #expect(NoTypePlaces.place(bundleID: "dev.warp.Warp-Stable", elementClasses: []) == .terminal)
        #expect(NoTypePlaces.place(bundleID: "com.utmapp.UTM", elementClasses: []) == .remote)
        #expect(NoTypePlaces.place(bundleID: "com.microsoft.rdc.macos", elementClasses: []) == .remote)
        #expect(NoTypePlaces.place(bundleID: "com.apple.TextEdit", elementClasses: []) == nil)
    }

    @Test func vsCodesTerminalPaneIsATerminalButItsEditorIsNot() {
        #expect(NoTypePlaces.place(bundleID: "com.microsoft.VSCode", elementClasses: ["xterm-helper-textarea"]) == .terminal)
        #expect(NoTypePlaces.place(bundleID: "com.microsoft.VSCode", elementClasses: ["native-edit-context"]) == nil)
    }

    // MARK: Input methods

    @Test func onlyAnUnfinishedCompositionCountsAsComposing() {
        #expect(InputComposition.composing(markedText: true, inputMethod: false, uncommittedKeys: false))
        #expect(InputComposition.composing(markedText: false, inputMethod: true, uncommittedKeys: true))
        #expect(!InputComposition.composing(markedText: false, inputMethod: true, uncommittedKeys: false),
                "Japanese selected but everything committed: paste as usual")
        #expect(!InputComposition.composing(markedText: false, inputMethod: false, uncommittedKeys: true),
                "typing in a plain layout is no composition")
    }

    @Test func returnEscapeTabAndClicksEndAComposition() {
        let watch = PersonInput()
        watch.record(keyCode: 40)
        #expect(watch.uncommittedKeys)
        for commit: Int64 in [36, 76, 53, 48] {
            watch.record(keyCode: 40)
            watch.record(keyCode: commit)
            #expect(!watch.uncommittedKeys, "key \(commit)")
        }
        watch.record(keyCode: 40)
        watch.record(keyCode: nil)
        #expect(!watch.uncommittedKeys, "a click")
    }

    @Test func nobodyWatchingMeansNobodyCanSayThePersonDidNotAct() {
        let watch = PersonInput()
        #expect(watch.acted(since: 0) == nil)
    }

    // MARK: How live words reach a field

    @Test func webContentAndWordTakeTypedKeysNativeViewsTakeRangeWrites() {
        #expect(LiveFieldMethod.method(webApp: true, bundleID: "com.google.Chrome") == .keys)
        #expect(LiveFieldMethod.method(webApp: true, bundleID: "com.apple.Safari") == .keys)
        #expect(LiveFieldMethod.method(webApp: false, bundleID: "com.microsoft.Word") == .keys)
        #expect(LiveFieldMethod.method(webApp: false, bundleID: "com.apple.TextEdit") == .ranges)
        #expect(LiveFieldMethod.method(webApp: false, bundleID: "org.libreoffice.script") == .ranges)
    }

    // MARK: pFlow's own words at the end

    @Test func theSelectionMustBeExactlyPflowsWords() {
        let own = OwnedWords(range: NSRange(location: 6, length: 9), text: "the light", personActed: { false }, collapse: {})
        #expect(own.mismatch(value: "Note: the light", selection: NSRange(location: 6, length: 9)) == nil)
        #expect(own.mismatch(value: "Note: the\u{00A0}light", selection: NSRange(location: 6, length: 9)) == nil,
                "a browser's no-break space is a space")
        #expect(own.mismatch(value: "Note: the light", selection: NSRange(location: 6, length: 4)) != nil)
        #expect(own.mismatch(value: "Note: the night", selection: NSRange(location: 6, length: 9)) != nil)
        #expect(own.mismatch(value: "Note: the", selection: NSRange(location: 6, length: 9)) != nil)
        #expect(own.mismatch(value: nil, selection: nil) != nil)
    }

    @Test func keyTextIsCutIntoPiecesWithoutSplittingACharacter() {
        let text = "Seven blue kites 🪁🪁 drift over the dunes at dawn, 👩‍👩‍👧 waving."
        let pieces = SyntheticKeys.chunks(text)
        #expect(pieces.joined() == text)
        #expect(pieces.allSatisfy { $0.utf16.count <= SyntheticKeys.unitsPerEvent })
        #expect(pieces.count > 1)
    }

    @Test func pflowsClipboardWritesAreMarkedTransientAndConcealed() throws {
        let item = try #require(TextInjector.clipboardItem(text: "fictional words", formatted: nil, sessionID: "s1"))
        #expect(item.types.contains(TextInjector.transientType))
        #expect(item.types.contains(TextInjector.concealedType))
        #expect(item.string(forType: .string) == "fictional words")
    }

    // MARK: Typed keys: append only, then the end replace

    private func keyCoordinator(_ field: SimulatedKeyField, session: FakeSession, hud: FakeHUD,
                                history: FakeHistory? = nil) -> (RecordingCoordinator, LiveFakeInjector) {
        let history = history ?? FakeHistory()
        let injector = LiveFakeInjector(field: nil)
        injector.keyField = field
        injector.liveField = field
        let coordinator = RecordingCoordinator(
            session: session, injector: injector, history: history, hud: hud, sounds: FakeSounds(),
            cleaner: FakeCleaner(), cleanupEnabled: { false }, vocabulary: { [] }, deviceName: { nil },
            liveTextMode: { .typeInApp }, typingRetryEvery: .milliseconds(5), typingRetryDeadline: 1)
        return (coordinator, injector)
    }

    @Test func typedWordsAreAppendedThenReplacedByTheFinishedTextOnce() async {
        let field = SimulatedKeyField("Note:")
        let session = FakeSession()
        session.textToReturn = "The lighthouse keeper waved."
        let hud = FakeHUD()
        let (coordinator, injector) = keyCoordinator(field, session: session, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("the light")
        session.emit("the lighthouse")
        session.emit("the lighthouse keeper")
        #expect(field.value == "Note: the lighthouse")
        #expect(field.typed == [" the", " lighthouse"], "only additions at the caret, never a revision")
        await coordinator.finish()
        #expect(field.selects == [NSRange(location: 6, length: 14)], "pFlow's words, without the space before them")
        #expect(injector.overSelection.map(\.0) == ["The lighthouse keeper waved."])
        #expect(field.value == "Note: The lighthouse keeper waved.")
        #expect(hud.offers.isEmpty)
        #expect(coordinator.lastOutcome == .pasted)
    }

    @Test func aRevisedWordEndsLiveTypingWithoutAKeyAndTheEndReplaceStillRuns() async {
        let field = SimulatedKeyField("")
        let session = FakeSession()
        session.textToReturn = "Their kites drift."
        let (coordinator, injector) = keyCoordinator(field, session: session, hud: FakeHUD())
        coordinator.begin()
        await Task.yield()
        session.emit("there kites")
        session.emit("there kites drift")
        #expect(field.value == "there kites")
        session.emit("their kites drift")
        session.emit("their kites drift")
        #expect(field.typed == ["there kites"], "the revision sent no key")
        await coordinator.finish()
        #expect(injector.overSelection.count == 1)
        #expect(field.value == "Their kites drift.")
    }

    @Test func aLineBreakEndsLiveTypingRatherThanPressingReturn() async {
        let field = SimulatedKeyField("")
        let session = FakeSession()
        session.textToReturn = "Dear Sam,\nSee you soon."
        let (coordinator, _) = keyCoordinator(field, session: session, hud: FakeHUD())
        coordinator.begin()
        await Task.yield()
        session.emit("dear sam")
        session.emit("dear sam\nsee you")
        session.emit("dear sam\nsee you soon")
        #expect(!field.typed.contains { $0.contains("\n") })
        await coordinator.finish()
        #expect(field.value == "Dear Sam,\nSee you soon.")
    }

    @Test func wordsAlreadyMatchingTheFinishedTextNeedNoReplace() async {
        let field = SimulatedKeyField("")
        let session = FakeSession()
        session.textToReturn = "seven blue kites"
        let (coordinator, injector) = keyCoordinator(field, session: session, hud: FakeHUD())
        coordinator.begin()
        await Task.yield()
        session.emit("seven blue kites")
        session.emit("seven blue kites")
        await coordinator.finish()
        #expect(field.value == "seven blue kites")
        #expect(injector.overSelection.isEmpty)
        #expect(field.selects.isEmpty)
    }

    @Test func thePersonsOwnEditMeansNoSelectAndTheCopyCard() async {
        let field = SimulatedKeyField("")
        let session = FakeSession()
        session.textToReturn = "Nine pelicans rest."
        let hud = FakeHUD()
        let (coordinator, injector) = keyCoordinator(field, session: session, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("nine pelicans")
        session.emit("nine pelicans rest")
        field.edit(NSRange(location: 0, length: 0), "X")
        await coordinator.finish()
        #expect(field.selects.isEmpty, "nothing is selected over the person's text")
        #expect(injector.overSelection.isEmpty)
        #expect(field.value == "Xnine pelicans")
        #expect(hud.offers == ["Nine pelicans rest."])
    }

    @Test func aRefusedReplaceEndsTheSelectionAndOffersTheCard() async {
        let field = SimulatedKeyField("")
        let session = FakeSession()
        session.textToReturn = "The baker left bread."
        let hud = FakeHUD()
        let (coordinator, injector) = keyCoordinator(field, session: session, hud: hud)
        injector.overSelectionOutcome = .savedToHistory(.personActed)
        coordinator.begin()
        await Task.yield()
        session.emit("the baker")
        session.emit("the baker left")
        await coordinator.finish()
        #expect(field.collapses == 1, "pFlow's selection ended without a key")
        #expect(field.value == "the baker", "pFlow's typed words stay; nothing goes over them")
        #expect(hud.offers == ["The baker left bread."])
        #expect(hud.reasons.last == InsertionBlock.personActed.reason)
    }

    @Test func aGuardRefusalBeforeAnyKeyMeansNothingTypedAndTheNormalPaste() async {
        let field = SimulatedKeyField("")
        field.refuseNext = .appChanged
        let session = FakeSession()
        session.textToReturn = "A quiet fox crossed."
        let (coordinator, injector) = keyCoordinator(field, session: session, hud: FakeHUD())
        coordinator.begin()
        await Task.yield()
        session.emit("a quiet")
        session.emit("a quiet fox")
        #expect(field.typed.isEmpty)
        await coordinator.finish()
        #expect(injector.delivered == ["A quiet fox crossed."], "no key went out, so the finished text takes the checked paste")
        #expect(injector.overSelection.isEmpty)
    }

    @Test func switchingAppsAfterTypedWordsNamesTheSwitchOnTheCard() async {
        let field = SimulatedKeyField("")
        let session = FakeSession()
        session.textToReturn = "The copper kettle sings."
        let hud = FakeHUD()
        let (coordinator, injector) = keyCoordinator(field, session: session, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("the copper")
        session.emit("the copper kettle")
        field.refuseNext = .appChanged
        session.emit("the copper kettle sings")
        #expect(field.typed == ["the copper"])
        await coordinator.finish()
        #expect(injector.overSelection.isEmpty, "the words stay; nothing is selected or pasted")
        #expect(hud.reasons.last == LiveInlineOwnership.Stop.app.cardReason)
        #expect(hud.offers == ["The copper kettle sings."])
    }

    @Test func cancellingNeverTakesTypedWordsBackOutWithKeys() async {
        let field = SimulatedKeyField("")
        let session = FakeSession()
        let hud = FakeHUD()
        let (coordinator, _) = keyCoordinator(field, session: session, hud: hud)
        coordinator.begin()
        await Task.yield()
        session.emit("our lantern")
        session.emit("our lantern parade")
        await coordinator.cancel()
        #expect(field.value == "our lantern")
        #expect(field.typed == ["our lantern"])
        #expect(hud.phases.contains(.typedTextLeft))
    }

    @Test func theOwnSpanSkipsTheSpacePflowAddedBeforeItsWords() {
        let start = LiveFieldState(app: 1, element: LiveFieldState.target, secure: false, trusted: true,
                                   value: "Note:", selection: NSRange(location: 5, length: 0))
        guard case .success(var ownership) = LiveInlineOwnership.begin(start, writable: true) else {
            Issue.record("begin refused")
            return
        }
        _ = ownership.update(transcript: "the light", observed: start)
        let step = ownership.update(transcript: "the lighthouse", observed: start)
        guard case .write(let write) = step else { Issue.record("no write"); return }
        var after = start
        after.value = "Note:" + write.text
        after.selection = NSRange(location: 5 + (write.text as NSString).length, length: 0)
        _ = ownership.confirm(accepted: true, observed: after)
        #expect(ownership.ownSpan(after) == NSRange(location: 6, length: 3))
        var edited = after
        edited.value = "Note: tha"
        #expect(ownership.ownSpan(edited) == nil)
    }
}
