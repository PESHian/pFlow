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
    /// A key the person still holds: selecting pFlow's words is refused, as the real guard does.
    var keysHeld = false
    func select(_ range: NSRange) -> Bool {
        guard !keysHeld else { return false }
        selects.append(range)
        current.selection = range
        return true
    }
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
        #expect(InputComposition.composing(markedLength: 6, tracked: false), "AppKit says marked text: composing")
        #expect(!InputComposition.composing(markedLength: 0, tracked: true), "AppKit says nothing marked: committed")
        #expect(InputComposition.composing(markedLength: nil, tracked: true))
        #expect(!InputComposition.composing(markedLength: nil, tracked: false))
    }

    @Test func inputMethodFamiliesComeFromTheSourceID() {
        #expect(InputMethodFamily.of(sourceID: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese") == .japanese)
        #expect(InputMethodFamily.of(sourceID: "com.apple.inputmethod.SCIM.ITABC") == .chinese)
        #expect(InputMethodFamily.of(sourceID: "com.apple.inputmethod.TCIM.Zhuyin") == .chinese)
        #expect(InputMethodFamily.of(sourceID: "com.apple.inputmethod.Korean.2SetKorean") == .korean)
        #expect(InputMethodFamily.of(sourceID: "com.example.inputmethod.Unknown") == .other)
    }

    private static let s: UInt64 = 1_000_000_000
    private static let K = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", P = "com.apple.inputmethod.SCIM.ITABC"
    private static let KO = "com.apple.inputmethod.Korean.2SetKorean", U = "com.example.inputmethod.Unknown"
    private static let kyouha: [Int64] = [40, 16, 31, 32, 4, 0]   // k y o u h a
    private static let space: Int64 = 49, returnKey: Int64 = 36, escape: Int64 = 53, backspace: Int64 = 51

    private func typed(_ keys: [Int64], from start: UInt64 = 0) -> CompositionTracker {
        var tracker = CompositionTracker()
        for (n, key) in keys.enumerated() { tracker.key(key, shortcut: false, at: start + UInt64(n) * 1_000_000) }
        return tracker
    }

    @Test func kotoeriSpaceConvertsAndDigitsAndPunctuationKeepComposing() {
        var tracker = typed(Self.kyouha + [Self.space])
        #expect(tracker.snapshot(at: 2 * Self.s, sourceID: Self.K), "kyouha + Space is a conversion, not a commit")
        tracker.key(18, shortcut: false, at: 2 * Self.s)   // 1
        tracker.key(47, shortcut: false, at: 2 * Self.s)   // .
        #expect(tracker.snapshot(at: 3 * Self.s, sourceID: Self.K))
        tracker.key(Self.returnKey, shortcut: false, at: 4 * Self.s)
        #expect(!tracker.snapshot(at: 5 * Self.s, sourceID: Self.K), "Return commits")
        var cancelled = typed(Self.kyouha)
        cancelled.key(Self.escape, shortcut: false, at: Self.s)
        #expect(!cancelled.snapshot(at: 2 * Self.s, sourceID: Self.K), "Escape cancels")
    }

    @Test func chineseCommitsOnSpaceDigitsPunctuationReturnEscape() {
        for commit: Int64 in [Self.space, 18, 25, Self.returnKey, Self.escape] {
            var tracker = typed([45, 34, 4, 0, 31])   // n i h a o
            #expect(tracker.snapshot(at: Self.s, sourceID: Self.P))
            tracker.key(commit, shortcut: false, at: Self.s)
            #expect(!tracker.snapshot(at: 2 * Self.s, sourceID: Self.P), "key \(commit)")
        }
    }

    @Test func koreanEndsASyllableOnSpacePunctuationArrowsReturnEscape() {
        for commit: Int64 in [Self.space, 43, 123, 124, 125, 126, Self.returnKey, Self.escape] {
            var tracker = typed([4, 0])
            tracker.key(commit, shortcut: false, at: Self.s)
            #expect(!tracker.snapshot(at: 2 * Self.s, sourceID: Self.KO), "key \(commit)")
        }
    }

    @Test func vietnameseAndHindiEndAWordOnSpaceOnly() {
        for id in ["com.apple.inputmethod.VietnameseIM.VietnameseTelex", "com.apple.inputmethod.VietnameseIM.VietnameseVNI",
                   "com.example.inputmethod.VietnameseVIQR", "com.apple.inputmethod.TransliterationIM.Hindi"] {
            #expect(InputMethodFamily.of(sourceID: id) == .phonetic, "\(id)")
            for commit: Int64 in [Self.space, Self.returnKey, Self.escape] {
                var tracker = typed([4, 0])
                tracker.key(commit, shortcut: false, at: Self.s)
                #expect(!tracker.snapshot(at: 2 * Self.s, sourceID: id), "\(id) key \(commit)")
            }
        }
        #expect(InputMethodFamily.of(sourceID: "im.rime.inputmethod.Squirrel.Hans") == .chinese)
        #expect(InputMethodFamily.of(sourceID: "com.apple.inputmethod.TYIM.Cantonese") == .chinese)
    }

    /// Punctuation that is part of a word in these input methods never counts as its end.
    @Test func toneMarksAndPagingKeysKeepTheWordOpen() {
        let cases: [(String, [Int64], String)] = [
            ("com.example.inputmethod.VietnameseVIQR", [8, 31, 39], "VIQR c o ' (a tone mark)"),
            ("com.apple.inputmethod.VietnameseIM.VietnameseTelex", [45, 4, 32, 33], "Telex n h u [ (ư)"),
            ("im.rime.inputmethod.Squirrel.Hans", [45, 34, 4, 0, 31, 24], "Rime nihao = (next page)"),
            (Self.P, [45, 34, 4, 0, 31, 24], "Pinyin nihao = (next page)"),
            (Self.P, [45, 34, 4, 0, 31, 27], "Pinyin nihao - (previous page)"),
        ]
        for (id, keys, label) in cases {
            let tracker = typed(keys)
            let start = tracker.snapshot(at: Self.s, sourceID: id)
            #expect(start, "\(label): still being typed")
            #expect(tracker.composing(snapshot: start, takeStart: Self.s, sourceID: id), "\(label): the take is refused")
        }
    }

    @Test func anUnknownInputMethodCommitsOnlyOnReturnOrEscape() {
        for keep: Int64 in [Self.space, 18, 43, 123] {
            var tracker = typed([4, 0])
            tracker.key(keep, shortcut: false, at: Self.s)
            #expect(tracker.snapshot(at: 2 * Self.s, sourceID: Self.U), "key \(keep) keeps it open")
        }
        var tracker = typed([4, 0])
        tracker.key(Self.returnKey, shortcut: false, at: Self.s)
        #expect(!tracker.snapshot(at: 2 * Self.s, sourceID: Self.U))
    }

    @Test func editingKeysNeverStartACompositionOnlyContinueOne() {
        for key: Int64 in [Self.backspace, 117, 123, 124, 125, 126, 115, 119, 116, 121] {
            var committed = typed([45, 34, Self.space])
            committed.key(key, shortcut: false, at: Self.s)
            #expect(!committed.snapshot(at: 2 * Self.s, sourceID: Self.P), "key \(key) after a commit")
        }
        var open = typed(Self.kyouha)
        open.key(Self.backspace, shortcut: false, at: 70 * Self.s)
        #expect(open.snapshot(at: 71 * Self.s, sourceID: Self.K), "Backspace inside a composition continues it")
    }

    @Test func shortcutsAndThePflowHotkeyAreNeverPartOfAComposition() {
        let watch = PersonInput(isTrusted: { false })
        watch.record(keyCode: 8, flags: .maskCommand, at: 0)            // ⌘C
        watch.record(keyCode: 2, flags: [.maskCommand, .maskShift], at: 0)   // ⌘⇧D
        watch.record(keyCode: 8, flags: .maskControl, at: 0)
        #expect(!watch.trackerForTesting.snapshot(at: Self.s, sourceID: Self.P))
        watch.record(keyCode: 8, flags: .maskShift, at: 0)               // Shift+C composes
        #expect(watch.trackerForTesting.snapshot(at: Self.s, sourceID: Self.P))
    }

    @Test func thePlainLayoutSelectedNowMeansNoComposition() {
        let tracker = typed(Self.kyouha)
        #expect(!tracker.snapshot(at: Self.s, sourceID: nil))
        #expect(!tracker.composing(snapshot: true, takeStart: Self.s, sourceID: nil),
                "Kotoeri to ABC: an English take is never refused on old keys")
    }

    @Test func keysTypedBeforeTheSwitchWasSeenAreReadWithTheInputMethodSelectedNow() {
        // The switch to Kotoeri was never seen (a held notification): "nihon" was recorded with no
        // family. Read at the take with Kotoeri selected, it is an open composition.
        let watch = PersonInput(isTrusted: { false })
        for key: Int64 in [45, 34, 4, 31, 45] { watch.record(keyCode: key, at: 0) }
        let start = watch.trackerForTesting.snapshot(at: Self.s, sourceID: Self.K)
        #expect(start)
        #expect(watch.trackerForTesting.composing(snapshot: start, takeStart: Self.s, sourceID: Self.K))
    }

    @Test func aCandidateWindowClickKeepsComposingAnyOtherClickCommits() {
        var tracker = typed(Self.kyouha + [Self.space, Self.space])
        tracker.click(commits: false, at: Self.s)
        #expect(tracker.snapshot(at: 2 * Self.s, sourceID: Self.K), "a candidate pick is not a commit")
        tracker.click(commits: true, at: 3 * Self.s)
        #expect(!tracker.snapshot(at: 4 * Self.s, sourceID: Self.K), "a click elsewhere commits (browsers commit on blur)")
    }

    @Test func theTakeKeepsItsStartStateWithNoTimeLimitUntilARealCommit() {
        var tracker = typed(Self.kyouha)
        let start = 2 * Self.s
        let snapshot = tracker.snapshot(at: start, sourceID: Self.K)
        #expect(snapshot)
        #expect(tracker.composing(snapshot: snapshot, takeStart: start, sourceID: Self.K), "a 6 s, or a 6 min, take: still composing")
        tracker.key(Self.space, shortcut: false, at: start + 6 * Self.s)
        #expect(tracker.composing(snapshot: snapshot, takeStart: start, sourceID: Self.K), "Space converts in Kotoeri")
        tracker.key(Self.returnKey, shortcut: false, at: start + 7 * Self.s)
        #expect(!tracker.composing(snapshot: snapshot, takeStart: start, sourceID: Self.K), "Return seen during the take: committed")
        tracker.key(4, shortcut: false, at: start + 8 * Self.s)
        #expect(tracker.composing(snapshot: snapshot, takeStart: start, sourceID: Self.K), "a new composition during the take")
        var clean = CompositionTracker()
        #expect(!clean.composing(snapshot: clean.snapshot(at: start, sourceID: Self.K), takeStart: start, sourceID: Self.K))
        clean.key(4, shortcut: false, at: start - 1)
        #expect(!clean.composing(snapshot: false, takeStart: start, sourceID: Self.K),
                "keys from before the take count only through the snapshot")
    }

    @Test func beforeATakeACompositionLeftAloneForAMinuteNoLongerCounts() {
        let tracker = typed(Self.kyouha)
        #expect(tracker.snapshot(at: 59 * Self.s, sourceID: Self.K))
        #expect(!tracker.snapshot(at: 61 * Self.s, sourceID: Self.K))
        #expect(CompositionTracker.preTakeExpiry == 60 * Self.s)
    }

    @Test func englishTypingLeavesNothingStoredAndAClickLooksNothingUp() {
        let watch = PersonInput(isTrusted: { false })
        let now = PersonInput.now()
        for (n, key) in [4, 14, 37, 37, 31].enumerated() {   // h e l l o, ABC selected
            watch.record(keyCode: Int64(key), at: now + UInt64(n))
            watch.stampSource(at: now + UInt64(n), source: "")
        }
        #expect(watch.trackerForTesting.keys.isEmpty)
        #expect(watch.clickCommits(at: CGPoint(x: 10, y: 10)))
        #expect(watch.windowLookups == 0, "no window list is read for a click after English typing")
        watch.record(keyCode: 4, at: now + 10)                 // a key not read yet
        _ = watch.clickCommits(at: CGPoint(x: 10, y: 10))
        #expect(watch.windowLookups == 1)
    }

    @Test func keysTypedUnderAnotherSourceBelongToBeforeTheSwitch() {
        // English "hello" under ABC, then Kotoeri selected: nothing typed under Kotoeri yet, nothing open.
        var tracker = CompositionTracker()
        for (n, key) in [4, 14, 37, 37, 31].enumerated() { tracker.key(Int64(key), shortcut: false, at: UInt64(n), source: "") }
        #expect(!tracker.snapshot(at: Self.s, sourceID: Self.K), "the switch ended whatever the letters were")
        // Then "nihon" under Kotoeri: open.
        for (n, key) in [45, 34, 4, 31, 45].enumerated() { tracker.key(Int64(key), shortcut: false, at: 10 + UInt64(n), source: Self.K) }
        #expect(tracker.snapshot(at: Self.s, sourceID: Self.K))
        // Back to ABC: an English take is never refused.
        #expect(!tracker.composing(snapshot: true, takeStart: Self.s, sourceID: nil))
    }

    @Test func aSwitchSeenLateOrNeverIsReadFromTheSourceSelectedAtTheCheck() {
        // (a) The switch to Kotoeri was not seen and the keys are not stamped yet (the main thread was
        // busy): read with Kotoeri selected at the check, "nihon" is open, and the take is refused.
        let watch = PersonInput(isTrusted: { false })
        let typedAt = PersonInput.now()
        for key: Int64 in [45, 34, 4, 31, 45] { watch.record(keyCode: key, at: typedAt) }
        let start = watch.compositionSnapshot(sourceID: Self.K)
        #expect(start.composing)
        #expect(watch.composing(since: start, sourceID: Self.K))
        // (b) Kotoeri "nihon", then ABC selected and "hello" typed: an English take, never refused.
        let english = PersonInput(isTrusted: { false })
        for (n, key) in [45, 34, 4, 31, 45].enumerated() { english.record(keyCode: Int64(key), at: UInt64(n)); english.stampSource(at: UInt64(n), source: Self.K) }
        for (n, key) in [4, 14, 37, 37, 31].enumerated() { english.record(keyCode: Int64(key), at: 10 + UInt64(n)); english.stampSource(at: 10 + UInt64(n), source: "") }
        let take = english.compositionSnapshot(sourceID: nil)
        #expect(!take.composing)
        #expect(!english.composing(since: take, sourceID: nil))
        #expect(!english.composing(since: (true, 0), sourceID: nil), "even a stale 'composing' start state never refuses under ABC")
    }

    @Test func aStampReachesTheKeyItWasReadFor() {
        var tracker = CompositionTracker()
        tracker.key(4, shortcut: false, at: 1)
        tracker.key(0, shortcut: false, at: 2)
        tracker.stamp(at: 1, source: "")
        tracker.stamp(at: 2, source: Self.K)
        #expect(tracker.keys.map(\.source) == [Self.K], "a key typed with a plain layout is not kept")
        #expect(tracker.snapshot(at: Self.s, sourceID: Self.K), "only the key typed under Kotoeri counts, and it is open")
    }

    @Test func typedLiveKeysNeedTheWatchAndNoComposingInputMethod() {
        #expect(LiveFieldMethod.keysAllowed(watching: true, inputMethod: false))
        #expect(!LiveFieldMethod.keysAllowed(watching: false, inputMethod: false), "not watching: no typed keys, the checked paste instead")
        #expect(!LiveFieldMethod.keysAllowed(watching: true, inputMethod: true))
    }

    @Test func aWatchThatNeverStartedOrWasStoppedIsNotWatching() {
        let watch = PersonInput(isTrusted: { false })
        #expect(!watch.watching, "no tap yet")
        watch.stop()
        #expect(!watch.watching)
        #expect(watch.acted(since: 0) == nil)
    }

    @Test func notWatchingReportsSoAndCountsAsActed() {
        let watch = PersonInput(isTrusted: { false })
        watch.overrideWatching(false)
        #expect(!watch.watching)
        #expect(watch.acted(since: 0) == nil)
        watch.overrideWatching(true)
        watch.record(keyCode: 8)
        #expect(watch.acted(since: 0) == true)
    }

    @Test func nobodyWatchingMeansNobodyCanSayThePersonDidNotAct() {
        let watch = PersonInput(isTrusted: { false })
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

    @Test func thePasteWriteIsMarkedOnlyWhenTemporary() throws {
        let temporary = try #require(TextInjector.pasteItem(text: "fictional", formatted: nil, sessionID: "a", keepCopy: false))
        #expect(temporary.types.contains(TextInjector.transientType) && temporary.types.contains(TextInjector.concealedType))
        let kept = try #require(TextInjector.pasteItem(text: "fictional", formatted: nil, sessionID: "b", keepCopy: true))
        #expect(!kept.types.contains(TextInjector.transientType) && !kept.types.contains(TextInjector.concealedType),
                "Copy dictation to clipboard: the person's copy, unmarked")
    }

    @Test func pflowsTemporaryPasteWriteIsMarkedButAKeptCopyIsNot() throws {
        let temporary = try #require(TextInjector.clipboardItem(text: "fictional words", formatted: nil, sessionID: "s1", private: true))
        #expect(temporary.types.contains(TextInjector.transientType))
        #expect(temporary.types.contains(TextInjector.concealedType))
        #expect(temporary.string(forType: .string) == "fictional words")
        let kept = try #require(TextInjector.clipboardItem(text: "fictional words", formatted: nil, sessionID: "s2", private: false))
        #expect(!kept.types.contains(TextInjector.transientType), "the copy the person asked to keep shows in clipboard managers")
        #expect(!kept.types.contains(TextInjector.concealedType))
        #expect(kept.string(forType: .string) == "fictional words")
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

    @Test func theEndReplaceWaitsForAHeldStopKey() async {
        let field = SimulatedKeyField("")
        field.keysHeld = true
        let session = FakeSession()
        session.textToReturn = "Nine pelicans rest."
        let hud = FakeHUD()
        let (coordinator, injector) = keyCoordinator(field, session: session, hud: hud)
        injector.onWaitForKeys = { field.keysHeld = false }
        coordinator.begin()
        await Task.yield()
        session.emit("nine pelicans")
        session.emit("nine pelicans rest")
        await coordinator.finish()
        #expect(injector.keyWaits == 1)
        #expect(field.value == "Nine pelicans rest.", "replaced once the key was up")
        #expect(hud.offers.isEmpty)
    }

    @Test func noTypedKeyAndNoSelectWhileTheWatchIsNotRunning() {
        let reader = FakeKeyReader("Note:")
        let watch = PersonInput(isTrusted: { false })
        var sent: [String] = []
        let field = KeyLiveTextField(reader: reader, pid: 1, facts: { _ in InsertionFacts() }, watch: watch,
                                     inputMethod: { false }, send: { sent.append($0); reader.append($0); return true })
        watch.overrideWatching(false)
        #expect(!field.canWriteRanges())
        #expect(!field.replace(NSRange(location: 5, length: 0), with: " the"))
        #expect(sent.isEmpty, "no key went out")
        #expect(field.refusal == .notWatching)
        // A fresh field (nothing typed, nothing refused yet): the select alone is refused too.
        let selectReader = FakeKeyReader("Note: the")
        let selectOnly = KeyLiveTextField(reader: selectReader, pid: 1, facts: { _ in InsertionFacts() }, watch: watch,
                                          inputMethod: { false }, send: { _ in true })
        #expect(!selectOnly.select(NSRange(location: 6, length: 3)))
        #expect(selectReader.selects.isEmpty, "nothing selected")
        #expect(selectOnly.personActedSinceSelect(), "nobody can say the person did nothing")
    }

    @Test func typedKeysAndTheSelectGoAheadWhileWatched() {
        let reader = FakeKeyReader("Note:")
        let watch = PersonInput(isTrusted: { false })
        watch.overrideWatching(true)
        var sent: [String] = []
        let field = KeyLiveTextField(reader: reader, pid: 1, facts: { _ in InsertionFacts() }, watch: watch,
                                     inputMethod: { false }, send: { sent.append($0); reader.append($0); return true })
        #expect(field.replace(NSRange(location: 5, length: 0), with: " the"))
        #expect(sent == [" the"])
        #expect(field.select(NSRange(location: 6, length: 3)))
        #expect(reader.selects == [NSRange(location: 6, length: 3)])
    }

    @Test func aRefusedGuardSendsNoKey() {
        let reader = FakeKeyReader("Note:")
        let watch = PersonInput(isTrusted: { false })
        watch.overrideWatching(true)
        var sent: [String] = []
        var facts = InsertionFacts()
        facts.composing = true
        let field = KeyLiveTextField(reader: reader, pid: 1, facts: { _ in facts }, watch: watch,
                                     inputMethod: { false }, send: { sent.append($0); return true })
        #expect(!field.replace(NSRange(location: 5, length: 0), with: " the"))
        #expect(sent.isEmpty && field.refusal == .inputMethod)
    }

    @Test func aShutDownTapIsStoppedAndBuiltAgain() {
        let watch = PersonInput(isTrusted: { true })
        var launches = 0, healthy = true
        watch.launcherForTesting = { launches += 1; $0.markRunningForTesting() }
        watch.healthForTesting = { healthy }
        watch.start()
        #expect(launches == 1 && watch.watching)
        watch.start()
        #expect(launches == 1, "a healthy tap is kept")
        healthy = false
        #expect(!watch.watching, "a shut-down tap is not reported as watching")
        watch.start()
        #expect(watch.stops == 1, "the dead tap is stopped first")
        #expect(launches == 2, "and a new one is built")
        healthy = true
        #expect(watch.watching)
    }

    @Test func aTrustChangeRebuildsTheWatchThroughTheRefresh() {
        let permissions = PermissionsManager()
        let watch = PersonInput(isTrusted: { false })
        permissions.watch = watch
        permissions.trustCheck = { true }
        permissions.refresh()
        #expect(watch.followsTrust == true, "trust back: the watch is started again")
        permissions.trustCheck = { false }
        permissions.refresh()
        #expect(watch.followsTrust == false)
        #expect(!watch.watching)
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

/// A field read through Accessibility, for KeyLiveTextField: keys typed land at the caret.
@MainActor
final class FakeKeyReader: KeyFieldReader {
    var current: LiveFieldState
    var selects: [NSRange] = []
    init(_ value: String) {
        current = LiveFieldState(app: 1, element: LiveFieldState.target, secure: false, trusted: true, value: value,
                                 selection: NSRange(location: (value as NSString).length, length: 0))
    }
    func append(_ text: String) {
        let value = (current.value ?? "") + text
        current.value = value
        current.selection = NSRange(location: (value as NSString).length, length: 0)
    }
    func state() -> LiveFieldState { current }
    func select(_ range: NSRange) -> Bool { selects.append(range); current.selection = range; return true }
    func selectionSettable() -> Bool { true }
}
