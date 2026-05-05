#if os(macOS)
import Combine
import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the Settings UI can drive a "Open at login" toggle.
@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastError: String?

    private init() {
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isEnabled = service.status == .enabled
    }
}
#endif
