import AppKit
import Testing
@testable import Yap

/// pFlow Dictation (the input method route): the guard for marked text, the
/// route rule, and pFlow's side of a take over a fake channel and fake input sources.
@MainActor
struct InputMethodTests {
    // MARK: Rules

    /// Push-to-talk holds Right Command for the whole take: marked text still goes in.
    @Test func markedTextIgnoresHeldKeysButNeverThePerson() {
        var held = InsertionFacts()
        held.modifiersHeld = true
        held.keyDown = true
        #expect(InsertionGuard.markedTextBlock(held) == nil, "a held Command key does not stop marked text")
        #expect(InsertionGuard.block(held) != nil, "typed keys and pastes still wait for held keys")
        var own = InsertionFacts()
        own.composing = true
        #expect(InsertionGuard.markedTextBlock(own) == nil, "the field's marked text is pFlow's own")
        var acted = InsertionFacts()
        acted.personActed = true
        #expect(InsertionGuard.markedTextBlock(acted) == .personActed)
        var moved = InsertionFacts()
        moved.sameApp = false
        #expect(InsertionGuard.markedTextBlock(moved) == .appChanged)
        var field = InsertionFacts()
        field.sameField = false
        #expect(InsertionGuard.markedTextBlock(field) == .fieldChanged)
        var password = InsertionFacts()
        password.password = true
        #expect(InsertionGuard.markedTextBlock(password) == .passwordField)
        var secure = InsertionFacts()
        secure.secureInput = true
        #expect(InsertionGuard.markedTextBlock(secure) == .secureInput)
    }

    @Test func theInputMethodIsNeverUsedForSecureFieldsTerminalsOrAnOpenComposition() {
        #expect(InputMethodRoute.allowed(secure: false, place: nil, composing: false))
        #expect(!InputMethodRoute.allowed(secure: true, place: nil, composing: false))
        #expect(!InputMethodRoute.allowed(secure: false, place: .terminal, composing: false))
        #expect(!InputMethodRoute.allowed(secure: false, place: .remote, composing: false))
        #expect(!InputMethodRoute.allowed(secure: false, place: nil, composing: true))
    }

    // MARK: A take over a fake channel

    private final class World {
        var current = "com.apple.keylayout.ABC"
        var selects: [String] = []
        var sent: [InputMethodWire.Message] = []
        var now: TimeInterval = 100
        var enabled = true
    }

    private func link(_ world: World) -> InputMethodLink {
        let link = InputMethodLink()
        link.enabled = { world.enabled }
        link.currentSource = { world.current }
        link.selectSource = { world.selects.append($0); world.current = $0; return true }
        link.clock = { world.now }
        link.transmit = { world.sent.append($0); return true }
        link.defaults = UserDefaults(suiteName: "pflow.im.tests.\(UUID().uuidString)")!
        link.connectedForTesting = true
        return link
    }

