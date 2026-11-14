import ServiceManagement

/// Noonchi as a macOS login item. Read from the system; the app doesn't store it.
enum LaunchAtLogin {
    enum Status { case enabled, requiresApproval, off }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .off
        }
    }

    @discardableResult
    static func set(_ on: Bool) -> Status {
        let service = SMAppService.mainApp
        try? on ? service.register() : service.unregister()
        return status
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
