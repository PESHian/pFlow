import Testing
import Foundation
@testable import Yap

@MainActor
final class FakeSession: DictationSessioning {
    enum Failure: Error { case start, stop }
    var onLevel: ((Float) -> Void)?
    var onTranscript: ((TranscriptUpdate) -> Void)?
    var onLiveStopped: (() -> Void)?
    private(set) var live: Bool?
    var textToReturn = "hello world"
    var stopError: Error?
    private(set) var take: String?
    private var nextSequence = 0
    var onStop: (() -> Void)?
    var startCalled = 0
    var stopCalled = 0
    var paused = false
    var startGate: CheckedContinuation<Void, Never>?
    var suspendStart = false
    var startError: Error?
    func setCapturePaused(_ paused: Bool) throws { self.paused = paused }

    func start(take: String, live: Bool) async throws {
        self.take = take
        self.live = live
        nextSequence = 0
        startCalled += 1
        if suspendStart { await withCheckedContinuation { startGate = $0 } }
        if let startError { throw startError }
    }
    func stop() async throws -> TranscriptUpdate {
        stopCalled += 1
        onStop?()
        if let stopError { throw stopError }
        return update(textToReturn, isFinal: true)
    }

    /// A live revision for the current take, as the engine would send it.
    func emit(_ text: String) { onTranscript?(update(text, isFinal: false)) }

    func update(_ text: String, isFinal: Bool) -> TranscriptUpdate {
        defer { nextSequence += 1 }
        return TranscriptUpdate(session: take ?? "", sequence: nextSequence, text: text, isFinal: isFinal)
    }
}

@MainActor
final class FakeInjector: TextInjecting {
    var targetApplicationName: String? = "TextEdit"
    var targetApplicationBundleID: String? = "com.apple.TextEdit"
    var outcome: InjectionOutcome = .pasted
    var delivered: [String] = []
    var receivedFormatting: [NSAttributedString?] = []
    var targetCaptures = 0

    func captureTarget() { targetCaptures += 1 }
    func deliver(_ text: String) async -> InjectionOutcome {
        delivered.append(text)
        return outcome
    }
    func deliver(_ text: String, formatted: NSAttributedString?) async -> InjectionOutcome {
        receivedFormatting.append(formatted)
        return await deliver(text)
    }
}

@MainActor
final class FakeHistory: HistoryStoring {
    var saved: [String] = []
    var durations: [Double?] = []
    var spokenCounts: [Int?] = []
    var applications: [String?] = []
    func save(text: String, duration: Double?, device: String?, spokenWordCount: Int?, applicationName: String?, applicationBundleID: String?) {
        saved.append(text)
        durations.append(duration)
        spokenCounts.append(spokenWordCount)
        applications.append(applicationBundleID)
    }
}

@MainActor
final class FakeHUD: HUDControlling {
    var phases: [HUDPhase] = []
    var shown = 0
    var previews: [Bool] = []
    var partials: [String] = []
    var notes: [String?] = []
    /// Mid-take switches between the capsule and the card.
    var cards: [Bool] = []
    var hidden = 0
    var hideDelays: [Double] = []
    var offers: [String] = []
    /// The reason line on the card, as set; nil clears it.
    var reasons: [String?] = []
    var accessibilityOffers: [Bool] = []
    /// What the panel shows now: the card (true) or the capsule (false).
    var livePreview = false
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    func show(device: String?, livePreview: Bool) { shown += 1; previews.append(livePreview); self.livePreview = livePreview }
    func setPhase(_ phase: HUDPhase) { phases.append(phase) }
    func setLevel(_ level: Float) {}
    func setPartial(_ text: String) { partials.append(text) }
    func setLiveNote(_ note: String?) { notes.append(note) }
    func setLivePreview(_ on: Bool) { cards.append(on); livePreview = on }
    func hide(after seconds: Double) { hidden += 1; hideDelays.append(seconds) }
    func setActions(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }
    func offerCopy(_ text: String) { offers.append(text) }
    func setReason(_ reason: String?) { reasons.append(reason) }
    func setNeedsAccessibility(_ on: Bool) { accessibilityOffers.append(on) }
}

final class FakeSounds: SoundPlaying {
    func playStart() {}
    func playStop() {}
}

@MainActor
final class FakeCleaner: TranscriptCleaning {
    var isAvailable = true
    var transform: (String) -> String = { $0 }
    var cleaned: [String] = []

