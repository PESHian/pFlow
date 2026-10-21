import Foundation
import Testing
@testable import Yap

/// One Grant press takes exactly one path: Apple's prompt or the System
/// Settings pane, never both at once.
@MainActor
struct PermissionGrantTests {
    @Test func accessibilityPromptsFirstThenOpensSettings() {
        #expect(PermissionsManager.accessibilityPath(granted: false, promptedBefore: false) == .prompt)
        #expect(PermissionsManager.accessibilityPath(granted: false, promptedBefore: true) == .openSettings)
        #expect(PermissionsManager.accessibilityPath(granted: true, promptedBefore: false) == .nothing)
        #expect(PermissionsManager.accessibilityPath(granted: true, promptedBefore: true) == .nothing)
    }

    @Test func automationPromptsWhileUndecidedAndOpensSettingsOnceDenied() {
        #expect(PermissionsManager.automationPath(.notDetermined) == .prompt)
        #expect(PermissionsManager.automationPath(.denied) == .openSettings)
        #expect(PermissionsManager.automationPath(.granted) == .nothing)
    }

    @Test func eachGrantPressDoesOneThing() async throws {
        let suite = "pflow-grant-fictional-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let permissions = PermissionsManager(defaults: defaults)
        permissions.accessibility = false
        var prompts = 0, opens = 0
        permissions.grantAccessibility(prompt: { prompts += 1 }, open: { opens += 1 })
        #expect((prompts, opens) == (1, 0), "first press: Apple's prompt only")
        #expect(permissions.accessibilityPrompted)
        permissions.grantAccessibility(prompt: { prompts += 1 }, open: { opens += 1 })
        #expect((prompts, opens) == (1, 1), "second press: the pane only")
        permissions.accessibility = true
        permissions.grantAccessibility(prompt: { prompts += 1 }, open: { opens += 1 })
        #expect((prompts, opens) == (1, 1), "nothing once granted")

        var automationPrompts = 0, automationOpens = 0
        permissions.automation = .notDetermined
        await permissions.grantAutomation(prompt: { automationPrompts += 1 }, open: { automationOpens += 1 })
        #expect((automationPrompts, automationOpens) == (1, 0))
        permissions.automation = .denied
        await permissions.grantAutomation(prompt: { automationPrompts += 1 }, open: { automationOpens += 1 })
        #expect((automationPrompts, automationOpens) == (1, 1))
        permissions.automation = .granted
        await permissions.grantAutomation(prompt: { automationPrompts += 1 }, open: { automationOpens += 1 })
        #expect((automationPrompts, automationOpens) == (1, 1))
    }
}
