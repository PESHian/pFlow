import Speech
import AVFoundation

final class TranscriptionService: StreamingTranscriber {
    var onTranscript: ((String) -> Void)?
    var onLiveStopped: (() -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let converter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?
    // Written by the results task, read by finish(); the lock keeps them consistent.
    private let textLock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var recognitionFailed = false
    private var previewFinalized = ""
    private let fastPreview: Bool

    /// With `fastPreview` (Live text on) a second, quicker recognizer on the
    /// same audio supplies the live words: first words in about 1.1 s instead
    /// of about 4 s. Its finished words are less accurate, so the finished text
    /// still comes only from the default recognizer, exactly as with Live text
    /// Off. Measured on fixed fictional recordings; see the speed table in the
    /// ledger.
    init(fastPreview: Bool = false) {
        self.fastPreview = fastPreview
    }

    private static func makeTranscriber(locale: Locale, fast: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// The supported locale to transcribe `locale` with, or nil if this engine
    /// covers none of it. The returned locale is what must be handed to
    /// `SpeechTranscriber` — `locale` itself may carry extensions it rejects.
    static func resolvedLocale(for locale: Locale) async -> Locale? {
        SpeechLocale.bestMatch(for: locale, in: await SpeechTranscriber.supportedLocales)
    }

    static func isSupported(locale: Locale) async -> Bool {
        await resolvedLocale(for: locale) != nil
    }

    static func availableLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func begin(locale: Locale, contextualStrings: [String]) async throws {
        textLock.withLock {
            finalized = ""
            volatile = ""
            previewFinalized = ""
            recognitionFailed = false
        }

        let transcriber = Self.makeTranscriber(locale: locale, fast: false)
        self.transcriber = transcriber
        let preview = fastPreview ? Self.makeTranscriber(locale: locale, fast: true) : nil
        let modules: [any SpeechModule] = [transcriber] + (preview.map { [$0] } ?? [])

        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer

        // Bias recognition toward the user's dictionary so names and jargon come
        // out right when spoken, rather than blindly rewriting the transcript.
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }

        try await Self.ensureModel(for: transcriber, locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw TranscriptionError.invalidFormat
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation

        recognizerTask = Task { [weak self] in
            guard let self, let transcriber = self.transcriber else { return }
            do {
                for try await result in transcriber.results {
                    // A volatile result replaces the previous volatile one; it is
                    // a revision of the unfinished words, not more words.
                    let text = String(result.text.characters)
                    let snapshot = self.textLock.withLock {
                        if result.isFinal {
                            self.finalized += text
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                        return self.finalized + self.volatile
                    }
                    if !self.fastPreview { self.onTranscript?(snapshot) }
                }
            } catch {
                if !Task.isCancelled {
                    NSLog("pFlow: live recognition stopped: \(error.localizedDescription)")
                    self.textLock.withLock { self.recognitionFailed = true }
                }
            }
        }
        if let preview {
            // Live words only. If this recognizer fails, the take still
            // finishes from the default one; the preview just stops changing.
            previewTask = Task { [weak self] in
                do {
                    for try await result in preview.results {
                        guard let self else { return }
                        let text = String(result.text.characters)
                        let snapshot = self.textLock.withLock { () -> String in
                            if result.isFinal {
                                self.previewFinalized += text
                                return self.previewFinalized
                            }
                            return self.previewFinalized + text
                        }
                        self.onTranscript?(snapshot)
                    }
                } catch {
                    if !Task.isCancelled { self?.onLiveStopped?() }
                }
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let inputBuilder else { return }
        do {
            let converted = try converter.convertBuffer(buffer, to: analyzerFormat)
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        } catch {
            // Drop this buffer if conversion fails; the next one will try again.
        }
    }

    func finish() async throws -> String {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        recognizerTask?.cancel()
        recognizerTask = nil
        previewTask?.cancel()
        previewTask = nil

        let (text, kept, failed) = textLock.withLock { (finalized, finalized + volatile, recognitionFailed) }
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        analyzerFormat = nil
        if failed {
            throw TranscriptionError.interrupted(kept: kept.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reserve the model ahead of time at launch so the first dictation isn't held up by it.
    static func prepareModel(for locale: Locale) async {
        try? await ensureModel(for: makeTranscriber(locale: locale, fast: false), locale: locale)
    }

    private static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installedLocales = await SpeechTranscriber.installedLocales
        let installed = Set(installedLocales.map { $0.identifier(.bcp47) })

        if !installed.contains(locale.identifier(.bcp47)) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            do {
                try await AssetInventory.reserve(locale: locale)
            } catch {
                NSLog("pFlow: could not reserve locale \(locale.identifier): \(error.localizedDescription)")
            }
        }
    }
}
