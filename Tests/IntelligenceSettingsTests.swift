import Foundation
import FoundationModels
import Testing
@testable import Yap

@MainActor
struct IntelligenceSettingsTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "pflow.intelligence.fixture.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func defaultAndInvalidChoiceStayLocal() {
        withDefaults { defaults in
            #expect(IntelligenceSettings(defaults: defaults, cloudAuthorization: { false }).mode == .onDevice)
            defaults.set("unexpected", forKey: IntelligenceSettings.defaultsKey)
            #expect(IntelligenceSettings(defaults: defaults, cloudAuthorization: { false }).mode == .onDevice)
        }
    }

    @Test func choicePersistsButDoesNotGrantCloudPermission() {
        withDefaults { defaults in
            let settings = IntelligenceSettings(defaults: defaults, cloudAuthorization: { false })
            settings.mode = .privateCloud
            let reloaded = IntelligenceSettings(defaults: defaults, cloudAuthorization: { false })
            #expect(reloaded.mode == .privateCloud)
            #expect(reloaded.resolvedMode == .onDevice)
            #expect(reloaded.cloudUnavailableReason == "Requires Apple approval and an approved app build.")
            reloaded.mode = .onDevice
            #expect(IntelligenceSettings(defaults: defaults, cloudAuthorization: { false }).mode == .onDevice)
        }
    }

    @Test func localRequestsNeverCheckOrInitializeCloud() {
        withDefaults { defaults in
            var cloudChecks = 0
            let settings = IntelligenceSettings(defaults: defaults, cloudAuthorization: { cloudChecks += 1; return false })
            #expect(settings.resolvedMode == .onDevice)
            _ = settings.session(instructions: "Copy edit.", using: .onDevice)
            #expect(cloudChecks == 0)
            settings.mode = .privateCloud
            // A captured local route stays local even after changing the preference.
            _ = settings.session(instructions: "Copy edit.", using: .onDevice)
            #expect(cloudChecks == 0)
            #expect(settings.resolvedMode == .onDevice)
            #expect(cloudChecks == 1)
        }
    }

    @Test func actualLocalSessionRespondsWithoutCloudAuthorization() async throws {
        let name = "pflow.intelligence.native.fixture.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IntelligenceSettings(defaults: defaults, cloudAuthorization: { false })
        let session = try #require(settings.session(instructions: "Follow the request exactly.", using: .onDevice))
        let response = try await session.respond(to: "Write exactly these three words: Maple River Station",
            options: GenerationOptions(samplingMode: .greedy)).content.lowercased()
        #expect(response.contains("maple river station"))
    }
}
