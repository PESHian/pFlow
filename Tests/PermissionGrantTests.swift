import Foundation
import Testing
@testable import Yap

/// One Grant press always does one visible thing, and never two at once.
/// The real steps (tccutil, Apple's prompt, System Settings) are injected,
/// so nothing here touches this Mac's privacy settings.
@MainActor
struct PermissionGrantTests {
    private final class Log {
        var resets = 0, prompts = 0, opens = 0, waits = 0
        var trusted: [Bool] = []
        var showing: [Bool] = []
        var watches = 0, promptsAtWatch = -1
        var firstPress = true
        var suspend: (() async -> Void)?
        func steps(trusted: Bool) -> PermissionsManager.AccessibilityGrantSteps {
            .init(
                isTrusted: { [self] in self.trusted.isEmpty ? trusted : self.trusted.removeFirst() },
                resetOwnRow: { [self] in resets += 1 },
                firstPressForThisCopy: { [self] in firstPress },
                watchForPrompt: { [self] in
                    watches += 1; promptsAtWatch = prompts
                    return { [self] in showing.isEmpty ? false : showing.removeFirst() }
                },
                prompt: { [self] in prompts += 1 },
                openSettings: { [self] in opens += 1 },
                wait: { [self] in waits += 1; await suspend?() }
            )
        }
    }

    /// Owner 2026-11-01: he turned pFlow on, it still said Grant, he pressed
    /// Grant again, and every press wiped the switch he had just turned on.
    @Test func anotherPressNeverClearsTheSwitch() async {
        let log = Log()
        log.firstPress = false
        log.showing = [true]
        let outcome = await PermissionsManager.grantAccessibility(log.steps(trusted: false))
        #expect(outcome == .promptShown)
        #expect((log.resets, log.prompts) == (0, 1), "no clearing after the first press for this copy")
    }

    @Test func theOldSwitchIsClearedOncePerCopyOfPFlow() {
        let scratch = ScratchDefaults("pflow.grant.once")
        defer { withExtendedLifetime(scratch) {} }
        let defaults = scratch.defaults
        #expect(PermissionsManager.firstPress(forCopy: "copy-a", defaults: defaults))
        #expect(!PermissionsManager.firstPress(forCopy: "copy-a", defaults: defaults))
        #expect(!PermissionsManager.firstPress(forCopy: "copy-a", defaults: defaults))
        #expect(PermissionsManager.firstPress(forCopy: "copy-b", defaults: defaults), "an update is a new copy: its old row is cleared once")
        #expect(!PermissionsManager.firstPress(forCopy: "copy-b", defaults: defaults))
        #expect(!PermissionsManager.thisCopy().isEmpty)
        #expect(PermissionsManager.thisCopy() == PermissionsManager.thisCopy())
    }

    @Test func trustedAlreadyDoesNothing() async {
        let log = Log()
        let outcome = await PermissionsManager.grantAccessibility(log.steps(trusted: true))
        #expect(outcome == .alreadyTrusted)
        #expect((log.resets, log.prompts, log.opens) == (0, 0, 0))
    }

    @Test func stalerowIsClearedThenApplesPromptShowsAndSettingsStaysClosed() async {
        let log = Log()
        log.showing = [false, true]
        let outcome = await PermissionsManager.grantAccessibility(log.steps(trusted: false))
        #expect(outcome == .promptShown)
        #expect((log.resets, log.prompts, log.opens) == (1, 1, 0), "the row is cleared before the prompt, and the pane is not opened on top of it")
        #expect(log.waits == 1)
        #expect(log.watches == 1 && log.promptsAtWatch == 0, "the watch starts before the prompt, so only a window that appears after it counts")
    }

    @Test func noPromptWithinASecondOpensTheAccessibilityList() async {
        let log = Log()
        let outcome = await PermissionsManager.grantAccessibility(log.steps(trusted: false))
        #expect(outcome == .settingsOpened)
        #expect((log.resets, log.prompts, log.opens) == (1, 1, 1))
        #expect(log.waits == PermissionsManager.promptWaits && PermissionsManager.promptWaits == 10, "about 2.5 s of looking for the prompt before opening the list")
    }

    @Test func aPromptThatTakesOverASecondStillCountsAndTheListStaysClosed() async {
        let log = Log()
        log.showing = Array(repeating: false, count: 6) + [true]
        let outcome = await PermissionsManager.grantAccessibility(log.steps(trusted: false))
        #expect(outcome == .promptShown)
        #expect((log.resets, log.prompts, log.opens) == (1, 1, 0), "one action: the slow prompt, not the list on top of it")
        #expect(log.waits == 6)
    }