    @Test func aTakeSelectsTheSourceMarksAndRestoresThePersonsSource() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t1", bundle: "com.google.Chrome"))
        #expect(world.current == InputMethodWire.sourceID)
        #expect(world.sent.first == .init(.begin, take: "t1", bundle: "com.google.Chrome", source: "com.apple.keylayout.ABC", at: 100))
        #expect(link.attachState() == .pending)
        #expect(!link.mark("the harbor"), "nothing is marked before the input method is active in the app")
        link.receive(.init(.client, take: "t1", bundle: "com.google.Chrome", uid: "c1"))
        #expect(link.attachState() == .attached)
        #expect(link.mark("the harbor"))
        #expect(link.mark("the harbor lights"))
        #expect(world.sent.filter { $0.kind == .mark }.map(\.text) == ["the harbor", "the harbor lights"])
        link.end()
        #expect(world.current == "com.apple.keylayout.ABC", "the person's source is back")
        #expect(world.sent.last?.kind == .end)
        link.end()
        #expect(world.selects == [InputMethodWire.sourceID, "com.apple.keylayout.ABC"], "restored once")
    }

    @Test func anotherAppOrNoAnswerMeansTheOtherLivePaths() {
        let world = World()
        let other = link(world)
        #expect(other.begin(id: "t2", bundle: "com.google.Chrome"))
        other.receive(.init(.client, take: "t2", bundle: "com.apple.Notes", uid: "n1"))
        #expect(other.attachState() == .failed("other app"))
        #expect(!other.mark("words"), "never written to another app")
        other.end()
        #expect(world.current == "com.apple.keylayout.ABC")
        let quiet = link(world)
        #expect(quiet.begin(id: "t3", bundle: "com.google.Chrome"))
        world.now += InputMethodLink.attachTimeout + 0.1
        #expect(quiet.attachState() == .failed("timeout"))
        quiet.end()
        #expect(world.current == "com.apple.keylayout.ABC")
    }

    /// A key, a click, another client, or the channel lost: nothing more is written; the source comes back.
    @Test func afterAnInterruptionNothingMoreIsWritten() async {
        for reason in ["key", "click", "appCommit", "clientChanged"] {
            let world = World()
            let link = link(world)
            #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
            link.receive(.init(.client, take: "t", bundle: "com.apple.TextEdit", uid: "u"))
            #expect(link.mark("seven blue"))
            link.receive(.init(.interrupted, take: "t", reason: reason))
            #expect(!link.mark("seven blue kites"), "\(reason): no more marks")
            let commit = await link.commit("Seven blue kites.")
            #expect(!commit.ok, "\(reason): no commit")
            #expect(InputMethodLink.stop(for: reason) != .revised)
            link.end()
            #expect(world.current == "com.apple.keylayout.ABC", "\(reason): source restored")
        }
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
        link.receive(.init(.client, take: "t", bundle: "com.apple.TextEdit", uid: "u"))
        link.lost()
        #expect(!link.mark("words"))
        link.end()
        #expect(world.current == "com.apple.keylayout.ABC")
    }

    @Test func theFinishedTextIsCommittedOnceAndTheAnswerIsUsed() async {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
        link.receive(.init(.client, take: "t", bundle: "com.apple.TextEdit", uid: "u"))
        #expect(link.mark("nine pelicans"))
        Task { @MainActor in
            await Task.yield()
            link.receive(.init(.committed, take: "t", ok: true, seen: true))
        }
        let result = await link.commit("Nine pelicans rest.")
        #expect(result.ok && result.seen)
        #expect(world.sent.filter { $0.kind == .commit }.count == 1)
    }

    @Test func cancellingTakesTheMarkedWordsOutAndRestores() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
        link.receive(.init(.client, take: "t", bundle: "com.apple.TextEdit", uid: "u"))
        #expect(link.mark("the baker"))
        link.cancel()
        link.end()
        #expect(world.sent.map(\.kind).contains(.cancel))
        #expect(world.current == "com.apple.keylayout.ABC")
    }

    /// The saved source is cleared once restored, so no later restore brings back an old one.
    @Test func theSavedSourceIsClearedAfterTheRestore() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
        #expect(link.defaults.string(forKey: InputMethodLink.restoreKey) == "com.apple.keylayout.ABC")
        link.end()
        #expect(link.defaults.string(forKey: InputMethodLink.restoreKey) == nil)
    }

    /// The person changed the source (Ctrl-Space) while pFlow waited: no re-selection, the take uses the other paths.
    @Test func aSourceThePersonChangedIsRespected() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.apple.Notes"))
        world.current = "com.apple.keylayout.Dvorak"
        world.now += 0.6
        #expect(link.attachState() == .failed("source changed"))
        #expect(world.selects == [InputMethodWire.sourceID], "nothing selected over the person's choice")
    }

    /// pFlow quit mid-take last time: at launch the person's source comes back.
    @Test func aLeftoverSelectionIsRestoredAtLaunch() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
        let fresh = InputMethodLink()
        fresh.currentSource = { world.current }
        fresh.selectSource = { world.selects.append($0); world.current = $0; return true }
        fresh.defaults = link.defaults
        fresh.restoreLeftover()
        #expect(world.current == "com.apple.keylayout.ABC")
    }

    /// Not running yet: selecting the source starts it; the begin goes out once it connects.
    @Test func theBeginWaitsForTheInputMethodToConnect() {
        let world = World()
        let link = link(world)
        link.connectedForTesting = false
        #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
        #expect(world.sent.isEmpty && world.current == InputMethodWire.sourceID)
        link.connectedForTesting = true
        link.adoptForTesting()
        #expect(world.sent.first?.kind == .begin)
        link.end()
        #expect(world.current == "com.apple.keylayout.ABC")
    }

    /// No activation after the select: the person's source, a pause, then pFlow's again; the
    /// activation that brings binds the take.
    @Test func noActivationMeansOneSpacedReselection() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.apple.Notes"))
        world.now += 0.2
        #expect(link.attachState() == .pending && world.selects.count == 1)
        world.now += 0.4
        #expect(link.attachState() == .pending)
        #expect(world.selects.last == "com.apple.keylayout.ABC", "the person's source first")
        world.now += 0.1
        _ = link.attachState()
        #expect(world.selects.count == 2, "a pause before pFlow's again")
        world.now += 0.2
        _ = link.attachState()
        #expect(world.selects.last == InputMethodWire.sourceID && world.selects.count == 3)
        link.receive(.init(.client, take: "t", bundle: "com.apple.Notes"))
        #expect(link.attachState() == .attached)
        world.now += 1
        _ = link.attachState()
        #expect(world.selects.count == 3, "once")
    }

    /// pFlow just started and the input method connects late: the re-selection waits for the begin to reach it.
    @Test func theReselectionCountsFromTheBegin() {
        let world = World()
        let link = link(world)
        link.connectedForTesting = false
        #expect(link.begin(id: "t", bundle: "com.apple.Notes"))
        world.now += 0.6
        _ = link.attachState()
        #expect(world.selects.count == 1, "no re-selection before the input method has the take")
        link.connectedForTesting = true
        link.adoptForTesting()
        world.now += 0.3
        _ = link.attachState()
        #expect(world.selects.count == 1)
        world.now += 0.3
        _ = link.attachState()
        #expect(world.selects.count == 2, "then the person's source, as usual")
    }

    /// A late activation while the person's source is selected for the re-selection is not the take's.
    @Test func aLateActivationDuringTheReselectionIsIgnored() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.google.Chrome"))
        world.now += 0.6
        _ = link.attachState()
        #expect(world.current == "com.apple.keylayout.ABC")
        link.receive(.init(.client, take: "t", bundle: "com.google.Chrome"))
        #expect(link.attachState() == .pending, "not attached while pFlow's source is not selected")
        world.now += 0.3
        _ = link.attachState()
        #expect(world.current == InputMethodWire.sourceID)
        link.receive(.init(.client, take: "t", bundle: "com.google.Chrome"))
        #expect(link.attachState() == .attached)
    }

    /// Marked text goes nowhere while another source is selected: no mark is sent then.
    @Test func noMarkWhileAnotherSourceIsSelected() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
        link.receive(.init(.client, take: "t", bundle: "com.apple.TextEdit"))
        world.current = "com.apple.keylayout.ABC"
        #expect(!link.mark("the harbor"))
        #expect(link.interrupted == "notSelected")
        #expect(!world.sent.contains { $0.kind == .mark })
    }

    /// The person's source is saved before the switch, so a pFlow that dies in between can still be undone.
    @Test func thePersonsSourceIsSavedBeforeTheSwitch() {
        let world = World()
        let link = link(world)
        var savedAtSelect: String?
        link.selectSource = { id in
            savedAtSelect = link.defaults.string(forKey: InputMethodLink.restoreKey)
            world.selects.append(id); world.current = id; return true
        }
        #expect(link.begin(id: "t", bundle: "com.apple.TextEdit"))
        #expect(savedAtSelect == "com.apple.keylayout.ABC")
    }

    /// "Copy dictation to clipboard" keeps the finished text whenever it went out, read back or not.
    @Test func theKeptCopyFollowsTheSettingAfterACommit() {
        #expect(InputMethodFinish.copiesToClipboard(.applied, keepCopy: true))
        #expect(InputMethodFinish.copiesToClipboard(.unconfirmed, keepCopy: true))
        #expect(!InputMethodFinish.copiesToClipboard(.applied, keepCopy: false))
        #expect(!InputMethodFinish.copiesToClipboard(.kept(.focus), keepCopy: true))
    }

    @Test func notAddedMeansNoSwitch() {
        let world = World()
        world.enabled = false
        let link = link(world)
        #expect(!link.begin(id: "t", bundle: "com.apple.TextEdit"))
        #expect(world.selects.isEmpty)
    }

    // MARK: The wire

    @Test func messagesRoundTripAndOversizedOnesEndTheStream() {
        let message = InputMethodWire.Message(.mark, take: "t", text: "the harbor ☃", seq: 3)
        var buffer = InputMethodWire.frame(message)! + InputMethodWire.frame(.init(.end, take: "t"))!
        #expect(InputMethodWire.unframe(&buffer) == [message, .init(.end, take: "t")])
        #expect(buffer.isEmpty)
        var huge = Data([0x7F, 0xFF, 0xFF, 0xFF])
        #expect(InputMethodWire.unframe(&huge) == nil)
    }
}

