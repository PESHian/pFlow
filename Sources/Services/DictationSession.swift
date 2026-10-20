import AVFoundation

@MainActor
protocol DictationSessioning: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    /// Transcript revisions for the take started with `start(take:)`, on the
    /// main thread. Bursts are coalesced, so not every revision arrives.
    var onTranscript: ((TranscriptUpdate) -> Void)? { get set }
    func start(take: String) async throws
    /// Ends the take and returns its final update, numbered after every partial.
    func stop() async throws -> TranscriptUpdate
    func cancel() async
    func setCapturePaused(_ paused: Bool) throws
}

extension DictationSessioning {
    func cancel() async { _ = try? await stop() }
}

@MainActor
final class DictationSession: DictationSessioning {
    var onLevel: ((Float) -> Void)?
    var onTranscript: ((TranscriptUpdate) -> Void)?

    private let capture = AudioCaptureService()
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

    /// Resolved once — querying supported locales is slow enough to be felt on
    /// the first keypress.
    private static var cachedResolution: Resolution?

    init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Switch dictation language while idle. Clears the resolved cache so the
    /// next recording re-resolves for the new locale.
    func setLocale(_ newLocale: Locale) {
        locale = newLocale
        Self.cachedResolution = nil
    }

    static func resolve(for locale: Locale) async -> Resolution {
        if let supported = await TranscriptionService.resolvedLocale(for: locale) {
            return .supported(supported)
        }
        return .unsupported
    }

    static func prewarm(locale: Locale = .current) async {
        let resolution = await resolve(for: locale)
        cachedResolution = resolution
        guard case .supported(let resolved) = resolution else { return }
        await TranscriptionService.prepareModel(for: resolved)
    }

    func start(take: String) async throws {
        feed?.close()
        let feed = LiveTranscriptFeed(session: take) { [weak self] update in self?.onTranscript?(update) }
        self.feed = feed
        let choice = selectedEngine()
        if choice == .whisper, !WhisperModelStore.hasModel(at: WhisperModelStore.modelURL) {
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
        } else if let cached = Self.cachedResolution {
            resolution = cached
        } else {
            resolution = await Self.resolve(for: locale)
            Self.cachedResolution = resolution
        }

        guard case .supported(let engineLocale) = resolution else {
            // No on-device model covers this locale. Refuse rather than hand the
            // audio to a service that would send it off the device.
            capture.stop()
            relay.reset()
            throw TranscriptionError.unsupportedLocale
        }

        let engine: StreamingTranscriber = choice == .apple ? TranscriptionService() : WhisperTranscriber()
        engine.onTranscript = { text in feed.post(text) }
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
