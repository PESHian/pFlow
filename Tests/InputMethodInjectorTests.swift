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
}
