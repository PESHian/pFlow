@preconcurrency import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Yap

private final class FixtureBundle {}

/// fixtures/live-text/whisper-windows. Windows runs the same files.
private struct WindowFixture: Decodable {
    struct Checkpoint: Decodable { let afterWindow: Int; let text: String }
    struct Expected: Decodable {
        let afterEach: [String]?
        let checkpoints: [Checkpoint]?
        let text: String
        let committedEndMs: Int
    }
    let description: String
    let language: String
    let windows: [WhisperWindow]
    let expected: Expected
}

/// A scripted live worker. `gate` holds calls until the test lets them go.
final class FakeLiveWorker: WhisperLiveWorking, @unchecked Sendable {
    private let lock = NSLock()
    var loadError: Error?
    var respond: (Int, [Float]) throws -> [WhisperWindowSegment] = { _, _ in [] }
    private var gate: DispatchSemaphore?
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var mostActive = 0
    private(set) var languages: [String] = []
    private(set) var stops = 0
    /// The finished-text pass. Throwing (the default) means the helper cannot
    /// do it, so whisper-cli runs.
    var finishText: (URL, String, Int) throws -> String = { _, _, _ in throw Scripted.crash }
    private(set) var finishes: [(recording: URL, language: String, threads: Int)] = []
    /// Calls running at once, live windows and the finished-text pass together.
    var overlapped: Int { lock.withLock { mostActive } }

    var snapshot: (calls: Int, active: Int, mostActive: Int, stops: Int) {
        lock.withLock { (calls, active, mostActive, stops) }
    }

    func hold() { lock.withLock { gate = DispatchSemaphore(value: 0) } }
    func release() {
        let gate = lock.withLock { () -> DispatchSemaphore? in defer { self.gate = nil }; return self.gate }
        gate?.signal()
    }

    func load() throws { if let loadError { throw loadError } }

    func recognize(_ samples: [Float], language: String) throws -> [WhisperWindowSegment] {
        let (call, gate) = lock.withLock { () -> (Int, DispatchSemaphore?) in
            calls += 1
            active += 1
            mostActive = max(mostActive, active)
            languages.append(language)
            return (calls, self.gate)
        }
        defer { lock.withLock { active -= 1 } }
        gate?.wait()
        return try respond(call, samples)
    }

    func finishTake(recording: URL, language: String, threads: Int) throws -> String {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            active += 1
            mostActive = max(mostActive, active)
            finishes.append((recording, language, threads))
            return finishGate
        }
        defer { lock.withLock { active -= 1 } }
        gate?.wait()
        return try finishText(recording, language, threads)
    }
    /// Holds the finished-text pass until `releaseFinish`.
    private var finishGate: DispatchSemaphore?
    func holdFinish() { lock.withLock { finishGate = DispatchSemaphore(value: 0) } }
    func releaseFinish() { lock.withLock { finishGate }?.signal() }

    /// Ending the helper makes a waiting call return, as closing the pipe does.
    func stop() { lock.withLock { stops += 1; return finishGate }?.signal() }
    var isStopped: Bool { lock.withLock { stops > 0 } }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}

private enum Scripted: Error { case crash }

private func speech(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { 0.3 * sin(Float($0) * 0.12) }
}

private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

private func segment(_ text: String, to ms: Int = 1_000) -> WhisperWindowSegment {
    WhisperWindowSegment(fromMs: 0, toMs: ms, text: text, noSpeechProbability: 0.02)
}

@MainActor
struct WhisperLiveTests {
    private func makeRecognizer(_ worker: FakeLiveWorker, texts: Box<[String]>, failures: Box<Int>,
                                language: String = "en") -> WhisperLiveRecognizer {
        WhisperLiveRecognizer(worker: worker, language: language, tick: .milliseconds(5),
                              onText: { text in texts.update { $0.append(text) } },
                              onFailure: { failures.update { $0 += 1 } })
    }

