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