    func process(_ text: String, cleanup: Bool, vocabulary: [String]) async -> String {
        cleaned.append(text)
        return transform(text)
    }
}

@MainActor
func makeCoordinator(
    session: FakeSession? = nil,
    injector: FakeInjector? = nil,
    history: FakeHistory? = nil,
    hud: FakeHUD? = nil,
    cleaner: FakeCleaner? = nil,
    cleanupEnabled: Bool = false,
    vocabulary: [String] = [],
    replacements: [DictionaryReplacement] = [],
    formatter: TemplateFormatting? = nil,
    activeTemplate: @escaping () -> DictationTemplate? = { nil },
    availableTemplates: @escaping () -> [DictationTemplate] = { [] },
    selectTemplate: @escaping (DictationTemplate) -> Void = { _ in },
    liveTextMode: @escaping () -> LiveTextMode = { .off },
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
) -> RecordingCoordinator {
    RecordingCoordinator(
        session: session ?? FakeSession(),
        injector: injector ?? FakeInjector(),
        history: history ?? FakeHistory(),
        hud: hud ?? FakeHUD(),
        sounds: FakeSounds(),
        cleaner: cleaner ?? FakeCleaner(),
        cleanupEnabled: { cleanupEnabled },
        vocabulary: { vocabulary },
        deviceName: { "Test Mic" },
        replacements: { replacements },
        formatter: formatter,
        activeTemplate: activeTemplate,
        availableTemplates: availableTemplates,
        selectTemplate: selectTemplate,
        liveTextMode: liveTextMode,
        clock: clock
    )
}

@MainActor
struct RecordingCoordinatorTests {
    @Test func explicitReplacementsWinAfterCleanupAndWorkWithoutTheModel() async {
        let rules = [DictionaryReplacement(heard: "Senten", replacement: "Sinton"),
                     DictionaryReplacement(heard: "sent in", replacement: "Sinton")]
        for available in [false, true] {
            let session = FakeSession()
            session.textToReturn = "Senten said sent in"
            let injector = FakeInjector()
            let history = FakeHistory()
            let cleaner = FakeCleaner()
            cleaner.isAvailable = available
            cleaner.transform = { _ in "SENTEN said sent in." }
            let coordinator = makeCoordinator(session: session, injector: injector, history: history,
                cleaner: cleaner, cleanupEnabled: true, replacements: rules)
            await coordinator.toggle()
            await coordinator.finish()
            #expect(injector.delivered == [available ? "Sinton said Sinton." : "Sinton said Sinton"])
            #expect(history.saved == injector.delivered)
        }
    }

