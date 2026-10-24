import Foundation
import Observation

// System dependencies are injected as protocols so this logic can be unit-tested with fakes.
@MainActor
@Observable
final class RecordingCoordinator {
    enum State: Equatable {
        case idle, recording, transcribing, inserting
    }

    private(set) var state: State = .idle
    var updateInProgress = false
    private(set) var lastOutcome: InjectionOutcome?

    private let session: DictationSessioning
    private let injector: TextInjecting
    private let history: HistoryStoring
    private let hud: HUDControlling
    private let sounds: SoundPlaying
    private let cleaner: TranscriptCleaning
    private let cleanupEnabled: () -> Bool
    private let vocabulary: () -> [String]
    private let replacements: () -> [DictionaryReplacement]
    private let formatter: TemplateFormatting?
    private let activeTemplate: () -> DictationTemplate?
    private let availableTemplates: () -> [DictationTemplate]
    private let selectTemplate: (DictationTemplate) -> Void
    private var recordingTemplate: DictationTemplate?
    private var recordingTemplates: [DictationTemplate] = []
    private let deviceName: () -> String?
    private let clock: () -> TimeInterval
    private let liveTextMode: () -> LiveTextMode
    // Read once per take, so changing the setting mid-take waits for the next one.
    private(set) var takeLiveTextMode: LiveTextMode = .off
    private var transcript = LiveTranscriptReconciler()
    private var take: String?
    // "Type in the current app" is typing into the destination this take.
    private var typingLive = false
    // Type mode asked the app (Electron, Chromium) for its Accessibility tree
    // and looks for the field again until it is there or time runs out.
    private var awaitingTyping = false
    private var typingRetryTask: Task<Void, Never>?
    /// This build was not trusted for Accessibility when the take started:
    /// no live typing and no paste can happen, so the card says so.
    private var takeAccessibilityOff = false
    /// Called once per take that found Accessibility off, after the take, so
    /// the app can open the setup page the first time it happens.
    var accessibilityMissing: (() -> Void)?
    private let typingRetryEvery: Duration
    private let typingRetryDeadline: TimeInterval

    private var startedAt: TimeInterval?
    private var recordingDevice: String?
    private var applicationName: String?
    private var applicationBundleID: String?
    private var startTask: Task<Void, Never>?

    func pauseCapture(_ paused: Bool) {
        do { try session.setCapturePaused(paused) }
        catch { Task { await cancel() } }
    }

