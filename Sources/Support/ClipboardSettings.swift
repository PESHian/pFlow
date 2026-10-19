import Foundation
import Observation

@MainActor
@Observable
final class ClipboardSettings {
    private let defaults: UserDefaults
    var copyDictation: Bool {
        didSet { defaults.set(copyDictation, forKey: "pflow.copyDictationToClipboard") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        copyDictation = defaults.object(forKey: "pflow.copyDictationToClipboard") as? Bool ?? false
    }
}
