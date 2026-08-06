import Combine
import Foundation
import ServiceManagement

protocol LaunchAtLoginServicing {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Throws rather than swallowing: an ad-hoc signed bundle outside `/Applications` can be
    /// refused by `SMAppService`, and the dropdown surfaces that instead of silently no-oping.
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
        isEnabled = service.isEnabled
    }

    func refresh() {
        isEnabled = service.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try service.setEnabled(enabled)
            isEnabled = service.isEnabled
            errorMessage = nil
        } catch {
            isEnabled = service.isEnabled
            errorMessage = error.localizedDescription
        }
    }
}

struct FixedLaunchAtLoginService: LaunchAtLoginServicing {
    let isEnabled: Bool

    func setEnabled(_ enabled: Bool) throws {}
}