/// An injector whose typed keys are held back (Command held through push-to-talk).
@MainActor
final class HeldBackInjector: TextInjecting {
    var targetApplicationName: String? = "Google Chrome"
    var targetApplicationBundleID: String? = "com.google.Chrome"
    var delivered: [String] = []
    var inputMethodFinal: LiveInlineFinal?
    func captureTarget() {}
    func deliver(_ text: String) async -> InjectionOutcome { delivered.append(text); return .pasted }
    func beginLive(session: String) -> LiveInlineStart { .typing }
    func typedLive(session: String) -> Bool { inputMethodFinal != nil }
    func finalizeLive(session: String, text: String) -> LiveInlineFinal { .notTyped }
    func liveHeldBack(session: String) -> Bool { inputMethodFinal == nil }
    func finishInputMethod(session: String, text: String) async -> LiveInlineFinal? { inputMethodFinal }
}

@MainActor
struct LiveFallbackTests {
    /// Typed keys cannot go out while Command is held: the words show in pFlow's own preview, and the finished text goes in once.
    @Test func heldKeysShowTheWordsInPFlowsPreview() async {
        let session = FakeSession()
        session.textToReturn = "seven blue kites"
        let hud = FakeHUD()
        let injector = HeldBackInjector()
        let coordinator = makeCoordinator(session: session, injector: injector, hud: hud, liveTextMode: { .typeInApp })
        await coordinator.toggle()
        session.emit("seven blue")
        #expect(hud.cards.last == true, "the preview card shows")
        #expect(hud.partials.last == "seven blue")
        await coordinator.finish()
        #expect(injector.delivered == ["seven blue kites"], "the finished text once")
    }

