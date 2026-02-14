import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let service = SMAppService.mainApp

    var status: SMAppService.Status {
        service.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var statusLabel: String {
        LaunchAtLoginManager.statusLabel(for: status)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    nonisolated static func statusLabel(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return String(localized: "Enabled")
        case .requiresApproval:
            return String(localized: "Requires approval in System Settings > Login Items")
        case .notFound:
            return String(localized: "Not found in app bundle")
        case .notRegistered:
            return String(localized: "Disabled")
        @unknown default:
            return String(localized: "Unknown")
        }
    }
}