    private func feed(_ recognizer: WhisperLiveRecognizer, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { recognizer.append($0) }
    }

    // MARK: Shared window fixtures

    @Test func sharedWindowFixturesProduceTheirExpectedText() throws {
        let folder = try #require(Bundle(for: FixtureBundle.self).url(forResource: "whisper-windows", withExtension: nil))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count >= 8)
        for file in files {
            let name = file.lastPathComponent
            let fixture = try JSONDecoder().decode(WindowFixture.self, from: Data(contentsOf: file))
            var merger = WhisperLiveMerger()
            var after: [String] = []
            for window in fixture.windows {
                merger.apply(window)
                after.append(merger.text)
            }
            if let expected = fixture.expected.afterEach { #expect(after == expected, "\(name)") }
            for checkpoint in fixture.expected.checkpoints ?? [] {
                #expect(after[checkpoint.afterWindow] == checkpoint.text, "\(name) window \(checkpoint.afterWindow)")
            }
            #expect(merger.text == fixture.expected.text, "\(name)")
            #expect(merger.committedEndMs == fixture.expected.committedEndMs, "\(name)")
        }
    }

    @Test func longSessionStaysBoundedAndNeverRepeatsASentence() throws {
        let folder = try #require(Bundle(for: FixtureBundle.self).url(forResource: "whisper-windows", withExtension: nil))
        let fixture = try JSONDecoder().decode(WindowFixture.self,
                                               from: Data(contentsOf: folder.appending(path: "long-session.json")))
        #expect(fixture.windows.count >= 290)
        #expect(fixture.windows.last!.endMs >= 300_000)
        #expect(fixture.windows.allSatisfy { $0.endMs - $0.startMs <= LiveWindowPlanner().maximumMs })
        let sentences = fixture.expected.text.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
        var merger = WhisperLiveMerger()
        fixture.windows.forEach { merger.apply($0) }
        let merged = merger.text.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(merged == sentences)
    }

    // MARK: Planner, gate, ring

    @Test func plannerStartsAtKeptWordsAndNeverExceedsTheLimit() {
        let planner = LiveWindowPlanner()
        #expect(planner.next(totalSamples: 15_999, committedEndMs: 0, lastEndSample: 0) == nil)
        #expect(planner.next(totalSamples: 16_000, committedEndMs: 0, lastEndSample: 0) == 0..<16_000)
        #expect(planner.next(totalSamples: 40_000, committedEndMs: 0, lastEndSample: 30_000) == nil)
        #expect(planner.next(totalSamples: 64_000, committedEndMs: 2_500, lastEndSample: 40_000) == 40_000..<64_000)
        // Five minutes in with nothing kept: still only the last 15 seconds.
        let late = planner.next(totalSamples: 300 * 16_000, committedEndMs: 0, lastEndSample: 299 * 16_000)!
        #expect(late == (285 * 16_000)..<(300 * 16_000))
        // Kept words end less than a second ago: wait for more audio.
        #expect(planner.next(totalSamples: 64_000, committedEndMs: 3_600, lastEndSample: 40_000) == nil)
    }

    @Test func gateSkipsSilenceAndRoomNoiseButNotSpeech() {
        #expect(!LiveAudioGate.hasSpeech(Array(repeating: 0, count: 48_000)[...]))
        #expect(!LiveAudioGate.hasSpeech((0..<48_000).map { _ in Float.random(in: -0.005...0.005) }[...]))
        var clip = Array(repeating: Float(0), count: 48_000)
        for index in 16_000..<19_200 { clip[index] = 0.2 * sin(Float(index) * 0.1) }
        #expect(LiveAudioGate.hasSpeech(clip[...]))
    }

    @Test func ringKeepsTheNewestAudioInOrder() {
        var ring = LiveAudioRing(seconds: 1)
        let first = (0..<12_000).map(Float.init)
        let second = (12_000..<20_000).map(Float.init)
        first.withUnsafeBufferPointer { ring.append($0) }
        second.withUnsafeBufferPointer { ring.append($0) }
        #expect(ring.total == 20_000)
        #expect(ring.oldest == 4_000)
        #expect(ring.snapshot(0..<20_000) == (4_000..<20_000).map(Float.init))
        #expect(ring.snapshot(15_990..<16_010) == (15_990..<16_010).map(Float.init))
        let huge = (0..<40_000).map(Float.init)
        huge.withUnsafeBufferPointer { ring.append($0) }
        #expect(ring.total == 60_000)
        #expect(ring.snapshot(59_998..<60_000) == [39_998, 39_999])
    }

    // MARK: Scheduler

    @Test func oneWindowAtATimeAndNewAudioDoesNotQueue() async {
        let worker = FakeLiveWorker()
        worker.respond = { call, _ in [segment(" Window \(call)")] }
        let texts = Box<[String]>([]), failures = Box(0)
        let recognizer = makeRecognizer(worker, texts: texts, failures: failures)
        worker.hold()
        recognizer.start()
        feed(recognizer, speech(seconds: 1.5))
        await waitUntil { worker.snapshot.calls == 1 }
        // Twenty seconds arrive while the first window is still running.
        for _ in 0..<200 { feed(recognizer, speech(seconds: 0.1)) }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(worker.snapshot.calls == 1)
        worker.release()
        await waitUntil { worker.snapshot.calls == 2 && worker.snapshot.active == 0 }
        try? await Task.sleep(for: .milliseconds(150))
        let windows = recognizer.recognizedWindows
        #expect(worker.snapshot.calls == 2)
        #expect(worker.snapshot.mostActive == 1)
        #expect(windows.count == 2)
        // The second window is the newest audio, bounded, not a backlog.
        #expect(windows.last?.upperBound == Int(21.5 * 16_000))
        #expect(windows.allSatisfy { $0.count <= 15 * 16_000 })
        // The first window's words are older than the second window, so they stay.
        #expect(texts.value == ["Window 1", "Window 1 Window 2"])
        recognizer.stop()
    }

    @Test func silenceRunsNoInference() async {
        let worker = FakeLiveWorker()
        let texts = Box<[String]>([]), failures = Box(0)
        let recognizer = makeRecognizer(worker, texts: texts, failures: failures)
        recognizer.start()
        feed(recognizer, Array(repeating: 0, count: 5 * 16_000))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(worker.snapshot.calls == 0)
        feed(recognizer, speech(seconds: 1.2))
        await waitUntil { worker.snapshot.calls == 1 }
        #expect(worker.snapshot.calls == 1)
        recognizer.stop()
    }

    @Test func resultsArrivingAfterStopAreDiscarded() async {
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in [segment(" Lantern moths gathered")] }
        let texts = Box<[String]>([]), failures = Box(0)
        let recognizer = makeRecognizer(worker, texts: texts, failures: failures)
        worker.hold()
        recognizer.start()
        feed(recognizer, speech(seconds: 1.5))
        await waitUntil { worker.snapshot.calls == 1 }
        #expect(recognizer.stop() == "")
        worker.release()
        await waitUntil { worker.snapshot.active == 0 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(texts.value.isEmpty)
        #expect(recognizer.text == "")
        #expect(failures.value == 0)
        #expect(worker.snapshot.stops >= 1)
    }

    @Test func workerFailureKeepsShownWordsAndStopsLiveWork() async {
        let worker = FakeLiveWorker()
        worker.respond = { call, _ in
            if call == 1 { return [segment(" Copper kettles hummed")] }
            throw Scripted.crash
        }
        let texts = Box<[String]>([]), failures = Box(0)
        let recognizer = makeRecognizer(worker, texts: texts, failures: failures)
        recognizer.start()
        feed(recognizer, speech(seconds: 1.5))
        await waitUntil { texts.value.count == 1 }
        feed(recognizer, speech(seconds: 1.5))
        await waitUntil { failures.value == 1 }
        feed(recognizer, speech(seconds: 3))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(failures.value == 1)
        #expect(worker.snapshot.calls == 2)
        #expect(worker.snapshot.stops >= 1)
        #expect(recognizer.text == "Copper kettles hummed")
        #expect(recognizer.stop() == "Copper kettles hummed")
        #expect(failures.value == 1)
    }

    @Test func modelLoadFailureIsReportedOnce() async {
        let worker = FakeLiveWorker()
        worker.loadError = Scripted.crash
        let texts = Box<[String]>([]), failures = Box(0)
        let recognizer = makeRecognizer(worker, texts: texts, failures: failures)
        recognizer.start()
        feed(recognizer, speech(seconds: 2))
        await waitUntil { failures.value == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(failures.value == 1)
        #expect(worker.snapshot.calls == 0)
    }

    // MARK: Whole engine with fake helpers

    private struct Engine {
        let root: URL
        let model: URL
        let helper: URL
    }

    /// A fake whisper-cli that "recognizes" `final` (or fails), and a model-sized file.
    private func engine(final: String?) throws -> Engine {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let model = root.appending(path: "model")
        FileManager.default.createFile(atPath: model.path, contents: nil)
        let handle = try FileHandle(forWritingTo: model)
        try handle.truncate(atOffset: UInt64(WhisperModelStore.expectedBytes))
        try handle.close()
        let helper = root.appending(path: "helper")
        // The fake whisper-cli leaves a mark beside itself, so a test can tell whether it ran.
        let script = final.map { "#!/bin/sh\ntouch \"$(dirname \"$0\")/cli-ran\"\nprintf '%s' '\($0)' > \"${11}.txt\"\n" }
            ?? "#!/bin/sh\ntouch \"$(dirname \"$0\")/cli-ran\"\nexit 17\n"
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return Engine(root: root, model: model, helper: helper)
    }

    private func play(_ transcriber: WhisperTranscriber, seconds: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        for chunk in stride(from: 0, to: Int(seconds * 16_000), by: 1_600) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
            buffer.frameLength = 1_600
            for index in 0..<1_600 { buffer.floatChannelData![0][index] = 0.3 * sin(Float(chunk + index) * 0.12) }
            transcriber.feed(buffer)
        }
    }

    @Test func finishedTextComesFromTheWholeRecordingIncludingTheTail() async throws {
        let fake = try engine(final: "Amber kites rose over the quiet harbor")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in [segment(" Amber kites rose")] }
        let shown = Box<[String]>([])
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root, liveWorker: { worker })
        transcriber.onTranscript = { text in shown.update { $0.append(text) } }
        try await transcriber.begin(locale: Locale(identifier: "es-ES"), contextualStrings: [])
        play(transcriber, seconds: 1.5)
        await waitUntil { !shown.value.isEmpty }
        #expect(shown.value == ["Amber kites rose"])
        // The tail: spoken after the last live window, before stop.
        play(transcriber, seconds: 0.4)
        let final = try await transcriber.finish()
        #expect(final == "Amber kites rose over the quiet harbor")
        #expect(worker.languages.allSatisfy { $0 == "es" } && !worker.languages.isEmpty)
        #expect(worker.snapshot.stops >= 1)
    }

    private func cliRan(_ fake: Engine) -> Bool {
        FileManager.default.fileExists(atPath: fake.root.appending(path: "cli-ran").path)
    }

    private func play48kStereo(_ transcriber: WhisperTranscriber, seconds: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for chunk in stride(from: 0, to: Int(seconds * 48_000), by: 4_800) {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            for channel in 0..<2 {
                for index in 0..<4_800 { buffer.floatChannelData![channel][index] = 0.3 * sin(Float(chunk + index) * 0.04) }
            }
            transcriber.feed(buffer)
        }
    }

    @Test func loadedHelperMakesTheFinishedTextWithoutStartingWhisperCLI() async throws {
        let fake = try engine(final: "From whisper-cli")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in [segment(" Amber kites rose")] }
        let frames = Box<Int64>(0)
        worker.finishText = { url, _, _ in
            frames.update { $0 = (try? AVAudioFile(forReading: url).length) ?? -1 }
            return "Amber kites rose over the quiet harbor\nand landed by the pier.\n"
        }
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root, liveWorker: { worker })
        try await transcriber.begin(locale: Locale(identifier: "es-ES"), contextualStrings: [])
        play(transcriber, seconds: 1.5)
        await waitUntil { worker.snapshot.calls > 0 }
        play(transcriber, seconds: 0.4)
        let final = try await transcriber.finish()
        // One line per segment comes back as one paragraph.
        #expect(final == "Amber kites rose over the quiet harbor and landed by the pier.")
        #expect(worker.finishes.map(\.language) == ["es"])
        #expect(worker.finishes.map(\.threads) == [WhisperTranscriber.finalThreads])
        // The whole take, tail included, written before the pass started.
        #expect(frames.value == Int64(1.9 * 16_000))
        #expect(!cliRan(fake))
        #expect(worker.snapshot.stops >= 1)
    }

    @Test func helperThatCannotFinishFallsBackToWhisperCLI() async throws {
        let fake = try engine(final: "Silver geese crossed the marsh")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in [segment(" Silver geese")] }
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root, liveWorker: { worker })
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        play(transcriber, seconds: 1.5)
        await waitUntil { worker.snapshot.calls > 0 }
        #expect(try await transcriber.finish() == "Silver geese crossed the marsh")
        #expect(worker.finishes.count == 1 && cliRan(fake))
    }

    @Test func windowRunningAtStopFinishesBeforeTheFinishedTextPass() async throws {
        let fake = try engine(final: "From whisper-cli")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in [segment(" Copper bells")] }
        worker.finishText = { _, _, _ in "Copper bells rang twice" }
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root, liveWorker: { worker })
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        worker.hold()
        play(transcriber, seconds: 1.5)
        await waitUntil { worker.snapshot.active == 1 }
        let finishing = Task { try await transcriber.finish() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(worker.finishes.isEmpty)
        worker.release()
        #expect(try await finishing.value == "Copper bells rang twice")
        #expect(worker.overlapped == 1)
        #expect(!cliRan(fake))
    }

    @Test(.timeLimit(.minutes(1))) func cancellingDuringTheHelperPassEndsItWithoutWhisperCLI() async throws {
        let fake = try engine(final: "From whisper-cli")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in [segment(" Lantern")] }
        worker.finishText = { _, _, _ in "Lantern light" }
        worker.holdFinish()
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root, liveWorker: { worker })
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        play(transcriber, seconds: 1.5)
        await waitUntil { worker.snapshot.calls > 0 }
        let finishing = Task { try await transcriber.finish() }
        await waitUntil { worker.finishes.count == 1 }
        let started = ProcessInfo.processInfo.systemUptime
        finishing.cancel()
        await #expect(throws: CancellationError.self) { try await finishing.value }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(worker.snapshot.stops >= 1 && !cliRan(fake))
    }

    @Test func eachTakeUsesItsOwnHelperInItsOwnLanguage() async throws {
        let fake = try engine(final: "From whisper-cli")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        var made: [FakeLiveWorker] = []
        for (locale, words) in [("es-ES", "Faro al amanecer"), ("fr-FR", "Phare à l'aube")] {
            let worker = FakeLiveWorker()
            worker.respond = { _, _ in [segment(" " + words)] }
            worker.finishText = { _, _, _ in words }
            made.append(worker)
            let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                                 temporaryDirectory: fake.root, liveWorker: { worker })
            try await transcriber.begin(locale: Locale(identifier: locale), contextualStrings: [])
            play(transcriber, seconds: 1.5)
            await waitUntil { worker.snapshot.calls > 0 }
            #expect(try await transcriber.finish() == words)
        }
        #expect(made.map { $0.finishes.map(\.language) } == [["es"], ["fr"]])
        #expect(made.allSatisfy { $0.languages.count == $0.snapshot.calls && $0.snapshot.stops >= 1 })
        #expect(made[0].languages.allSatisfy { $0 == "es" } && made[1].languages.allSatisfy { $0 == "fr" })
    }

    @Test func microphoneSwitchMidTakeStillGivesTheHelperTheWholeRecording() async throws {
        let fake = try engine(final: "From whisper-cli")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in [segment(" Harbor")] }
        let frames = Box<Int64>(0)
        worker.finishText = { url, _, _ in
            frames.update { $0 = (try? AVAudioFile(forReading: url).length) ?? -1 }
            return "Harbor gulls"
        }
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root, liveWorker: { worker })
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        play(transcriber, seconds: 1.5)
        await waitUntil { worker.snapshot.calls > 0 }
        play48kStereo(transcriber, seconds: 1.0)
        #expect(try await transcriber.finish() == "Harbor gulls")
        #expect(abs(frames.value - 2 * 16_000 - 8_000) <= 1_600)
        #expect(!cliRan(fake))
    }

    @Test func finalFailureKeepsTheLiveWords() async throws {
        let fake = try engine(final: nil)
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in [segment(" Velvet foxes napped")] }
        let shown = Box<[String]>([])
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root, liveWorker: { worker })
        transcriber.onTranscript = { text in shown.update { $0.append(text) } }
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        play(transcriber, seconds: 1.5)
        await waitUntil { !shown.value.isEmpty }
        do {
            _ = try await transcriber.finish()
            Issue.record("A failed final pass must not succeed")
        } catch TranscriptionError.interrupted(let kept) {
            #expect(kept == "Velvet foxes napped")
        }
    }

    @Test func liveWorkerFailureStillRunsTheFinalPass() async throws {
        let fake = try engine(final: "Silver geese crossed the marsh")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let worker = FakeLiveWorker()
        worker.respond = { _, _ in throw Scripted.crash }
        let stopped = Box(0)
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root, liveWorker: { worker })
        transcriber.onLiveStopped = { stopped.update { $0 += 1 } }
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        play(transcriber, seconds: 1.5)
        await waitUntil { stopped.value == 1 }
        #expect(stopped.value == 1)
        #expect(try await transcriber.finish() == "Silver geese crossed the marsh")
    }

    @Test func liveOffStartsNoWorkerAndShowsNothing() async throws {
        let fake = try engine(final: "Quiet canoes drifted home")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let shown = Box<[String]>([])
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper,
                                             temporaryDirectory: fake.root)
        transcriber.onTranscript = { text in shown.update { $0.append(text) } }
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        play(transcriber, seconds: 2.5)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(try await transcriber.finish() == "Quiet canoes drifted home")
        #expect(shown.value.isEmpty)
    }

    // MARK: The real helper client

    @Test func helperThatDiesMidTakeFailsTheCallWithoutEndingPFlow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appending(path: "live-helper")
        // Says "ready", never reads a request, then exits.
        try "#!/bin/sh\nprintf '\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000'\nsleep 0.3\nexit 1\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let worker = WhisperLiveProcess(executable: helper, model: root)
        let outcome = Task.detached { () -> String in
            do { try worker.load() } catch { return "load failed" }
            do { _ = try worker.recognize(speech(seconds: 2), language: "en"); return "returned" }
            catch { return "failed" }
        }
        let started = ProcessInfo.processInfo.systemUptime
        #expect(await outcome.value == "failed")
        #expect(ProcessInfo.processInfo.systemUptime - started < 5)
        worker.stop()
    }

    /// A fake live helper: says "ready", then runs `then` (shell).
    private func liveHelper(in root: URL, then: String) throws -> URL {
        let helper = root.appending(path: "live-helper-\(UUID().uuidString)")
        try "#!/bin/sh\nprintf '\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000'\n\(then)\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }

    /// Whether a process started from `helper` is still alive.
    private func running(_ helper: URL) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", helper.path]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    /// Runs `work` and reports whether it returned within `seconds`.
    private func returns(within seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let done = Box(false)
        Task.detached { await work(); done.update { $0 = true } }
        await waitUntil(seconds) { done.value }
        return done.value
    }

    @Test func helperThatStopsAnsweringIsEndedAndWhisperCLIMakesTheFinishedText() async throws {
        let fake = try engine(final: "Copper boats came home")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        // Ready, then the helper freezes (SIGSTOP) in the middle of the take,
        // and would ignore a polite SIGTERM.
        let helper = try liveHelper(in: fake.root, then: "trap '' TERM\nkill -STOP $$")
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper, temporaryDirectory: fake.root,
                                             liveWorker: { WhisperLiveProcess(executable: helper, model: fake.model) })
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        play(transcriber, seconds: 2.5)
        // A live window is now waiting on the frozen helper.
        try await Task.sleep(for: .seconds(1))
        let result = Box<String?>(nil)
        let started = ProcessInfo.processInfo.systemUptime
        let finished = await returns(within: 8) {
            let text = try? await transcriber.finish()
            result.update { $0 = text }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if !finished { await transcriber.cancel() }
        #expect(finished, "finish waited on a frozen helper")
        #expect(elapsed < 6, "finish took \(elapsed) s")
        #expect(result.value == "Copper boats came home")
        await waitUntil(2) { !running(helper) }
        #expect(!running(helper), "the frozen helper was left running")
    }

    @Test func cancelEndsAFrozenHelperAtOnceEvenWhileFinishWaits() async throws {
        let fake = try engine(final: "Copper boats came home")
        defer { try? FileManager.default.removeItem(at: fake.root) }
        let helper = try liveHelper(in: fake.root, then: "kill -STOP $$")
        let transcriber = WhisperTranscriber(modelURL: fake.model, executableURL: fake.helper, temporaryDirectory: fake.root,
                                             liveWorker: { WhisperLiveProcess(executable: helper, model: fake.model) })
        try await transcriber.begin(locale: .init(identifier: "en-US"), contextualStrings: [])
        play(transcriber, seconds: 2.5)
        try await Task.sleep(for: .seconds(1))
        let finishDone = Box(false)
        Task.detached { _ = try? await transcriber.finish(); finishDone.update { $0 = true } }
        // finish is now waiting for the window the frozen helper holds.
        try await Task.sleep(for: .milliseconds(300))
        let started = ProcessInfo.processInfo.systemUptime
        let canceled = await returns(within: 6) { await transcriber.cancel() }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(canceled)
        #expect(elapsed < 1.5, "cancel took \(elapsed) s")
        await waitUntil(2) { finishDone.value }
        #expect(finishDone.value)
        await waitUntil(2) { !running(helper) }
        #expect(!running(helper))
    }

    @Test func everyHelperReplyHasADeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        // Ready, then it reads every request and never answers.
        let helper = try liveHelper(in: root, then: "cat > /dev/null")
        let recording = root.appending(path: "audio.wav")
        try Data(count: 3_200).write(to: recording)
        for request in ["window", "finish"] {
            let worker = WhisperLiveProcess(executable: helper, model: root, replyLimit: 0.5)
            try worker.load()
            let outcome = Box("waiting")
            let started = ProcessInfo.processInfo.systemUptime
            let returned = await returns(within: 6) {
                do {
                    if request == "window" { _ = try worker.recognize(speech(seconds: 1), language: "en") }
                    else { _ = try worker.finishTake(recording: recording, language: "en", threads: 4) }
                    outcome.update { $0 = "answered" }
                } catch { outcome.update { $0 = "failed" } }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            worker.stop()
            #expect(returned && outcome.value == "failed", "\(request): \(outcome.value)")
            #expect(elapsed < 3, "\(request) took \(elapsed) s")
            #expect(worker.isStopped)
        }
    }

    @Test func aReplyForAnotherRequestIsNeverTakenAsTheCurrentOne() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        // Two replies, both for request 1 and with no segments, then it only reads.
        let reply = "printf '\\002\\000\\000\\000\\001\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000\\000'"
        let helper = try liveHelper(in: root, then: "\(reply)\n\(reply)\ncat > /dev/null")
        let worker = WhisperLiveProcess(executable: helper, model: root, replyLimit: 5)
        defer { worker.stop() }
        try worker.load()
        let samples = speech(seconds: 1)
        let first = await Task.detached { (try? worker.recognize(samples, language: "en")) != nil }.value
        #expect(first, "the reply for request 1 is accepted")
        // Request 2 reads the late reply that still names request 1.
        let second = await Task.detached { (try? worker.recognize(samples, language: "en")) != nil }.value
        #expect(!second, "a reply for request 1 was taken as the reply to request 2")
    }

    @Test func missingHelperFailsLoad() {
        let worker = WhisperLiveProcess(executable: URL(filePath: "/tmp/pflow-missing-\(UUID().uuidString)"),
                                        model: URL(filePath: "/tmp"))
        #expect(throws: (any Error).self) { try worker.load() }
    }

    // MARK: Preview note

    @Test func liveNoteFitsThePreviewInLightAndDark() throws {
        let shots = ProcessInfo.processInfo.environment["PFLOW_HUD_SHOTS"].map { URL(fileURLWithPath: $0) }
        for width in [HUDModel.previewWidth, 288] {
            for (look, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light),
                                               ("dark", .darkAqua, .dark)] {
                var sizes: [CGSize] = []
                for note in [nil, "Live words stopped"] {
                    let model = HUDModel()
                    model.livePreview = true
                    model.colorScheme = scheme
                    model.previewMaxWidth = width
                    model.partial = "The ferry captain counted seven gulls on the railing while the fog lifted"
                    model.liveNote = note
                    let view = NSHostingView(rootView: RecordingHUDView(model: model))
                    view.appearance = NSAppearance(named: appearance)
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    sizes.append(view.fittingSize)
                    if let shots, note != nil, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
                        try rep.representation(using: .png, properties: [:])?
                            .write(to: shots.appending(path: "live-note-\(Int(width))-\(look).png"))
                    }
                }
                // The note never resizes the card mid-take.
                #expect(sizes[0] == sizes[1], "\(width) \(look)")
            }
        }
    }

    // MARK: Coordinator

    @Test func liveChoiceReachesTheSessionAndAStopShowsANote() async {
        for mode in LiveTextMode.allCases {
            let session = FakeSession()
            session.textToReturn = "Gentle rain tapped the window"
            let hud = FakeHUD()
            let injector = FakeInjector()
            let coordinator = makeCoordinator(session: session, injector: injector, hud: hud, liveTextMode: { mode })
            await coordinator.toggle()
            #expect(session.live == mode.showsPreview)
            session.emit("Gentle rain")
            session.onLiveStopped?()
            await coordinator.finish()
            // A field that cannot be typed into says so first, then the take is Preview.
            let first: [String?] = mode == .typeInApp ? ["Can't type in this app"] : []
            #expect(hud.notes == first + (mode.showsPreview ? ["Live words stopped"] : []), "\(mode)")
            #expect(injector.delivered == ["Gentle rain tapped the window"], "\(mode)")
            // Late: after the take, nothing more is shown.
            session.onLiveStopped?()
            #expect(hud.notes.count == first.count + (mode.showsPreview ? 1 : 0))
        }
    }
}