    @Test func grantNoticedWhileWaitingOpensNothing() async {
        let log = Log()
        log.trusted = [false, false, true]
        let outcome = await PermissionsManager.grantAccessibility(log.steps(trusted: false))
        #expect(outcome == .granted)
        #expect((log.resets, log.prompts, log.opens) == (1, 1, 0))
    }

    @Test func aSecondPressWhileOneIsRunningDoesNothing() async {
        let permissions = PermissionsManager()
        permissions.accessibility = false
        let log = Log()
        let gate = AsyncStream<Void>.makeStream()
        var iterator = gate.stream.makeAsyncIterator()
        // Only the first press blocks on the gate; a second press that got
        // through would run to its end (and fail the counts below).
        var blocked = false
        log.suspend = { if !blocked { blocked = true; _ = await iterator.next() } }
        async let first: Void = permissions.grantAccessibility(steps: log.steps(trusted: false))
        // The row reset runs off the main actor now, so give the first press
        // a few turns to reach its prompt before the second press lands.
        for _ in 0..<20 where log.prompts == 0 { await Task.yield() }
        await permissions.grantAccessibility(steps: log.steps(trusted: false))
        #expect((log.resets, log.prompts) == (1, 1), "the second press must not reset and prompt again")
        gate.continuation.finish()
        await first
        #expect((log.resets, log.prompts, log.opens) == (1, 1, 1))
    }

    @Test func hintUnderTheStepMatchesWhatThePressDid() async {
        let permissions = PermissionsManager()
        permissions.accessibility = false
        let log = Log()
        await permissions.grantAccessibility(steps: log.steps(trusted: false))
        permissions.accessibility = false
        #expect(permissions.accessibilityHint == "Turn on “\(PermissionsManager.listedName)” in the list that opened.")
        log.showing = [true]
        await permissions.grantAccessibility(steps: log.steps(trusted: false))
        permissions.accessibility = false
        #expect(permissions.accessibilityHint == "Choose Open System Settings in Apple's message, then turn on “\(PermissionsManager.listedName)”.")
        permissions.accessibility = true
        #expect(permissions.accessibilityHint == nil, "no hint once granted")
    }

    @Test func otherPermissionsPromptWhileUndecidedAndOpenSettingsOnceDenied() {
        #expect(PermissionsManager.grantPath(for: .notDetermined) == .prompt)
        #expect(PermissionsManager.grantPath(for: .denied) == .openSettings)
        #expect(PermissionsManager.grantPath(for: .granted) == .nothing)
    }

    @Test func eachMicrophoneAndSpeechPressDoesOneThing() async {
        let permissions = PermissionsManager()
        for status in [PermissionsManager.Status.notDetermined, .denied, .granted] {
            var prompts = 0, opens = 0
            permissions.microphone = status
            permissions.speech = status
            await permissions.grantMicrophone(prompt: { prompts += 1 }, open: { opens += 1 })
            await permissions.grantSpeech(prompt: { prompts += 1 }, open: { opens += 1 })
            let expected: (Int, Int) = switch status {
            case .notDetermined: (2, 0)
            case .denied: (0, 2)
            case .granted: (0, 0)
            }
            #expect((prompts, opens) == expected, "\(status): prompts \(prompts), opens \(opens)")
        }
    }

    @Test func everyPrivacyListHasItsOwnAddress() {
        let anchors = Set([PermissionsManager.PrivacyPane.accessibility, .microphone, .speechRecognition].map(\.rawValue))
        #expect(anchors == ["Privacy_Accessibility", "Privacy_Microphone", "Privacy_SpeechRecognition"])
    }

    /// pFlow pastes with its own key events, so it never asks to control
    /// System Events: setup is Microphone, Speech Recognition and Accessibility.
    @Test func setupNeedsNoAutomation() {
        let permissions = PermissionsManager()
        permissions.microphone = .granted
        permissions.speech = .granted
        permissions.accessibility = true
        #expect(permissions.allGranted)
        let plist = try? String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/PermissionGrantTests.swift", with: "Sources/Info.plist"), encoding: .utf8)
        #expect(plist?.contains("NSAppleEventsUsageDescription") == false)
    }
}
