import AppKit
import Testing
@testable import Yap

/// pFlow Dictation through TextInjector, the way a take runs it: the first
/// marks looked for at the caret in the target (the 0.7 s check), and the end
/// of a take that commits through the input method only when that holds.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InputMethodInjectorTests {
    private final class World {
        var current = "com.apple.keylayout.ABC"
        var sent: [InputMethodWire.Message] = []
        var read = "Dear Sam,"
        let scratch = ScratchDefaults("pflow.im.injector")
    }

    private func setUp(_ world: World) -> (TextInjector, InputMethodLink) {
        let link = InputMethodLink()
        link.enabled = { true }
        link.currentSource = { world.current }
        link.selectSource = { world.current = $0; return true }
        link.transmit = { world.sent.append($0); return true }
        link.defaults = world.scratch.defaults
        link.connectedForTesting = true
        let injector = TextInjector()
        injector.inputMethod = link
        injector.readTarget = { _ in world.read }
        injector.markedTextCheck = { nil }
        return (injector, link)
    }

    /// A take whose client is on probation (no activation came), its first words marked and acknowledged.
    private func probationTake(_ world: World) -> (TextInjector, InputMethodLink) {
        let (injector, link) = setUp(world)
        // Chrome keeps marked words (learned on its first take this launch).
        injector.rememberMarksForTesting(.keeps, for: "com.google.Chrome")
        #expect(link.begin(id: "t", bundle: "com.google.Chrome", readable: true))
        link.receive(.init(.client, take: "t", bundle: "com.google.Chrome", provisional: true))
        injector.adoptInputMethodTakeForTesting(session: "t", field: AXUIElementCreateApplication(getpid()), value: "Dear Sam,", caret: 9)
        #expect(injector.reconcileLive(session: "t", transcript: "the harbor") == nil)
        #expect(world.sent.filter { $0.kind == .mark }.map(\.text) == [" the harbor"])
        link.receive(.init(.marked, take: "t", seq: 1, ok: true))
        return (injector, link)
    }

    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func firstMarksSeenAtTheCaretConfirmTheTake() async {
        let world = World()
        let (injector, link) = probationTake(world)
        world.read = "Dear Sam, the harbor"
        #expect(await waitFor(0.5) { link.confirmed }, "seen at the caret: confirmed well inside the 0.7 s")
        withExtendedLifetime(injector) {}
        #expect(world.sent.contains(.init(.confirm, take: "t", seq: 1)))
        #expect(!world.sent.contains { $0.kind == .cancel })
    }

    @Test func firstMarksNeverSeenAreTakenBackAfterTheCheck() async {
        let world = World()
        let (injector, link) = probationTake(world)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!world.sent.contains { $0.kind == .cancel }, "not before the 0.7 s check is over")
        #expect(await waitFor(1) { world.sent.contains { $0.kind == .cancel } }, "then taken back out")
        #expect(!link.confirmed)
        link.receive(.init(.cleared, take: "t", ok: false, reason: "committed"))
        let final = await injector.finishInputMethod(session: "t", text: "The harbor.")
        #expect(final == .kept(.otherWindow), "not proven gone: no paste, the Copy card says why")
        #expect(!world.sent.contains { $0.kind == .commit })
    }

    /// Owner 2026-11-01, T3 Code: the first marks were not seen in time, taken back, and the client could
    /// not be read to prove them gone ("unread"): the whole take ended on the card. At the end, when the
    /// target field is still the app's focused one and reads exactly as at the start (twice), the
    /// finished text goes in once by the usual checked paste. The app committing them, another field
    /// focused, or the field holding anything new: the card, as before.
    @Test func anUnreadTakeBackIsProvenByTheFieldAtTheEnd() async {
        // (take-back reason, focused field the same, field text, the person acted, the field changes after the first look)
        let cases: [(String, Bool, String, Bool?, Bool, LiveInlineFinal)] = [
            ("unread", true, "Dear Sam,", false, false, .notTyped),
            ("committed", true, "Dear Sam,", false, false, .kept(.otherWindow)),
            ("unread", false, "Dear Sam,", false, false, .kept(.otherWindow)),
            ("unread", true, "Dear Sam, Bye", false, false, .kept(.otherWindow)),
            ("unread", true, "Dear Sam,", true, false, .kept(.otherWindow)),
            ("unread", true, "Dear Sam,", nil, false, .kept(.otherWindow)),
            ("unread", true, "Dear Sam,", false, true, .kept(.otherWindow)),
        ]
        for (reason, focusedSame, read, acted, changes, expected) in cases {
            let world = World()
            let (injector, link) = freshTake(world)
            world.read = read
            var looks = 0
            injector.focusedFieldNow = {
                looks += 1
                // The second look comes after the quarter-second wait: the field changed meanwhile.
                if changes, looks == 2 { world.read = "Dear Sam, Bye" }
                return focusedSame ? AXUIElementCreateApplication(getpid()) : AXUIElementCreateApplication(1)
            }
            injector.personActedSinceCapture = { acted }
            link.receive(.init(.marked, take: "t", seq: 1, ok: true))
            #expect(await waitFor(2.5) { world.sent.contains { $0.kind == .cancel } })
            link.receive(.init(.cleared, take: "t", ok: false, reason: reason))
            let final = await injector.finishInputMethod(session: "t", text: "The harbor lights.")
            #expect(final == expected, "\(reason), focused \(focusedSame), field \(read), acted \(String(describing: acted)), changes \(changes)")
            #expect(!world.sent.contains { $0.kind == .commit })
        }
    }

    @Test func firstMarksProvenGoneLetTheTakeGoOnAnotherWay() async {
        let world = World()
        let (injector, _) = probationTake(world)
        #expect(await waitFor(1.2) { world.sent.contains { $0.kind == .cancel } })
        let id = world.sent.last { $0.kind == .cancel }?.take
        (injector.inputMethod).receive(.init(.cleared, take: id, ok: true, reason: "gone"))
        let final = await injector.finishInputMethod(session: "t", text: "The harbor.")
        #expect(final == nil, "the take left the input method: the usual paths finish it")
        #expect(!world.sent.contains { $0.kind == .commit })
    }

    // MARK: Apps that hide their text (book writer, 0.3.20)

    /// A client activated for this take in the target app, its first words marked.
    private func freshTake(_ world: World) -> (TextInjector, InputMethodLink) {
        let (injector, link) = setUp(world)
        #expect(link.begin(id: "t", bundle: "com.example.writer", readable: true))
        link.receive(.init(.client, take: "t", bundle: "com.example.writer", provisional: false))
        injector.adoptInputMethodTakeForTesting(session: "t", field: AXUIElementCreateApplication(getpid()), value: "Dear Sam,", caret: 9)
        #expect(injector.reconcileLive(session: "t", transcript: "the harbor") == nil)
        #expect(world.sent.filter { $0.kind == .mark }.map(\.text) == [" the harbor"])
        return (injector, link)
    }

    /// The app never shows the marks where pFlow can read them (or not in time). Taken back out and
    /// proven gone, the take goes on in pFlow's card, and the finished text goes in once at the end:
    /// no keys typed into a field whose text pFlow cannot check, so no half-typed words with a card.
    @Test func marksNeverSeenInAFreshClientGoOnInTheCard() async {
        let world = World()
        let (injector, link) = freshTake(world)
        link.receive(.init(.marked, take: "t", seq: 1, ok: true))
        #expect(await waitFor(1.5) { world.sent.contains { $0.kind == .cancel } })
        link.receive(.init(.cleared, take: "t", ok: true, reason: "gone"))
        #expect(await waitFor(1) { world.sent.contains { $0.kind == .end } })
        #expect(world.current == "com.apple.keylayout.ABC", "the person's source is back")
        #expect(injector.reconcileLive(session: "t", transcript: "the harbor lights") == .unsupported, "the card shows the words")
        #expect(injector.reconcileLive(session: "t", transcript: "the harbor lights glow") == nil, "said once")
        #expect(!injector.typedLive(session: "t"), "nothing typed live")
        #expect(await injector.finishInputMethod(session: "t", text: "The harbor lights glow.") == nil)
        #expect(injector.finalizeLive(session: "t", text: "The harbor lights glow.") == .notTyped, "the usual checked paste, once")
        #expect(!world.sent.contains { $0.kind == .commit })
    }

    /// Words the app committed itself and that could not come back out, shown exactly at the caret:
    /// they are selected there and the finished text goes over them (the whole text once). Not
    /// exactly there (the person's text changed): the card.
    @Test func committedWordsLeftAtTheCaretGetTheFinishedTextOverThem() async {
        for (exact, late) in [(true, false), (false, false), (false, true)] {
            let world = World()
            let (injector, link) = freshTake(world)
            let field = SimulatedTextField(exact || late ? "Dear Sam, the harbor" : "Dear Sam, the harbor!")
            // A field that answers from a late cache: the second read shows the words gone.
            if late { field.afterNextRead = { field.current.value = "Dear Sam," } }
            injector.leftWordsField = { field }
            injector.leftWordsSettle = {}
            link.receive(.init(.marked, take: "t", seq: 1, ok: true))
            #expect(await waitFor(1.5) { world.sent.contains { $0.kind == .cancel } })
            link.receive(.init(.cleared, take: "t", ok: false, reason: "committed"))
            #expect(await waitFor(1) { world.sent.contains { $0.kind == .end } })
            let final = await injector.finishInputMethod(session: "t", text: "The harbor lights.")
            if exact {
                guard case .replace(let own)? = final else { Issue.record("expected the finished text over the words: \(String(describing: final))"); continue }
                #expect(own.range == NSRange(location: 10, length: 10) && own.text == "the harbor", "the words, not the space before them")
                #expect(field.current.selection == own.range, "selected for the checked paste")
            } else {
                #expect(final == .kept(.otherWindow))
                #expect(field.current.selection != NSRange(location: 10, length: 10))
            }
        }
    }

    /// An app that types each mark in as typed text (no marked text): its first words, seen at the
    /// caret, are taken back once to check; they are still there, so nothing more is marked (no
    /// doubled words), pFlow Dictation stops, the finished text goes over those words at the end,
    /// and the app gets pFlow's card from then on (review S2).
    @Test func anAppThatTypesMarksInIsNeverMarkedTwice() async {
        let world = World()
        let (injector, link) = freshTake(world)
        link.receive(.init(.marked, take: "t", seq: 1, ok: true))
        world.read = "Dear Sam, the harbor"
        #expect(await waitFor(1) { world.sent.contains { $0.kind == .cancel } }, "the one check")
        link.receive(.init(.cleared, take: "t", ok: false, reason: "committed"))
        #expect(await waitFor(1) { world.sent.contains { $0.kind == .end } })
        #expect(!world.sent.contains { $0.kind == .confirm }, "never confirmed: nothing may commit")
        #expect(injector.reconcileLive(session: "t", transcript: "the harbor lights") == .unsupported, "the card")
        #expect(injector.reconcileLive(session: "t", transcript: "the harbor lights glow") == nil)
        #expect(world.sent.filter { $0.kind == .mark }.count == 1, "never marked again beside them")
        #expect(injector.appMarks["com.example.writer"] == .types)
        let field = SimulatedTextField("Dear Sam, the harbor")
        injector.leftWordsField = { field }
        injector.leftWordsSettle = {}
        guard case .replace(let own)? = await injector.finishInputMethod(session: "t", text: "The harbor lights glow.") else {
            Issue.record("the finished text goes over the typed words"); return
        }
        #expect(own.text == "the harbor")
    }

    /// An app with marked text: the check takes the first words back, they are gone, they come straight
    /// back and the take goes on; the next take in that app is not checked again.
    @Test func anAppThatKeepsMarksIsCheckedOnceAndTheWordsComeBack() async {
        let world = World()
        let (injector, link) = freshTake(world)
        link.receive(.init(.marked, take: "t", seq: 1, ok: true))
        world.read = "Dear Sam, the harbor"
        #expect(await waitFor(1) { world.sent.contains { $0.kind == .cancel } })
        world.read = "Dear Sam,"
        link.receive(.init(.cleared, take: "t", ok: true, reason: "gone"))
        #expect(await waitFor(1) { link.confirmed }, "confirmed after the check")
        #expect(world.sent.filter { $0.kind == .mark }.map(\.text) == [" the harbor", " the harbor"], "the words come straight back")
        #expect(injector.appMarks["com.example.writer"] == .keeps)
        #expect(!world.sent.contains { $0.kind == .end })

        // The next take in the same app: no check.
        world.sent.removeAll()
        world.read = "Dear Sam,"
        #expect(link.begin(id: "t2", bundle: "com.example.writer", readable: true))
        link.receive(.init(.client, take: "t2", bundle: "com.example.writer", provisional: false))
        injector.adoptInputMethodTakeForTesting(session: "t2", field: AXUIElementCreateApplication(getpid()), value: "Dear Sam,", caret: 9)
        #expect(injector.reconcileLive(session: "t2", transcript: "the kites") == nil)
        let seq = link.take?.seq ?? 0
        link.receive(.init(.marked, take: "t2", seq: seq, ok: true))
        world.read = "Dear Sam, the kites"
        #expect(await waitFor(1) { link.confirmed })
        #expect(!world.sent.contains { $0.kind == .cancel }, "checked once per app")
    }

    /// Recognition failed mid-take: the words shown stay as they are and the person's source comes
    /// back at once, not at the next take (F5: pFlow's source was seen selected between takes).
    @Test func aTakeWithNoFinishedTextLetsTheInputMethodGo() {
        let world = World()
        let (injector, link) = freshTake(world)
        link.receive(.init(.marked, take: "t", seq: 1, ok: true))
        #expect(world.current == InputMethodWire.sourceID)
        injector.endLive(session: "t")
        #expect(world.sent.contains { $0.kind == .keep }, "the words shown stay as they are")
        #expect(world.sent.contains { $0.kind == .end })
        #expect(world.current == "com.apple.keylayout.ABC", "the person's source is back")
        #expect(link.take == nil)
        #expect(world.scratch.defaults.string(forKey: InputMethodLink.restoreKey) == nil)
    }

    /// A slow app shows the finished text late (its text read back 1.5 s behind, the book writer's
    /// shape): the paste counts as landed, never a card saying the app did not take it.
    @Test func aPasteThatShowsLateCountsAsLanded() async {
        let before = "Dear Sam,", after = "Dear Sam, The harbor."
        var reads = 0
        func run(landsAfter: Int, owned: Bool = true) async -> TextInjector.PasteSeen {
            reads = 0
            return await TextInjector.pasteSeen(reads: 20, late: TextInjector.lateReads,
                                                read: { reads += 1; return reads > landsAfter ? after : before },
                                                landed: { $0 == after }, asBefore: { $0 == before }, owned: { owned }, wait: {})
        }
        #expect(await run(landsAfter: 5) == .landed)
        #expect(await run(landsAfter: 45) == .landedLate, "shown 2.2 s after the paste")
        #expect(await run(landsAfter: 1000) == .notTaken, "never shown: not taken, after 1.5 s more")
        #expect(reads == 20 + 1 + TextInjector.lateReads)
        #expect(await run(landsAfter: 1000, owned: false) == .unconfirmed, "the clipboard changed meanwhile")
    }

    /// Confirmed, but at the end the target no longer shows the words: no commit through the input method.
    @Test func theEndCommitsOnlyWhileTheMarksStillShowAtTheCaret() async {
        let world = World()
        let (injector, link) = probationTake(world)
        world.read = "Dear Sam, the harbor"
        #expect(await waitFor(0.5) { link.confirmed })
        world.read = "Dear Sam,"
        let answer = Task { @MainActor in
            _ = await self.waitFor(2) { world.sent.contains { $0.kind == .cancel } }
            link.receive(.init(.cleared, take: "t", ok: true, reason: "gone"))
        }
        let final = await injector.finishInputMethod(session: "t", text: "The harbor.")
        await answer.value
        #expect(!world.sent.contains { $0.kind == .commit }, "never committed over words that are not there")
        #expect(world.sent.contains { $0.kind == .cancel })
        #expect(final == .notTyped, "proven gone: the usual checked paste")
    }

    @Test func theEndCommitsWhenTheMarksShowAtTheCaret() async {
        let world = World()
        let (injector, link) = probationTake(world)
        world.read = "Dear Sam, the harbor"
        #expect(await waitFor(0.5) { link.confirmed })
        let answer = Task { @MainActor in
            _ = await self.waitFor(2) { world.sent.contains { $0.kind == .commit } }
            world.read = "Dear Sam, The harbor."
            link.receive(.init(.committed, take: "t", ok: true, seen: true))
        }
        let final = await injector.finishInputMethod(session: "t", text: "The harbor.")
        await answer.value
        #expect(world.sent.filter { $0.kind == .commit }.map(\.text) == [" The harbor."])
        #expect(final == .applied)
    }

    // MARK: No activation: trying harder before the other paths

    /// A take in an app that sends no activation (no probation: the target cannot be read), its
    /// attach state asked through TextInjector every 0.1 s on pFlow's clock, as the coordinator does.
    private final class Bounces {
        let world = World()
        var now: TimeInterval = 50
        var selects: [String] = []
        let injector: TextInjector
        let link: InputMethodLink
        let begun: TimeInterval

        @MainActor init(_ test: InputMethodInjectorTests) {
            (injector, link) = test.setUp(world)
            begun = now
            link.clock = { [unowned self] in now }
            link.selectSource = { [unowned self] in selects.append($0); world.current = $0; return true }
            _ = link.begin(id: "t", bundle: "com.t3tools.t3code")
            injector.adoptInputMethodTakeForTesting(session: "t", field: AXUIElementCreateApplication(getpid()), value: "", caret: 0)
        }

        /// Asks once more, 0.1 s later.
        @MainActor func tick() -> LiveInlineStart {
            now += 0.1
            return injector.retryLive(session: "t")
        }

        var pflowSelects: Int { selects.filter { $0 == InputMethodWire.sourceID }.count }
        var rebinds: [InputMethodWire.Message] { world.sent.filter { $0.kind == .rebind } }
    }

    /// Three bounces (the person's source, then pFlow's again), all inside the same wait as before:
    /// the other paths take over no later than they did with one.
    @Test func noActivationGetsThreeBouncesWithinTheSameWait() {
        let take = Bounces(self)
        var result = LiveInlineStart.waiting
        while result == .waiting, take.now - take.begun < 5 { result = take.tick() }
        let pflow = InputMethodWire.sourceID, person = "com.apple.keylayout.ABC"
        #expect(take.selects == [pflow, person, pflow, person, pflow, person, pflow, person],
                "three bounces, then the person's source back for the other paths")
        #expect(result != .waiting && result != .typing)
        // The wait the person had before this change: 1.8 s, asked every 0.1 s.
        #expect(take.now - take.begun <= 1.9 + 1e-9, "no later than the 1.8 s wait")
        #expect(take.rebinds.count == 3, "each re-selection binds only activations after it")
        let times = take.rebinds.compactMap(\.at)
        #expect(times.count == 3 && times == times.sorted() && Set(times).count == 3)
    }

    /// An activation while the person's source is selected is a late one and never binds; the one
    /// after pFlow's source is selected again (here the second bounce) does, and live words start.
    @Test func anActivationAfterALaterBounceIsUsed() {
        let take = Bounces(self)
        while take.selects.count < 4, take.now - take.begun < 5 { #expect(take.tick() == .waiting) }
        #expect(take.world.current == "com.apple.keylayout.ABC", "second bounce: the person's source is selected")
        take.link.receive(.init(.client, take: "t", bundle: "com.t3tools.t3code", uid: "late"))
        #expect(take.tick() == .waiting, "not bound while the person's source is selected")
        while take.pflowSelects < 3, take.now - take.begun < 5 { #expect(take.tick() == .waiting) }
        take.link.receive(.init(.client, take: "t", bundle: "com.t3tools.t3code", uid: "fresh"))
        #expect(take.tick() == .typing)
        #expect(take.now - take.begun < 1.8, "in the field before the old fallback time")
    }

    /// The person changes the source between two bounces: no more bounces, the other paths.
    @Test func aSourceThePersonChangesBetweenBouncesIsRespected() {
        let take = Bounces(self)
        while take.pflowSelects < 2, take.now - take.begun < 5 { #expect(take.tick() == .waiting) }
        let before = take.selects
        take.world.current = "com.apple.keylayout.Dvorak"
        var result = LiveInlineStart.waiting
        while result == .waiting, take.now - take.begun < 5 { result = take.tick() }
        #expect(take.selects == before, "nothing selected over the person's choice")
        #expect(take.world.current == "com.apple.keylayout.Dvorak")
        #expect(take.now - take.begun < 1.5, "the next bounce sees the change and stops the wait early")
    }
}

