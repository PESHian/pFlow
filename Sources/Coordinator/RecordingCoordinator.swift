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
        applicationName = injector.targetApplicationName
        applicationBundleID = injector.targetApplicationBundleID
        recordingTemplate = activeTemplate()
        recordingTemplates = availableTemplates()
        state = .recording
        startedAt = clock()
        recordingDevice = deviceName()
        pauseCapture(false)
        sounds.playStart()
        hud.show(device: recordingDevice)
        hud.setPhase(.listening)
        startTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.session.start() }
            catch {
                NSLog("Yap: failed to start recording: \(error)")
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

        session.onLevel = { [weak self] level in self?.hud.setLevel(level) }
        session.onPartial = { [weak self] text in self?.hud.setPartial(text) }

        hud.setActions(
            onConfirm: { [weak self] in Task { await self?.toggle() } },
            onCancel: { [weak self] in Task { await self?.cancel() } }
        )
    }

    func cancel() async {
        guard state == .recording else { return }
        disarmCancel()
        state = .transcribing
        sounds.playStop()
        hud.hide(after: 0)
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
            let raw = try await session.stop()
            let spokenWordCount = raw.split(whereSeparator: \.isWhitespace).count
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if let command = SpokenTemplateCommand.parse(text, templates: recordingTemplates) {
                recordingTemplate = command.template
                text = command.text
                if text.isEmpty { selectTemplate(command.template) }
            }

            guard !text.isEmpty else {
                hud.hide(after: 0)
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
                hud.hide(after: 0)
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
            let outcome = await injector.deliver(text, formatted: formattedText)
            lastOutcome = outcome
            NSLog("Yap: insertion result: \(outcome)")
            if case .blockedBySecureInput(let holder) = outcome {
                NSLog("Yap: paste blocked by secure input held by \(holder ?? "another app"); text left on clipboard")
            }

            history.save(text: text, duration: duration, device: recordingDevice,
                         spokenWordCount: spokenWordCount, applicationName: applicationName,
                         applicationBundleID: applicationBundleID)

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
            NSLog("Yap: failed to finish recording: \(error.localizedDescription)")
            hud.hide(after: 0)
        }
        state = .idle
    }
}
