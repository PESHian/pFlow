import ServiceManagement
import Observation
import Foundation

@MainActor
@Observable
final class LaunchAtLoginService {
    var isEnabled: Bool = false
    var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
        let status = isEnabled ? "enabled" : (needsApproval ? "requires approval" : "disabled")
        NSLog("pFlow: launch-at-login status: \(status)")
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("pFlow: launch-at-login toggle failed: \(error.localizedDescription)")
        }
        refresh()
    }
}
