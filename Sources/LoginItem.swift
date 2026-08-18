import Foundation
import ServiceManagement

/// Launch-at-login registration. `SMAppService.mainApp` needs no helper target
/// and no privileged install — it registers the bundle itself.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers on first launch so the tracker is simply always there. A user
    /// who turns it off in System Settings stays off — `.requiresApproval` is
    /// their decision, not a failure to retry.
    static func enableIfUnset() {
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register()
    }

    static func set(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}
