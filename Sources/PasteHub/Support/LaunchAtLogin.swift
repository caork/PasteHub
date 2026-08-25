import AppKit
import ServiceManagement

enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static var statusText: String {
        switch status {
        case .enabled: "已开启"
        case .notRegistered: "未开启"
        case .notFound: "需要把 App 放到 /Applications"
        case .requiresApproval: "等待系统批准"
        @unknown default: "未知"
        }
    }
}