    func begin() {
        guard state == .idle, !updateInProgress else { return }
        injector.captureTarget()
        guard !injector.targetIsSecure else {
            hud.show(device: nil, livePreview: false)
            explain(.passwordField, Self.passwordNote, text: nil)
            return
        }
        applicationName = injector.targetApplicationName
        applicationBundleID = injector.targetApplicationBundleID
        recordingTemplate = activeTemplate()
        recordingTemplates = availableTemplates()
        state = .recording
        startedAt = clock()
        recordingDevice = deviceName()
        takeLiveTextMode = liveTextMode()
        let take = UUID().uuidString
        self.take = take
        transcript.begin(session: take)
        // Checked before pFlow shows anything, against the field just captured.
        // Checked fresh every take, never cached: a grant made since the
        // last take counts now. Off, the Accessibility reason wins over
        // everything else: no live typing is tried, no Electron tree is
        // asked for (that would end in "Can't type in this app" while the
        // Grant row still says Accessibility), and the card shows the
        // words with the note and the Grant button from the first word.
        var liveNote: String?
        typingLive = false
        takeAccessibilityOff = !injector.accessibilityGranted
        if takeAccessibilityOff {
            NSLog("pFlow: Accessibility is off for this build; words cannot be typed or pasted this take")
        }
        if takeLiveTextMode == .typeInApp, !takeAccessibilityOff {
            switch injector.beginLive(session: take) {
            case .typing:
                typingLive = true
                liveNote = "Typing in \(applicationName ?? "this app")"
            case .waiting:
                // The capsule shows meanwhile: the words are expected in the app.
                awaitingTyping = true
                liveNote = "Typing in \(applicationName ?? "this app")"
                retryTyping(take: take)
            case .preview(let stop):
                liveNote = stop.previewNote
            }
        }
        let accessibilityCard = takeAccessibilityOff && takeLiveTextMode.showsPreview
        if accessibilityCard { liveNote = Self.needsAccessibilityNote }
        pauseCapture(false)
        sounds.playStart()
        hud.show(device: recordingDevice,
                 livePreview: takeLiveTextMode.showsCard(typingLive: typingLive || awaitingTyping) || accessibilityCard)
        hud.setPhase(.listening)
        if takeAccessibilityOff { hud.setNeedsAccessibility(true) }
        if let liveNote { hud.setLiveNote(liveNote) }
        startTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.session.start(take: take, live: self.takeLiveTextMode.showsPreview) }
            catch {
                NSLog("pFlow: failed to start recording: \(error)")
                self.transcript.cancel()
                self.stopAwaitingTyping()
                self.leaveLiveTyping()
                _ = try? await self.session.stop()
                self.explain(.failed, Self.startFailedNote, text: nil)
                self.state = .idle
            }
        }
    }

    static let needsAccessibilityNote = "pFlow needs Accessibility to type"
    static let onClipboardNote = "Your words are on the clipboard. Press ⌘V to paste them."

    func finish() async {
        guard state == .recording else { return }
        await stopRecording()
    }

    /// The one place Right Command effects become recording actions.
    func handle(_ effect: RightCommandActivation.Effect) {
        switch effect {
        case .start: begin()
        case .pause: pauseCapture(true)
        case .resume: pauseCapture(false)
        case .finish: Task { await finish() }
        case .cancel: Task { await cancel() }
        }
    }

    private func receive(_ update: TranscriptUpdate) {
        let accepted = transcript.lastSequence
        let changed = transcript.apply(update)
        guard takeLiveTextMode.showsPreview, transcript.lastSequence != accepted else { return }
        if changed { hud.setPartial(transcript.text) }
        // A repeat of the same words still goes to typing: it is how the last words settle.
        guard typingLive, state == .recording, let take else { return }
        if let stop = injector.reconcileLive(session: take, transcript: transcript.text) {
            showCard(note: stop.stoppedNote)
        }
    }

    /// Typing in the app ended for this take. The capsule stays; the finished
    /// words go in at the end, or the Copy card offers them.
    private func showCard(note: String) {
        hud.setLiveNote(note)
    }

    /// Looks for the field again, every `typingRetryEvery`, until the app has
    /// built its tree, something rules typing out, or `typingRetryDeadline`
    /// passes; then typing starts, or the card shows why not.
    private func retryTyping(take: String) {
        let deadline = clock() + typingRetryDeadline
        typingRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.typingRetryEvery ?? .milliseconds(100))
                guard let self, !Task.isCancelled, self.awaitingTyping, self.state == .recording, self.take == take else { return }
                switch self.injector.retryLive(session: take) {
                case .waiting where self.clock() < deadline:
                    continue
                case .waiting:
                    self.awaitingTyping = false
                    self.showCard(note: LiveInlineOwnership.Stop.unsupported.previewNote)
                case .preview(let stop):
                    self.awaitingTyping = false
                    self.showCard(note: stop.previewNote)
                case .typing:
                    self.awaitingTyping = false
                    self.typingLive = true
                    // Words heard while waiting go in now, not with the next update.
                    if let stop = self.injector.reconcileLive(session: take, transcript: self.transcript.text) {
                        self.showCard(note: stop.stoppedNote)
                    }
                }
                return
            }
        }
    }

    private func stopAwaitingTyping() {
        typingRetryTask?.cancel()
        typingRetryTask = nil
        awaitingTyping = false
    }

    /// Takes provisional typed words back out when the take ends with no text.
    /// Returns false when they had to be left in place.
    @discardableResult
    private func leaveLiveTyping() -> Bool {
        guard typingLive, let take else { return true }
        typingLive = false
        if case .left = injector.cancelLive(session: take) { return false }
        return true
    }

    private func hideAfterLiveTyping() {
        if leaveLiveTyping() {
            hud.hide(after: 0)
        } else {
            explain(.typedTextLeft, Self.typedLeftNote, text: nil)
        }
    }

    /// Live words stopped mid-take. Say so; the words shown stay, and stopping
    /// still runs the normal final recognition.
    private func liveStopped() {
        guard state == .recording, takeLiveTextMode.showsPreview else { return }
        showCard(note: "Live words stopped")
    }

    private var cancelArmed = false
    private var cancelArmTask: Task<Void, Never>?
    private let cancelArmWindow: Duration = .milliseconds(2500)

    init(
        session: DictationSessioning,
        injector: TextInjecting,
        history: HistoryStoring,
        hud: HUDControlling,
        sounds: SoundPlaying,
        cleaner: TranscriptCleaning,
        cleanupEnabled: @escaping () -> Bool,
        vocabulary: @escaping () -> [String],
        deviceName: @escaping () -> String?,
        replacements: @escaping () -> [DictionaryReplacement] = { [] },
        formatter: TemplateFormatting? = nil,
        activeTemplate: @escaping () -> DictationTemplate? = { nil },
        availableTemplates: @escaping () -> [DictationTemplate] = { [] },
        selectTemplate: @escaping (DictationTemplate) -> Void = { _ in },
        liveTextMode: @escaping () -> LiveTextMode = { .off },
        typingRetryEvery: Duration = .milliseconds(100),
        typingRetryDeadline: TimeInterval = 2,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.session = session
        self.injector = injector
        self.history = history
        self.hud = hud
        self.sounds = sounds
        self.cleaner = cleaner
        self.cleanupEnabled = cleanupEnabled
        self.vocabulary = vocabulary
        self.replacements = replacements
        self.formatter = formatter
        self.activeTemplate = activeTemplate
        self.availableTemplates = availableTemplates
        self.selectTemplate = selectTemplate
        self.deviceName = deviceName
        self.clock = clock
        self.liveTextMode = liveTextMode
        self.typingRetryEvery = typingRetryEvery
        self.typingRetryDeadline = typingRetryDeadline

        session.onLevel = { [weak self] level in self?.hud.setLevel(level) }
        session.onTranscript = { [weak self] update in self?.receive(update) }
        session.onLiveStopped = { [weak self] in self?.liveStopped() }

        hud.setActions(
            onConfirm: { [weak self] in Task { await self?.toggle() } },
            onCancel: { [weak self] in Task { await self?.cancel() } }
        )
    }

    func cancel() async {
        guard state == .recording else { return }
        disarmCancel()
        stopAwaitingTyping()
        transcript.cancel()
        state = .transcribing
        sounds.playStop()
        hideAfterLiveTyping()
        pauseCapture(true)
        await startTask?.value
        await session.cancel()
        startTask = nil
        state = .idle
    }

    // Two-step cancel: first press arms it, a second press within the window discards. Prevents a stray Escape (dismissing a menu, say) from destroying a dictation in progress.
    func handleEscape() {
        guard state == .recording else { return }

        if cancelArmed {
            disarmCancel()
            Task { await cancel() }
            return
        }

        cancelArmed = true
        hud.setPhase(.confirmCancel)
        cancelArmTask = Task { [weak self] in
            try? await Task.sleep(for: self?.cancelArmWindow ?? .milliseconds(2500))
            guard !Task.isCancelled, let self, self.cancelArmed else { return }
            self.cancelArmed = false
            if self.state == .recording { self.hud.setPhase(.listening) }
        }
    }

    private func disarmCancel() {
        cancelArmTask?.cancel()
        cancelArmTask = nil
        cancelArmed = false
    }

    func toggle() async {
        switch state {
        case .idle:
            await startRecording()
        case .recording:
            await stopRecording()
        case .transcribing, .inserting:
            break
        }
    }

    private func startRecording() async {
        begin()
        await startTask?.value
    }

    private func stopRecording() async {
        let duration = startedAt.map { max(0, clock() - $0) }
        disarmCancel()
        stopAwaitingTyping()
        state = .transcribing
        sounds.playStop()
        hud.setPhase(.transcribing)
        pauseCapture(true)
        await startTask?.value
        startTask = nil

        do {
            // The final update carries the last words. Partials still on their
            // way to the main thread are older, so they are dropped from here on.
            transcript.apply(try await session.stop())
            let raw = transcript.text
            let spokenWordCount = raw.split(whereSeparator: \.isWhitespace).count
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if let command = SpokenTemplateCommand.parse(text, templates: recordingTemplates) {
                recordingTemplate = command.template
                text = command.text
                if text.isEmpty { selectTemplate(command.template) }
            }

            guard !text.isEmpty else {
                hideAfterLiveTyping()
                state = .idle
                return
            }

            // Deterministic passes first: instant, on device, no model needed.
            text = FillerRemoval.strip(text)
            let terms = vocabulary()
            let rules = replacements()
            if !terms.isEmpty {
                let exactTargets = Set(rules.map { $0.replacement.lowercased() })
                let learned = terms.filter { !exactTargets.contains($0.lowercased()) }
                text = DictionaryCorrection.correctFirstLetterMisses(in: text, terms: learned, excluding: rules.map(\.heard))
            }

            // Removing fillers can empty a transcript that was only "um uh".
            guard !text.isEmpty else {
                hideAfterLiveTyping()
                state = .idle
                return
            }

            // Cleanup preserves known names. Only explicit Heard → Write rules
            // may substitute their exact spellings after model processing.
            var formattedText: NSAttributedString?
            if let template = recordingTemplate, let formatter {
                hud.setPhase(.cleaning)
                if let report = await formatter.formatStyled(text, using: template, vocabulary: terms) {
                    formattedText = report
                    text = report.string
                }
            } else if cleanupEnabled(), cleaner.isAvailable {
                hud.setPhase(.cleaning)
                text = await cleaner.process(text, cleanup: true, vocabulary: terms)
            }

            // Explicit user spellings win over model cleanup and work offline
            // even when Apple Intelligence is disabled or unavailable.
            if let styled = formattedText {
                let corrected = DictionaryCorrection.applyReplacements(in: styled, rules: rules)
                formattedText = corrected
                text = corrected.string
            } else {
                text = DictionaryCorrection.applyReplacements(in: text, rules: rules)
            }
            state = .inserting
            let outcome: InjectionOutcome
            var typingStopped = false
            if typingLive, let take {
                typingLive = false
                // The stop key may still be held: selecting pFlow's words and the
                // paste over them wait for it, as the plain paste does.
                await injector.waitForKeysToClear()
                // Plain text replaces the provisional words once. Accessibility
                // cannot set styles, so template formatting arrives as plain text.
                switch injector.finalizeLive(session: take, text: text) {
                case .applied: outcome = .pasted
                case .notTyped: outcome = await injector.deliver(text, formatted: formattedText)
                case .replace(let own):
                    // pFlow's own typed words are selected: the finished text goes over them, or,
                    // if anything is in doubt, they stay and the card offers the finished text.
                    outcome = await injector.insertOverSelection(text, own: own, formatted: formattedText)
                    if case .savedToHistory = outcome { typingStopped = true }
                case .kept(let stop):
                    outcome = .savedToHistory(.typingStopped(stop))
                    typingStopped = true
                }
            } else {
                outcome = await injector.deliver(text, formatted: formattedText)
            }
            lastOutcome = outcome
            NSLog("pFlow: insertion result: \(outcome)")
            if case .blockedBySecureInput(let holder) = outcome {
                NSLog("pFlow: paste blocked by secure input held by \(holder ?? "another app"); text left on clipboard")
            }

            history.save(text: text, duration: duration, device: recordingDevice,
                         spokenWordCount: spokenWordCount, applicationName: applicationName,
                         applicationBundleID: applicationBundleID)

            if typingStopped, case .savedToHistory(let block) = outcome {
                // Words pFlow typed stay; the finished text could not go in
                // safely. The card keeps it with Copy until closed or the next take.
                // Always the card (the capsule has no words and no Copy), and
                // the card has its own close; the next take replaces it.
                hud.setLivePreview(true)
                hud.setPartial(text)
                hud.setPhase(.typingStopped)
                hud.setReason(block.reason)
                if block == .typingStopped(.permission) { hud.setNeedsAccessibility(true) }
                hud.offerCopy(text)
                state = .idle
                noteAccessibilityIfMissing()
                return
            }
            switch outcome {
            case .pasted:
                hud.hide(after: 0)
            case .unconfirmed:
                hud.hide(after: 0)
            case .savedToHistory(let block):
                // The words did not go in: the card keeps them with Copy and
                // names the reason, so the person never has to dig them out
                // of History or guess what went wrong.
                hud.setLivePreview(true)
                hud.setPartial(text)
                hud.setPhase(.savedToHistory)
                hud.setReason(block.reason)
                if block == .accessibilityOff { hud.setNeedsAccessibility(true) }
                hud.offerCopy(text)
            case .leftOnClipboard, .blockedBySecureInput:
                // The words wait on the clipboard: the card says so (the
                // capsule is one size and shows at most an icon).
                hud.setLivePreview(true)
                hud.setPartial(text)
                hud.setPhase(.copied)
                hud.setReason(Self.onClipboardNote)
                hud.offerCopy(text)
            }
            noteAccessibilityIfMissing()
        } catch {
            NSLog("pFlow: failed to finish recording: \(error.localizedDescription)")
            keepRecoverableText(after: error, duration: duration)
        }
        state = .idle
    }

    /// After a take that started without Accessibility: only if it is still
    /// off now. A grant approved during the take needs no setup page, and
    /// pFlow must not come to the front over an app it just pasted into.
    private func noteAccessibilityIfMissing() {
        guard takeAccessibilityOff else { return }
        takeAccessibilityOff = false
        guard !injector.accessibilityGranted else { return }
        accessibilityMissing?()
    }

    /// Recognition failed after words were already recognized. Keep those
    /// words in History instead of dropping them, and say so. Nothing is
    /// typed: the text never finished, so it is not treated as a success.
    private func keepRecoverableText(after error: Error, duration: Double?) {
        // Words already typed stay where they are; nothing more is typed.
        typingLive = false
        var kept = transcript.text
        if case TranscriptionError.interrupted(let recovered) = error, !recovered.isEmpty { kept = recovered }
        transcript.cancel()
        kept = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else {
            hud.hide(after: 0)
            return
        }
        history.save(text: kept, duration: duration, device: recordingDevice,
                     spokenWordCount: kept.split(whereSeparator: \.isWhitespace).count,
                     applicationName: applicationName, applicationBundleID: applicationBundleID)
        let typed = take.map { injector.typedLive(session: $0) } ?? false
        explain(typed ? .liveTextKeptTyped : .liveTextKept, typed ? Self.keptTypedNote : Self.keptNote, text: kept)
    }

    /// pFlow did not put the text in: the card says why in one plain sentence
    /// and offers the words when there are any (it stays until closed or the
    /// next take); with nothing to copy it goes after a few seconds. The
    /// capsule itself only ever shows an icon.
    private func explain(_ phase: HUDPhase, _ reason: String, text: String?) {
        hud.setLivePreview(true)
        hud.setPhase(phase)
        hud.setReason(reason)
        if let text, !text.isEmpty {
            hud.setPartial(text)
            hud.offerCopy(text)
        } else {
            hud.hide(after: Self.noteSeconds)
        }
    }

    static let noteSeconds: Double = 6
    static let passwordNote = "That's a password field, so pFlow didn't type there."
    static let startFailedNote = "pFlow couldn't start recording, so nothing was typed."
    static let typedLeftNote = "Cancelled. The words pFlow already typed are still in the app."
    static let keptNote = "Speech recognition stopped early. These words are in History; nothing was typed."
    static let keptTypedNote = "Speech recognition stopped early. The words already typed stay in the app; these are in History."
}