    @Test func anInputMethodCommitThatCannotBeReadBackIsReportedUnconfirmed() async {
        let session = FakeSession()
        let injector = HeldBackInjector()
        injector.inputMethodFinal = .unconfirmed
        let coordinator = makeCoordinator(session: session, injector: injector, liveTextMode: { .typeInApp })
        await coordinator.toggle()
        session.emit("hello")
        await coordinator.finish()
        #expect(coordinator.lastOutcome == .unconfirmed)
        #expect(injector.delivered.isEmpty, "never pasted a second time")
    }
}

/// Safari (WebKit) applied several back-to-back key events out of order: the
/// last piece of a long batch landed first (VM trace: "...meet the" then
/// "he old lighthouse. ferry at 9 and walk along the pier to t"). Typed
/// keys go out one event at a time, each shown before the next.
@MainActor
struct TypedKeyOrderTests {
    /// A field that, given several key events at once, applies the last one first.
    final class ReorderingField: KeyFieldReader {
        var value = "Note:"
        var selection = NSRange(location: 5, length: 0)
        func post(_ text: String) {
            var pieces = SyntheticKeys.chunks(text)
            if pieces.count > 1 { pieces = [pieces.removeLast()] + pieces }
            for piece in pieces {
                value = (value as NSString).replacingCharacters(in: selection, with: piece)
                selection = NSRange(location: selection.location + (piece as NSString).length, length: 0)
            }
        }
        func state() -> LiveFieldState {
            LiveFieldState(app: 1, element: LiveFieldState.target, secure: false, trusted: true, value: value, selection: selection)
        }
        func select(_ range: NSRange) -> Bool { selection = range; return true }
        func selectionSettable() -> Bool { true }
    }

