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
        func steps(trusted: Bool) -> PermissionsManager.AccessibilityGrantSteps {
            .init(
                isTrusted: { [self] in self.trusted.isEmpty ? trusted : self.trusted.removeFirst() },
                resetOwnRow: { [self] in resets += 1 },
                prompt: { [self] in prompts += 1 },
                promptIsShowing: { [self] in showing.isEmpty ? false : showing.removeFirst() },
                openSettings: { [self] in opens += 1 },
                wait: { [self] in waits += 1 }
            )
        }
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
    }

    @Test func noPromptWithinASecondOpensTheAccessibilityList() async {
        let log = Log()
        let outcome = await PermissionsManager.grantAccessibility(log.steps(trusted: false))
        #expect(outcome == .settingsOpened)
        #expect((log.resets, log.prompts, log.opens) == (1, 1, 1))
        #expect(log.waits == 4, "about a second of looking for the prompt before opening the list")
    }

    @Test func grantNoticedWhileWaitingOpensNothing() async {
        let log = Log()
        log.trusted = [false, false, true]
        let outcome = await PermissionsManager.grantAccessibility(log.steps(trusted: false))
        #expect(outcome == .granted)
        #expect((log.resets, log.prompts, log.opens) == (1, 1, 0))
    }

    @Test func hintUnderTheStepMatchesWhatThePressDid() async {
        let permissions = PermissionsManager()
        permissions.accessibility = false
        let log = Log()
        await permissions.grantAccessibility(steps: log.steps(trusted: false))
        permissions.accessibility = false
        #expect(permissions.accessibilityHint == "Turn on pFlow in the list that opened.")
        log.showing = [true]
        await permissions.grantAccessibility(steps: log.steps(trusted: false))
        permissions.accessibility = false
        #expect(permissions.accessibilityHint == "Choose Open System Settings in Apple's message, then turn on pFlow.")
        permissions.accessibility = true
        #expect(permissions.accessibilityHint == nil, "no hint once granted")
    }

    @Test func otherPermissionsPromptWhileUndecidedAndOpenSettingsOnceDenied() {
        #expect(PermissionsManager.grantPath(for: .notDetermined) == .prompt)
        #expect(PermissionsManager.grantPath(for: .denied) == .openSettings)
        #expect(PermissionsManager.grantPath(for: .granted) == .nothing)
    }

    @Test func eachMicrophoneSpeechAndAutomationPressDoesOneThing() async {
        let permissions = PermissionsManager()
        for status in [PermissionsManager.Status.notDetermined, .denied, .granted] {
            var prompts = 0, opens = 0
            permissions.microphone = status
            permissions.speech = status
            permissions.automation = status
            await permissions.grantMicrophone(prompt: { prompts += 1 }, open: { opens += 1 })
            await permissions.grantSpeech(prompt: { prompts += 1 }, open: { opens += 1 })
            await permissions.grantAutomation(prompt: { prompts += 1 }, open: { opens += 1 })
            let expected: (Int, Int) = switch status {
            case .notDetermined: (3, 0)
            case .denied: (0, 3)
            case .granted: (0, 0)
            }
            #expect((prompts, opens) == expected, "\(status): prompts \(prompts), opens \(opens)")
        }
    }

    @Test func everyPrivacyListHasItsOwnAddress() {
        let anchors = Set([PermissionsManager.PrivacyPane.accessibility, .microphone, .speechRecognition, .automation].map(\.rawValue))
        #expect(anchors == ["Privacy_Accessibility", "Privacy_Microphone", "Privacy_SpeechRecognition", "Privacy_Automation"])
    }
}
