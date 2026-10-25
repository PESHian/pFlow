import AppKit
import Testing
@testable import Yap

/// Quick re-takes: macOS can leave the last take's client active and send no
/// activation. That client goes on probation: its first marks must show at the
/// caret in the target field before it may commit; if they do not, they come
/// back out of that same client with an empty mark, confirmed gone.
@MainActor
struct InputMethodProbeTests {
    /// A text client that records what the input method did to it, with its own text and caret.
    final class FakeClient: MarkedTextClient {
        let bundle: String?
        var caretRect: CGRect?
        var marks: [String] = []
        var inserts: [String] = []
        /// A client that refuses to let go of its marked text keeps it.
        var refusesToClear = false
        /// A client whose text cannot be read.
        var unreadable = false
        private(set) var text: String
        private var caret: Int
        private var shown = ""
        init(_ bundle: String, caret rect: CGRect? = nil, text: String = "Dear Sam,") {
            self.bundle = bundle; caretRect = rect; self.text = text; caret = (text as NSString).length
        }
        func setMarked(_ words: String) { marks.append(words); if !(refusesToClear && words.isEmpty) { shown = words } }
        func insert(_ words: String) {
            inserts.append(words)
            text = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: words)
            caret += (words as NSString).length
            shown = ""
        }
        /// The app commits its composition by itself (a blur, a click), telling no input method.
        func appCommitsComposition() {
            let words = shown
            shown = ""
            text = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: words)
            caret += (words as NSString).length
        }
        var markedLength: Int { (shown as NSString).length }
        var caretLocation: Int? { caret }
        private var document: String { (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: shown) }
        /// Like an app's text client: a range past the end reads as what there is.
        func text(in range: NSRange) -> String? {
            let all = document as NSString
            guard !unreadable, range.location <= all.length else { return unreadable ? nil : "" }
            return all.substring(with: NSRange(location: range.location, length: min(range.length, all.length - range.location)))
        }
    }

    private func id(_ object: AnyObject) -> ObjectIdentifier { ObjectIdentifier(object) }

    // MARK: The input method's side (shared core)

    @Test func aClientOnProbationMarksButNeverCommitsUntilConfirmed() {
        let core = InputMethodTakeCore()
        let leftover = FakeClient("com.google.Chrome")
        _ = core.begin(bundle: "com.google.Chrome", after: 20)
        #expect(core.probe(id(leftover), client: leftover, window: nil))
        #expect(core.mark("the harbor", controller: id(leftover), client: leftover))
        #expect(!core.commit("The harbor.", controller: id(leftover), client: leftover), "not before pFlow saw the words in the target")
        #expect(leftover.inserts.isEmpty)
        core.confirm()
        #expect(core.commit("The harbor.", controller: id(leftover), client: leftover))
        #expect(leftover.inserts == ["The harbor."])
    }

    @Test func aFreshClientAlsoCommitsOnlyOnceConfirmed() {
        let core = InputMethodTakeCore()
        let fresh = FakeClient("com.apple.TextEdit")
        _ = core.begin(bundle: "com.apple.TextEdit", after: 20)
        #expect(core.activated(.init(controller: id(fresh), bundle: "com.apple.TextEdit", at: 21)) == .bound)
        #expect(core.mark("seven", controller: id(fresh), client: fresh))
        #expect(!core.commit("Seven.", controller: id(fresh), client: fresh))
        core.confirm()
        #expect(core.commit("Seven.", controller: id(fresh), client: fresh))
    }

    @Test func takingBackIsAnEmptyMarkInTheClientThatShowsTheWords() {
        let core = InputMethodTakeCore()
        let otherWindow = FakeClient("com.google.Chrome")
        let target = FakeClient("com.google.Chrome")
        _ = core.begin(bundle: "com.google.Chrome", after: 20)
        #expect(core.probe(id(otherWindow), client: otherWindow, window: nil))
        #expect(core.mark("the harbor", controller: id(otherWindow), client: otherWindow))
        #expect(core.clear() == .gone, "reported gone")
        #expect(otherWindow.marks == ["the harbor", ""], "an empty mark, in the very client that showed them")
        #expect(otherWindow.inserts.isEmpty, "never inserted, not even an empty text")
        #expect(target.marks.isEmpty && target.inserts.isEmpty)
    }

    @Test func aClientThatStillReportsMarkedTextIsNotTakenBack() {
        let core = InputMethodTakeCore()
        let stubborn = FakeClient("com.google.Chrome")
        stubborn.refusesToClear = true
        _ = core.begin(bundle: "com.google.Chrome", after: 20)
        _ = core.probe(id(stubborn), client: stubborn, window: nil)
        _ = core.mark("the harbor", controller: id(stubborn), client: stubborn)
        #expect(core.clear() == .stillMarked, "still marked: not reported gone")
    }

    /// The other window's app committed the words itself (Chrome on a blur): nothing marked, yet
    /// the words are there. That is no take-back, and pFlow must not paste.
    @Test func wordsTheAppCommittedItselfAreNotTakenBack() {
        let core = InputMethodTakeCore()
        let otherWindow = FakeClient("com.google.Chrome")
        _ = core.begin(bundle: "com.google.Chrome", after: 20)
        _ = core.probe(id(otherWindow), client: otherWindow, window: nil)
        _ = core.mark(" the harbor", controller: id(otherWindow), client: otherWindow)
        otherWindow.appCommitsComposition()
        #expect(otherWindow.markedLength == 0)
        #expect(core.clear() == .committed, "the words are in that window's text")
        #expect(core.clear() == .committed, "asked again, the same answer")
    }

    /// Long words: only their end is read back (an app keeps little text around the caret).
    @Test func longWordsTheAppCommittedAreFoundByTheirEnd() {
        let core = InputMethodTakeCore()
        let client = FakeClient("com.google.Chrome")
        let words = " the harbor lights glow softly tonight while seven blue kites drift over the sandy dunes and the children follow"
        _ = core.begin(bundle: "com.google.Chrome", after: 20)
        _ = core.probe(id(client), client: client, window: nil)
        _ = core.mark(words, controller: id(client), client: client)
        client.appCommitsComposition()
        #expect(core.clear() == .committed)
        let clean = FakeClient("com.google.Chrome", text: "Dear Sam, see you soon at the harbor gate before the ferry leaves this evening, bring the maps and the kites")
        let core2 = InputMethodTakeCore()
        _ = core2.begin(bundle: "com.google.Chrome", after: 20)
        _ = core2.probe(id(clean), client: clean, window: nil)
        _ = core2.mark(words, controller: id(clean), client: clean)
        #expect(core2.clear() == .gone, "taken back out: the field's own text is not the words")
    }

    @Test func aClientWhoseTextCannotBeReadGivesNoProof() {
        let core = InputMethodTakeCore()
        let unreadable = FakeClient("com.google.Chrome")
        unreadable.unreadable = true
        _ = core.begin(bundle: "com.google.Chrome", after: 20)
        _ = core.probe(id(unreadable), client: unreadable, window: nil)
        _ = core.mark(" the harbor", controller: id(unreadable), client: unreadable)
        #expect(core.clear() == .unread)
    }

    @Test func theSameWordsAlreadyInTheWindowDoNotCountAsCommitted() {
        let core = InputMethodTakeCore()
        let client = FakeClient("com.apple.TextEdit", text: "Dear Sam, the harbor")
        _ = core.begin(bundle: "com.apple.TextEdit", after: 20)
        _ = core.probe(id(client), client: client, window: nil)
        _ = core.mark(" the harbor", controller: id(client), client: client)
        #expect(core.clear() == .gone)
    }

    @Test func unconfirmedWordsAreTakenOutWhenTheTakeEndsNotKept() {
        let core = InputMethodTakeCore()
        let leftover = FakeClient("com.apple.Notes")
        _ = core.begin(bundle: "com.apple.Notes", after: 20)
        _ = core.probe(id(leftover), client: leftover, window: nil)
        _ = core.mark("blue kites", controller: id(leftover), client: leftover)
        core.keepAsIs()
        #expect(leftover.inserts.isEmpty, "an unconfirmed client never gets the words for good")
        #expect(leftover.marks.last == "")
        let confirmed = FakeClient("com.apple.Notes")
        _ = core.begin(bundle: "com.apple.Notes", after: 30)
        _ = core.activated(.init(controller: id(confirmed), bundle: "com.apple.Notes", at: 31))
        _ = core.mark("blue kites", controller: id(confirmed), client: confirmed)
        core.confirm()
        core.keepAsIs()
        #expect(confirmed.inserts == ["blue kites"], "confirmed: the words stay exactly as they are")
    }

    @Test func probationIsRefusedForAnotherAppAWindowElsewhereOrAFreshClient() {
        let core = InputMethodTakeCore()
        _ = core.begin(bundle: "com.google.Chrome", after: 20)
        let notes = FakeClient("com.apple.Notes")
        #expect(!core.probe(id(notes), client: notes, window: nil), "another app")
        let elsewhere = FakeClient("com.google.Chrome", caret: CGRect(x: 1500, y: 100, width: 2, height: 18))
        #expect(!core.probe(id(elsewhere), client: elsewhere, window: CGRect(x: 0, y: 0, width: 800, height: 600)),
                "its caret is outside the target window")
        let fresh = FakeClient("com.google.Chrome")
        _ = core.activated(.init(controller: id(fresh), bundle: "com.google.Chrome", at: 21))
        let leftover = FakeClient("com.google.Chrome")
        #expect(!core.probe(id(leftover), client: leftover, window: nil), "a client activated for this take is there")
    }

    @Test func aFreshActivationReplacesProbationOnlyBeforeAnyWords() {
        let core = InputMethodTakeCore()
        let leftover = FakeClient("com.google.Chrome"), fresh = FakeClient("com.google.Chrome")
        _ = core.begin(bundle: "com.google.Chrome", after: 20)
        _ = core.probe(id(leftover), client: leftover, window: nil)
        #expect(core.activated(.init(controller: id(fresh), bundle: "com.google.Chrome", at: 21)) == .bound)
        #expect(!core.mayMark(id(leftover)) && core.mayMark(id(fresh)))
        let core2 = InputMethodTakeCore()
        _ = core2.begin(bundle: "com.google.Chrome", after: 20)
        _ = core2.probe(id(leftover), client: leftover, window: nil)
        _ = core2.mark("the", controller: id(leftover), client: leftover)
        #expect(core2.activated(.init(controller: id(fresh), bundle: "com.google.Chrome", at: 21)) == .changed,
                "words shown: never moved to another client")
    }

    // MARK: pFlow's side

    private final class World {
        var current = "com.apple.keylayout.ABC"
        var sent: [InputMethodWire.Message] = []
        var now: TimeInterval = 100
    }

    private func link(_ world: World) -> InputMethodLink {
        let link = InputMethodLink()
        link.enabled = { true }
        link.currentSource = { world.current }
        link.selectSource = { world.current = $0; return true }
        link.clock = { world.now }
        link.transmit = { world.sent.append($0); return true }
        link.defaults = UserDefaults(suiteName: "pflow.im.probe.\(UUID().uuidString)")!
        link.connectedForTesting = true
        return link
    }

    @Test func noActivationOnAReadableTargetPutsTheClientOnProbation() async {
        let world = World()
        let link = link(world)
        let window = CGRect(x: 10, y: 20, width: 800, height: 600)
        #expect(link.begin(id: "t", bundle: "com.google.Chrome", readable: true, window: window))
        world.now += InputMethodLink.probeAfter + 0.01
        _ = link.attachState()
        #expect(world.sent.last == .init(.probe, take: "t", frame: [10, 20, 800, 600]))
        link.receive(.init(.client, take: "t", bundle: "com.google.Chrome", provisional: true))
        #expect(link.attachState() == .attached && link.provisional && !link.confirmed)
        #expect(link.mark("the harbor"))
        let early = await link.commit("The harbor.")
        #expect(!early.ok && !world.sent.contains { $0.kind == .commit }, "never committed before the words were seen")
        link.confirm(seq: 1)
        #expect(world.sent.last == .init(.confirm, take: "t", seq: 1))
        Task { @MainActor in
            await Task.yield()
            link.receive(.init(.committed, take: "t", ok: true, seen: true))
        }
        let late = await link.commit("The harbor.")
        #expect(late.ok)
    }

    @Test func anUnreadableTargetNeverGoesOnProbation() {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.microsoft.VSCode", readable: false))
        world.now += 0.3
        _ = link.attachState()
        #expect(!world.sent.contains { $0.kind == .probe })
        link.receive(.init(.client, take: "t", bundle: "com.microsoft.VSCode"))
        #expect(link.confirmed, "a client activated for this take is the only check there is")
    }

    @Test func takingBackWaitsForTheInputMethodToReportTheWordsGone() async {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.google.Chrome", readable: true))
        link.receive(.init(.client, take: "t", bundle: "com.google.Chrome", provisional: true))
        #expect(link.mark("the harbor"))
        Task { @MainActor in
            await Task.yield()
            link.receive(.init(.cleared, take: "t", ok: false))
        }
        #expect(await link.clear() == false, "refused: the words may still show")
        #expect(world.sent.last?.kind == .cancel)
        let world2 = World()
        let link2 = self.link(world2)
        #expect(link2.begin(id: "u", bundle: "com.google.Chrome", readable: true))
        link2.receive(.init(.client, take: "u", bundle: "com.google.Chrome", provisional: true))
        #expect(link2.mark("the harbor"))
        Task { @MainActor in
            await Task.yield()
            link2.receive(.init(.cleared, take: "u", ok: true))
        }
        #expect(await link2.clear())
    }

    @Test func noAnswerToTheTakeBackCountsAsNotGone() async {
        let world = World()
        let link = link(world)
        #expect(link.begin(id: "t", bundle: "com.google.Chrome", readable: true))
        link.receive(.init(.client, take: "t", bundle: "com.google.Chrome", provisional: true))
        #expect(link.mark("the harbor"))
        #expect(await link.clear() == false)
    }

    // MARK: The end of a take

    /// (b) The take ends before its marks were seen in the target: no commit through the input method.
    @Test func anUnconfirmedTakeNeverCommitsThroughTheInputMethod() {
        #expect(InputMethodFinish.takesBackFirst(targetReadable: true, confirmed: false, marksAtCaret: true),
                "even if the words happen to read right at the very end")
        #expect(InputMethodFinish.takesBackFirst(targetReadable: true, confirmed: true, marksAtCaret: false))
        #expect(!InputMethodFinish.takesBackFirst(targetReadable: true, confirmed: true, marksAtCaret: true))
        #expect(!InputMethodFinish.takesBackFirst(targetReadable: false, confirmed: true, marksAtCaret: false))
    }

    /// (a) Marks not proven gone: no paste beside them; the Copy card says why.
    @Test func noPasteUnlessTheTakeBackIsProven() {
        #expect(InputMethodFinish.afterTakeBack(cleared: true) == .notTyped)
        #expect(InputMethodFinish.afterTakeBack(cleared: false) == .kept(.otherWindow))
        #expect(LiveInlineOwnership.Stop.otherWindow.cardReason == "Your words may have gone to another window.")
    }
}