    @Test func aLongBatchIsTypedInOrderOrNotAtAll() {
        let field = ReorderingField()
        let watch = PersonInput(isTrusted: { false })
        watch.overrideWatching(true)
        let keys = KeyLiveTextField(reader: field, pid: 1, facts: { _ in InsertionFacts() }, watch: watch,
                                    inputMethod: { false }, send: { field.post($0); return true })
        let words = " ferry at 9 and walk along the pier to the old lighthouse."
        #expect(keys.replace(NSRange(location: 5, length: 0), with: words))
        #expect(field.value == "Note:" + words, "in order: \(field.value)")
    }
}

/// The input method's own rules (shared code): which client a take binds to, and the orphan restore.
struct InputMethodBindingTests {
    private final class Controller {}
    private let window1 = Controller(), window2 = Controller()
    private func activation(_ c: Controller, _ bundle: String = "com.google.Chrome", at: TimeInterval) -> InputMethodBinding.Activation {
        .init(controller: ObjectIdentifier(c), bundle: bundle, at: at)
    }

    /// Chrome window 1's client was never deactivated; the take in window 2 gets no fresh activation at first.
    /// It must never write to window 1, and binds to window 2 once that one is activated for this take.
    @Test func aTakeNeverBindsToALeftoverClient() {
        var binding = InputMethodBinding()
        _ = binding.activated(activation(window1, at: 10))
        #expect(binding.begin(bundle: "com.google.Chrome", after: 20) == .none, "the leftover from an earlier take is not bound")
        #expect(!binding.mayWrite(ObjectIdentifier(window1)))
        #expect(binding.activated(activation(window2, at: 21)) == .bound)
        #expect(binding.mayWrite(ObjectIdentifier(window2)) && !binding.mayWrite(ObjectIdentifier(window1)))
    }

    /// An activation from before this take's select that reaches the input method late is still a leftover.
    @Test func aLateDeliveredOldActivationIsNotBound() {
        var binding = InputMethodBinding()
        _ = binding.begin(bundle: "com.google.Chrome", after: 20)
        #expect(binding.activated(activation(window1, at: 19.5)) == .none)
        #expect(!binding.mayWrite(ObjectIdentifier(window1)))
    }

    @Test func anActivationJustAfterTheSelectBindsAtBegin() {
        var binding = InputMethodBinding()
        _ = binding.activated(activation(window2, at: 20.1))
        #expect(binding.begin(bundle: "com.google.Chrome", after: 20) == .bound, "the input method started by this select")
        _ = binding.activated(activation(window1, "com.apple.TextEdit", at: 19))
        #expect(binding.mayWrite(ObjectIdentifier(window2)))
    }

    @Test func anotherClientAfterWordsBreaksTheTakeBeforeWordsRebinds() {
        var binding = InputMethodBinding()
        _ = binding.begin(bundle: "com.google.Chrome", after: 20)
        _ = binding.activated(activation(window1, at: 21))
        #expect(binding.activated(activation(window2, at: 22)) == .rebound, "nothing shown yet, same app, this take's select")
        binding.marked = true
        #expect(binding.activated(activation(window1, at: 23)) == .changed, "words shown: never moved to another client")
        #expect(binding.mayWrite(ObjectIdentifier(window2)))
        var other = InputMethodBinding()
        _ = other.begin(bundle: "com.google.Chrome", after: 20)
        #expect(other.activated(activation(window1, "com.apple.Notes", at: 21)) == .none, "another app never binds")
    }