    @Test func usageKeepsSpokenWordsOriginalAppAndRecordingOnlyTime() async {
        var now: TimeInterval = 100
        let session = FakeSession()
        session.textToReturn = "um one two three"
        let injector = FakeInjector()
        let history = FakeHistory()
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in now = 700; return "One two three." }
        let coordinator = makeCoordinator(session: session, injector: injector, history: history,
                                          cleaner: cleaner, cleanupEnabled: true, clock: { now })
        await coordinator.toggle()
        injector.targetApplicationBundleID = "com.apple.Safari"
        now = 160
        await coordinator.finish()
        #expect(history.durations == [60])
        #expect(history.spokenCounts == [4])
        #expect(history.applications == ["com.apple.TextEdit"])
        #expect(history.saved == ["One two three."])
    }
    @Test func failedStartShowsErrorAndAllowsRetry() async {
        let session = FakeSession()
        session.startError = FakeSession.Failure.start
        let injector = FakeInjector()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(session: session, injector: injector, hud: hud)
        await coordinator.toggle()
        #expect(coordinator.state == .idle)
        #expect(hud.phases.last == .failed)
        #expect(hud.hideDelays == [2])
        #expect(session.stopCalled == 1)
        #expect(injector.delivered.isEmpty)
        session.startError = nil
        await coordinator.toggle()
        #expect(coordinator.state == .recording)
        await coordinator.finish()
        #expect(injector.delivered == ["hello world"])
    }
    @Test func releaseWaitsForStartupAndStopsOnlyOnce() async {
        let session = FakeSession()
        session.suspendStart = true
        let injector = FakeInjector()
        let coordinator = makeCoordinator(session: session, injector: injector)
        coordinator.begin()
        while session.startGate == nil { await Task.yield() }
        coordinator.pauseCapture(true)
        #expect(session.paused)
        let finish = Task { await coordinator.finish() }
        while coordinator.state == .recording { await Task.yield() }
        #expect(session.stopCalled == 0)
        session.startGate?.resume()
        await finish.value
        #expect(session.stopCalled == 1)
        #expect(injector.delivered == ["hello world"])
    }

    @Test func quickDoubleTapResumesExistingSession() async {
        let session = FakeSession()
        let coordinator = makeCoordinator(session: session)
        await coordinator.toggle()
        coordinator.pauseCapture(true)
        #expect(session.paused)
        coordinator.pauseCapture(false)
        #expect(!session.paused)
        #expect(session.startCalled == 1)
        await coordinator.finish()
        await coordinator.finish()
        #expect(session.stopCalled == 1)
    }
    @Test func startsIdle() {
        let coordinator = makeCoordinator()
        #expect(coordinator.state == .idle)
    }

    @Test func toggleStartsRecording() async {
        let session = FakeSession()
        let coordinator = makeCoordinator(session: session)
        await coordinator.toggle()
        #expect(coordinator.state == .recording)
        #expect(session.startCalled == 1)
    }

    @Test func capturesTargetAppBeforeShowingAnyUI() async {
        let injector = FakeInjector()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(injector: injector, hud: hud)

        await coordinator.toggle()

        // Must happen on start, not at insert time, or the HUD could be mistaken
        // for the target.
        #expect(injector.targetCaptures == 1)
        #expect(hud.shown == 1)
    }

    @Test func fullCycleInsertsAndSaves() async {
        let session = FakeSession()
        let injector = FakeInjector()
        let history = FakeHistory()
        let coordinator = makeCoordinator(session: session, injector: injector, history: history)

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(coordinator.state == .idle)
        #expect(session.stopCalled == 1)
        #expect(injector.delivered == ["hello world"])
        #expect(history.saved == ["hello world"])
        #expect(coordinator.lastOutcome == .pasted)
    }

    @Test func emptyTranscriptIsNotSavedOrInserted() async {
        let session = FakeSession()
        session.textToReturn = "   \n  "
        let injector = FakeInjector()
        let history = FakeHistory()
        let coordinator = makeCoordinator(session: session, injector: injector, history: history)

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(history.saved.isEmpty)
        #expect(injector.delivered.isEmpty)
        #expect(coordinator.state == .idle)
    }

    @Test func nonEditableTargetLeavesTextOnClipboard() async {
        let session = FakeSession()
        let injector = FakeInjector()
        injector.outcome = .leftOnClipboard
        let history = FakeHistory()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(session: session, injector: injector, history: history, hud: hud)

        await coordinator.toggle()
        await coordinator.toggle()

        // Still saved to history even when it couldn't be pasted.
        #expect(history.saved == ["hello world"])
        #expect(coordinator.lastOutcome == .leftOnClipboard)
        #expect(hud.phases.last == .copied)
        // "Press ⌘V" is on the card, never as words in the one-size capsule.
        #expect(hud.livePreview)
        #expect(hud.reasons.last == RecordingCoordinator.onClipboardNote)
        #expect(hud.offers == ["hello world"])
    }

    @Test func unverifiedPasteHidesImmediatelyAndKeepsTruthfulOutcomeAndHistory() async {
        let injector = FakeInjector()
        injector.outcome = .unconfirmed
        let hud = FakeHUD()
        let history = FakeHistory()
        let coordinator = makeCoordinator(injector: injector, history: history, hud: hud)
        await coordinator.toggle()
        await coordinator.finish()
        #expect(coordinator.lastOutcome == .unconfirmed)
        #expect(coordinator.state == .idle)
        #expect(history.saved == ["hello world"])
        #expect(!hud.phases.contains(.pasteUnconfirmed))
        #expect(hud.hideDelays.last == 0)
        #expect(!hud.phases.contains(.failed))
    }

    @Test func clipboardOffBlockedInsertionSavesHistoryWithoutClaimingCopied() async {
        let injector = FakeInjector()
        injector.outcome = .savedToHistory(.clipboard)
        let history = FakeHistory()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(injector: injector, history: history, hud: hud)
        await coordinator.toggle()
        await coordinator.finish()
        #expect(history.saved == ["hello world"])
        #expect(coordinator.lastOutcome == .savedToHistory(.clipboard))
        #expect(hud.phases.last == .savedToHistory)
        #expect(hud.reasons.last == InsertionBlock.clipboard.reason, "the card names the real reason")
        #expect(hud.accessibilityOffers.isEmpty, "no Grant button when Accessibility is not the problem")
        #expect(hud.offers == ["hello world"] && hud.livePreview, "the words that did not go in are offered with Copy")
        #expect(!hud.phases.contains(.copied))
        #expect(coordinator.state == .idle)
    }

    @Test func cancelDiscardsWithoutInsertingOrSaving() async {
        let session = FakeSession()
        let injector = FakeInjector()
        let history = FakeHistory()
        let coordinator = makeCoordinator(session: session, injector: injector, history: history)

        await coordinator.toggle()
        await coordinator.cancel()

        #expect(coordinator.state == .idle)
        #expect(session.stopCalled == 1) // capture is still torn down
        #expect(injector.delivered.isEmpty)
        #expect(history.saved.isEmpty)
    }

    @Test func firstEscapeArmsCancelButKeepsRecording() async {
        let session = FakeSession()
        let hud = FakeHUD()
        let coordinator = makeCoordinator(session: session, hud: hud)

        await coordinator.toggle()
        coordinator.handleEscape()

        #expect(coordinator.state == .recording)
        #expect(hud.phases.contains(.confirmCancel))
        #expect(session.stopCalled == 0)
    }

    @Test func secondEscapeDiscardsTheDictation() async {
        let session = FakeSession()
        let injector = FakeInjector()
        let history = FakeHistory()
        let coordinator = makeCoordinator(session: session, injector: injector, history: history)

        await coordinator.toggle()
        coordinator.handleEscape()
        coordinator.handleEscape()

        // handleEscape spawns the cancel, so let it settle.
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(coordinator.state == .idle)
        #expect(injector.delivered.isEmpty)
        #expect(history.saved.isEmpty)
    }

    @Test func escapeIsIgnoredWhenNotRecording() async {
        let hud = FakeHUD()
        let coordinator = makeCoordinator(hud: hud)

        coordinator.handleEscape()

        #expect(coordinator.state == .idle)
        #expect(!hud.phases.contains(.confirmCancel))
    }

    @Test func cancelIsIgnoredWhenNotRecording() async {
        let session = FakeSession()
        let coordinator = makeCoordinator(session: session)

        await coordinator.cancel()

        #expect(coordinator.state == .idle)
        #expect(session.stopCalled == 0)
    }

    @Test func cleanedTextIsInsertedAndSaved() async {
        let session = FakeSession()
        session.textToReturn = "um so hello world"
        let injector = FakeInjector()
        let history = FakeHistory()
        let hud = FakeHUD()
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "Hello world." }
        let coordinator = makeCoordinator(
            session: session, injector: injector, history: history, hud: hud,
            cleaner: cleaner, cleanupEnabled: true
        )

        await coordinator.toggle()
        await coordinator.toggle()

        // Fillers are stripped deterministically before the model sees the text.
        #expect(cleaner.cleaned == ["So hello world"])
        #expect(injector.delivered == ["Hello world."])
        #expect(history.saved == ["Hello world."])
        #expect(hud.phases.contains(.cleaning))
    }

    @Test func cleanupIsSkippedWhenDisabled() async {
        let injector = FakeInjector()
        let hud = FakeHUD()
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "should not appear" }
        let coordinator = makeCoordinator(
            injector: injector, hud: hud, cleaner: cleaner, cleanupEnabled: false
        )

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(cleaner.cleaned.isEmpty)
        #expect(injector.delivered == ["hello world"])
        #expect(!hud.phases.contains(.cleaning))
    }

    @Test func cleanupIsSkippedWhenModelUnavailable() async {
        let injector = FakeInjector()
        let hud = FakeHUD()
        let cleaner = FakeCleaner()
        cleaner.isAvailable = false
        cleaner.transform = { _ in "should not appear" }
        let coordinator = makeCoordinator(
            injector: injector, hud: hud, cleaner: cleaner, cleanupEnabled: true
        )

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(cleaner.cleaned.isEmpty)
        #expect(injector.delivered == ["hello world"])
        #expect(!hud.phases.contains(.cleaning))
    }

    @Test func trimsWhitespaceBeforeInserting() async {
        let session = FakeSession()
        session.textToReturn = "  padded text  "
        let injector = FakeInjector()
        let coordinator = makeCoordinator(session: session, injector: injector)

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(injector.delivered == ["padded text"])
    }
}
