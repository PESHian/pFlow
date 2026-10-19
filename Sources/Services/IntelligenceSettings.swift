import Foundation
import FoundationModels
import Observation
import Security

enum IntelligenceMode: String, CaseIterable, Identifiable {
    case onDevice
    case privateCloud
    var id: String { rawValue }
    var title: String { self == .onDevice ? "On this Mac" : "Apple Private Cloud Compute" }
}

/// Both cleanup and templates use the same explicit, persisted privacy choice.
@MainActor @Observable
final class IntelligenceSettings {
    static let shared = IntelligenceSettings()
    static let defaultsKey = "intelligenceProcessingMode"
    var mode: IntelligenceMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.defaultsKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cloudAuthorization: () -> Bool
    @ObservationIgnored private var cloudModel: PrivateCloudComputeLanguageModel?

    init(defaults: UserDefaults = .standard,
         cloudAuthorization: @escaping () -> Bool = IntelligenceSettings.hasCloudEntitlement) {
        self.defaults = defaults
        self.cloudAuthorization = cloudAuthorization
        mode = defaults.string(forKey: Self.defaultsKey).flatMap(IntelligenceMode.init(rawValue:)) ?? .onDevice
    }

    nonisolated private static func hasCloudEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task,
            "com.apple.developer.private-cloud-compute" as CFString, nil) as? Bool == true
    }

    private func authorizedCloudModel() -> PrivateCloudComputeLanguageModel? {
        guard cloudAuthorization() else { return nil }
        if cloudModel == nil { cloudModel = PrivateCloudComputeLanguageModel() }
        return cloudModel
    }

    var cloudUnavailableReason: String? {
        guard let model = authorizedCloudModel() else {
            return "Requires Apple approval and an approved app build."
        }
        guard model.isAvailable else { return "Apple cloud processing is not ready on this Mac." }
        guard !model.quotaUsage.isLimitReached else { return "Apple's daily cloud limit has been reached." }
        return nil
    }

    var resolvedMode: IntelligenceMode {
        mode == .privateCloud && cloudUnavailableReason == nil ? .privateCloud : .onDevice
    }

    var isAvailable: Bool {
        resolvedMode == .privateCloud || SystemLanguageModel.default.isAvailable
    }

    /// The caller captures one route for the entire transcript. A local request
    /// can never become a cloud request if the setting changes between chunks.
    func session(instructions: String, using requested: IntelligenceMode) -> LanguageModelSession? {
        if requested == .privateCloud, mode == .privateCloud,
           cloudUnavailableReason == nil, let model = authorizedCloudModel() {
            return LanguageModelSession(model: model) { instructions }
        }
        guard SystemLanguageModel.default.isAvailable else { return nil }
        return LanguageModelSession(instructions: instructions)
    }
}