    @Test func theRebindCountsOnlyLaterActivations() {
        var binding = InputMethodBinding()
        _ = binding.begin(bundle: "com.apple.Notes", after: 20)
        _ = binding.activated(activation(window1, "com.apple.Notes", at: 20.5))
        #expect(binding.rebind(after: 21) == .none, "an activation from before the re-selection no longer counts")
        #expect(!binding.mayWrite(ObjectIdentifier(window1)))
        #expect(binding.activated(activation(window2, "com.apple.Notes", at: 21.2)) == .bound)
    }

    @Test func theOrphanRestoreWaitsThreeSecondsWithNoTakeAndNoPFlow() {
        #expect(InputMethodBinding.orphanDelay == 3)
        #expect(InputMethodBinding.orphanRestoreDue(hasTake: false, connected: false, selectedIsOurs: true, sinceActivation: 3))
        #expect(!InputMethodBinding.orphanRestoreDue(hasTake: false, connected: false, selectedIsOurs: true, sinceActivation: 2.9))
        #expect(!InputMethodBinding.orphanRestoreDue(hasTake: true, connected: false, selectedIsOurs: true, sinceActivation: 5))
        #expect(!InputMethodBinding.orphanRestoreDue(hasTake: false, connected: true, selectedIsOurs: true, sinceActivation: 5))
        #expect(!InputMethodBinding.orphanRestoreDue(hasTake: false, connected: false, selectedIsOurs: false, sinceActivation: 5))
    }
}

/// pFlow's checks of the target field around the input method.
@MainActor
struct InputMethodTargetTests {
    /// Window 2 (the target) shows nothing of the marks: they went to another client.
    @Test func marksMissingFromTheTargetAreNotInTheTarget() {
        let expected: (String) -> String? = { "Dear Sam, " + $0 }
        #expect(!InputMethodFinish.showsInTarget(read: "Dear Sam,", candidates: ["the harbor", "the harbor lights"], expected: expected, placeholder: false))
        #expect(InputMethodFinish.showsInTarget(read: "Dear Sam, the harbor", candidates: ["the harbor", "the harbor lights"], expected: expected, placeholder: false))
        #expect(!InputMethodFinish.showsInTarget(read: nil, candidates: ["the harbor"], expected: expected, placeholder: false))
    }

    /// The commit counts only when the target shows it; the input method's own read-back only for an unreadable target.
    @Test func theCommitLandsOnlyWhereTheTargetShowsIt() async {
        var copied = 0
        let wrongWindow = await InputMethodFinish.conclude(committed: true, seenByInputMethod: true, targetReadable: true, keepCopy: true,
                                                          landedInTarget: { false }, copy: { copied += 1 })
        #expect(wrongWindow == .unconfirmed, "its own client showing it proves nothing about the target")
        #expect(copied == 1, "Copy dictation to clipboard keeps the text when it is unconfirmed")
        let shown = await InputMethodFinish.conclude(committed: true, seenByInputMethod: false, targetReadable: true, keepCopy: false,
                                                    landedInTarget: { true }, copy: { copied += 1 })
        #expect(shown == .applied && copied == 1)
        let unreadable = await InputMethodFinish.conclude(committed: true, seenByInputMethod: true, targetReadable: false, keepCopy: false,
                                                         landedInTarget: { false }, copy: {})
        #expect(unreadable == .applied)
        let refused = await InputMethodFinish.conclude(committed: false, seenByInputMethod: false, targetReadable: true, keepCopy: true,
                                                      landedInTarget: { true }, copy: { copied += 1 })
        #expect(refused == .kept(.focus) && copied == 1)
    }
}
