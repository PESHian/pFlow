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
            hud.setPhase(.passwordField)
            hud.hide(after: 2)
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
        var liveNote: String?
        typingLive = false
        if takeLiveTextMode == .typeInApp {
            switch injector.beginLive(session: take) {
            case .typing:
                typingLive = true
                liveNote = "Typing in \(applicationName ?? "this app")"
            case .preview(let stop):
                liveNote = stop.previewNote
            }
        }
        pauseCapture(false)
        sounds.playStart()
        hud.show(device: recordingDevice, livePreview: takeLiveTextMode.showsCard(typingLive: typingLive))
        hud.setPhase(.listening)
        if let liveNote { hud.setLiveNote(liveNote) }
        startTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.session.start(take: take, live: self.takeLiveTextMode.showsPreview) }
            catch {
                NSLog("pFlow: failed to start recording: \(error)")
                self.transcript.cancel()
                self.leaveLiveTyping()
                _ = try? await self.session.stop()
                self.hud.setPhase(.failed)
                self.hud.hide(after: 2)
                self.state = .idle
            }
        }
    }

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

    /// Typing in the app ended for this take, so the words now need the card.
    private func showCard(note: String) {
        hud.setLivePreview(takeLiveTextMode.showsCard(typingLive: false))
        hud.setPartial(transcript.text)
        hud.setLiveNote(note)
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
            hud.setPhase(.typedTextLeft)
            hud.hide(after: 4)
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
                // Plain text replaces the provisional words once. Accessibility
                // cannot set styles, so template formatting arrives as plain text.
                switch injector.finalizeLive(session: take, text: text) {
                case .applied: outcome = .pasted
                case .notTyped: outcome = await injector.deliver(text, formatted: formattedText)
                case .kept:
                    outcome = .savedToHistory
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

            if typingStopped {
                // Words pFlow typed stay; the finished text could not go in
                // safely. The card keeps it with Copy until closed or the next take.
                hud.setPhase(.typingStopped)
                hud.offerCopy(text)
                state = .idle
                return
            }
            switch outcome {
            case .pasted:
                hud.hide(after: 0)
            case .unconfirmed:
                hud.hide(after: 0)
            case .savedToHistory:
                hud.setPhase(.savedToHistory)
                hud.hide(after: 3)
            case .leftOnClipboard, .blockedBySecureInput:
                hud.setPhase(.copied)
                hud.hide(after: 3)
            }
        } catch {
            NSLog("pFlow: failed to finish recording: \(error.localizedDescription)")
            keepRecoverableText(after: error, duration: duration)
        }
        state = .idle
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
        hud.setPhase(typed ? .liveTextKeptTyped : .liveTextKept)
        hud.hide(after: 4)
    }
}
