import Foundation
import LiveryCore
import ServiceManagement

/// Registration of the privileged helper (SMAppService daemon). Status is per bundle path; approval lives in
/// System Settings > General > Login Items & Extensions > Allow in the Background.
enum HelperManager {
    enum State: Equatable {
        case notInstalled, requiresApproval, enabled, unknown

        var title: String {
            switch self {
            case .notInstalled: return String(localized: "Not installed")
            case .requiresApproval: return String(localized: "Waiting for approval in System Settings")
            case .enabled: return String(localized: "Enabled")
            case .unknown: return String(localized: "Unknown")
            }
        }
    }

    nonisolated private static var service: SMAppService { SMAppService.daemon(plistName: HelperInfo.plistName) }

    /// Talks to backgroundtaskmanagementd, which can take seconds on a cold start: never call on the main thread.
    nonisolated static func state() -> State {
        switch service.status {
        case .notRegistered, .notFound: return .notInstalled
        case .requiresApproval: return .requiresApproval
        case .enabled: return .enabled
        @unknown default: return .unknown
        }
    }

    /// `register()` throws "Operation not permitted" while the daemon merely awaits approval; the status tells the truth.
    nonisolated static func install() -> State {
        try? service.register()
        HelperClient.forget()
        return state()
    }

    nonisolated static func uninstall() -> State {
        try? service.unregister()
        HelperClient.forget()
        return state()
    }

    /// After a rebuild the bundle holds a new helper binary; re-registering makes launchd use it. No UI for unapproved ones.
    nonisolated static func refreshIfEnabled() {
        guard state() == .enabled else { return }
        try? service.register()
        HelperClient.forget()
    }

    @MainActor
    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
