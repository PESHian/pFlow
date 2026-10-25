import AVFoundation

@MainActor
protocol DictationSessioning: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    /// Transcript revisions for the take started with `start(take:)`, on the
    /// main thread. Bursts are coalesced, so not every revision arrives.
    var onTranscript: ((TranscriptUpdate) -> Void)? { get set }
    /// Live words stopped during the current take; the take still finishes.
    var onLiveStopped: (() -> Void)? { get set }
    /// `live` is the take's Live text choice. Off adds no live recognition work.
    func start(take: String, live: Bool) async throws
    /// Ends the take and returns its final update, numbered after every partial.
    func stop() async throws -> TranscriptUpdate
    func cancel() async
    func setCapturePaused(_ paused: Bool) throws
}

extension DictationSessioning {
    func cancel() async { _ = try? await stop() }
    var onLiveStopped: (() -> Void)? {
        get { nil }
        set {}
    }
}

/// Where a take's audio comes from: the microphone in the app, a recording
/// played in real time in timing runs.
protocol AudioCapturing: AnyObject {
    /// Called on the audio thread for each captured buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    /// Called on the audio thread with a normalized 0...1 level.
    var onLevel: ((Float) -> Void)? { get set }
    func start() throws
    func stop()
    func pause()
    func resume() throws
}

extension AudioCaptureService: AudioCapturing {}

@MainActor
final class DictationSession: DictationSessioning {
    var onLevel: ((Float) -> Void)?
    var onTranscript: ((TranscriptUpdate) -> Void)?
    var onLiveStopped: (() -> Void)?

    private let capture: AudioCapturing
    private let whisperModel: URL
    private let appleEngine: () -> StreamingTranscriber
    private let relay = AudioBufferRelay()
    private var transcriber: StreamingTranscriber?
    private var feed: LiveTranscriptFeed?
    private var locale: Locale
    private var capturePaused = false

    func setCapturePaused(_ paused: Bool) throws {
        capturePaused = paused
        if paused { capture.pause() } else { try capture.resume() }
    }

    /// The user's dictionary, read fresh at the start of each dictation so edits
    /// take effect on the next press with no restart.
    var contextualStrings: () -> [String] = { [] }
    var selectedEngine: () -> TranscriptionEngine = { .apple }

    /// The locale the on-device transcriber will actually run, resolved from the
    /// user's locale. `.unsupported` means no on-device model covers it. We stop
    /// there rather than fall back to anything that would leave the device.
    enum Resolution {
        case supported(Locale)
        case unsupported
    }

    /// Resolved once per language — querying supported locales is slow enough
    /// to be felt on the first keypress. Keyed by the language asked for, so a
    /// resolution is never used for another language, whatever order a
    /// launch prewarm and a language change finish in.
    private static var resolutions: [String: Resolution] = [:]

    init(locale: Locale = .current, capture: AudioCapturing = AudioCaptureService(),
         whisperModel: URL = WhisperModelStore.modelURL,
         appleEngine: @escaping () -> StreamingTranscriber = { TranscriptionService() }) {
        self.locale = locale
        self.capture = capture
        self.whisperModel = whisperModel
        self.appleEngine = appleEngine
    }

    /// Switch dictation language while idle. The next recording uses the new
    /// language's own resolution.
    func setLocale(_ newLocale: Locale) {
        locale = newLocale
    }

    #if DEBUG
    /// The VM harness replays recognizer output recorded on a Mac whose Speech works.
    static func assumeSupported(_ locale: Locale) { resolutions[locale.identifier] = .supported(locale) }
    #endif

    static func resolve(for locale: Locale) async -> Resolution {
        if let supported = await TranscriptionService.resolvedLocale(for: locale) {
            return .supported(supported)
        }
        return .unsupported
    }

    static func prewarm(locale: Locale = .current) async {
        let resolution = await resolve(for: locale)
        resolutions[locale.identifier] = resolution
        guard case .supported(let resolved) = resolution else { return }
        await TranscriptionService.prepareModel(for: resolved)
    }

    func start(take: String, live: Bool) async throws {
        feed?.close()
        let feed = LiveTranscriptFeed(session: take) { [weak self] update in self?.onTranscript?(update) }
        self.feed = feed
        let choice = selectedEngine()
        if choice == .whisper, !WhisperModelStore.hasModel(at: whisperModel) {
            throw WhisperError.modelNeeded
        }
        // Open the microphone FIRST. Preparing the speech stack takes a moment,
        // and anything said during it would otherwise be lost — which is what
        // made the first press feel laggy.
        relay.reset()
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        capture.onBuffer = { [weak self] buffer in
            self?.relay.receive(buffer)
        }
        try capture.start()
        if capturePaused { capture.pause() }

        let resolution: Resolution
        if choice == .whisper {
            resolution = .supported(locale)
        } else if let cached = Self.resolutions[locale.identifier] {
            resolution = cached
        } else {
            let asked = locale
            resolution = await Self.resolve(for: asked)
            Self.resolutions[asked.identifier] = resolution
        }

        guard case .supported(let engineLocale) = resolution else {
            // No on-device model covers this locale. Refuse rather than hand the
            // audio to a service that would send it off the device.
            capture.stop()
            relay.reset()
            throw TranscriptionError.unsupportedLocale
        }

        let model = whisperModel
        let engine: StreamingTranscriber = choice == .apple ? appleEngine()
            : WhisperTranscriber(modelURL: model, liveWorker: live ? { WhisperLiveProcess(model: model) } : nil)
        engine.onTranscript = { text in feed.post(text) }
        engine.onLiveStopped = { [weak self] in
            Task { @MainActor in
                guard let self, self.feed === feed else { return }
                self.onLiveStopped?()
            }
        }
        transcriber = engine

        do {
            try await engine.begin(locale: engineLocale, contextualStrings: contextualStrings())
        } catch {
            capture.stop()
            relay.reset()
            transcriber = nil
            throw error
        }

        relay.attach { buffer in engine.feed(buffer) }
    }

    func stop() async throws -> TranscriptUpdate {
        capture.stop()
        relay.reset()
        let feed = self.feed ?? LiveTranscriptFeed(session: "", deliver: { _ in })
        defer {
            transcriber = nil
            feed.close()
            self.feed = nil
        }
        let text = try await transcriber?.finish() ?? ""
        return feed.finish(text)
    }

    func cancel() async {
        capture.stop()
        relay.reset()
        feed?.close()
        feed = nil
        await transcriber?.cancel()
        transcriber = nil
    }
}
