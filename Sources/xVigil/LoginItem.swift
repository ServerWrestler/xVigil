import Foundation
import ServiceManagement

/// Start-at-login registration via SMAppService. Only works from a real .app
/// bundle — `swift run` has no bundle identity to register — so the UI
/// degrades to an explanation in that case.
@MainActor
enum LoginItem {
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration can land in .requiresApproval when the user has blocked
    /// login items for this app in System Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
