import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws rather than swallowing: an ad-hoc signed bundle outside `/Applications` can be
    /// refused by `SMAppService`, and the dropdown surfaces that instead of silently no-oping.
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
