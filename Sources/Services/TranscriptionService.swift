import Speech
import AVFoundation

final class TranscriptionService: StreamingTranscriber {
    var onTranscript: ((String) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Never>?
    private let converter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?
    // Written by the results task, read by finish(); the lock keeps them consistent.
    private let textLock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var recognitionFailed = false
    private let reportingOptions: Set<SpeechTranscriber.ReportingOption>

    /// `fastResults` asks Apple Speech for quicker, less settled live words.
    /// Timing runs compare it with the default; see the speed table in the ledger.
    init(fastResults: Bool = false) {
        reportingOptions = fastResults ? [.volatileResults, .fastResults] : [.volatileResults]
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
            recognitionFailed = false
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Bias recognition toward the user's dictionary so names and jargon come
        // out right when spoken, rather than blindly rewriting the transcript.
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }

        do { try await Self.ensureModel(for: transcriber, locale: locale) }
        catch { throw TranscriptionError.modelNotReady }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.invalidFormat
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation

        readResults(transcriber.results.map { (text: String($0.text.characters), isFinal: $0.isFinal) })

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

    /// Reads the recognizer's results until the stream ends: a final result is added for good, a
    /// volatile one replaces the last volatile one (a revision of the unfinished words, not more words).
    func readResults<S: AsyncSequence>(_ results: S) where S.Element == (text: String, isFinal: Bool) {
        recognizerTask = Task { [weak self] in
            do {
                for try await result in results {
                    guard let self else { return }
                    let snapshot = self.textLock.withLock {
                        if result.isFinal {
                            self.finalized += result.text
                            self.volatile = ""
                        } else {
                            self.volatile = result.text
                        }
                        return self.finalized + self.volatile
                    }
                    self.onTranscript?(snapshot)
                }
            } catch {
                if !Task.isCancelled {
                    NSLog("pFlow: live recognition stopped: \(error.localizedDescription)")
                    self?.textLock.withLock { self?.recognitionFailed = true }
                }
            }
        }
    }

    /// How long the end of a take waits for the results stream to end once the analyzer finished.
    static let resultsDrain: Duration = .milliseconds(1500)

    func finish() async throws -> String {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // The analyzer is done, but its last final result may still be on its way to the reader:
        // the stream is let end (bounded), not cancelled under it, so the last words are kept.
        if let reader = recognizerTask { _ = await Self.drain(reader, within: Self.resultsDrain) }
        recognizerTask = nil

        // Words seen live but never finalized (the stream did not finish them in time) still count:
        // they are the last words the person saw.
        let (text, kept, failed) = textLock.withLock { (finalized + volatile, finalized + volatile, recognitionFailed) }
        transcriber = nil
        analyzer = nil
        inputBuilder = nil
        analyzerFormat = nil
        if failed {
            throw TranscriptionError.interrupted(kept: kept.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lets `task` end by itself within `limit`, else cancels it (and waits for that). True when it
    /// ended by itself.
    static func drain(_ task: Task<Void, Never>, within limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: limit); return false }
            let first = await group.next() ?? false
            if !first { task.cancel() }
            group.cancelAll()
            return first
        }
    }

    /// Reserve the model ahead of time at launch so the first dictation isn't held up by it.
    static func prepareModel(for locale: Locale) async {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        try? await ensureModel(for: transcriber, locale: locale)
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
