import Foundation
import ServiceManagement

/// Starts Astro when the user logs in, via the macOS login-item service.
///
/// On by default: the first launch of the installed copy registers it once.
/// After that the user's choice wins — switching it off in the menu is never
/// undone by a later launch.
@MainActor
enum LaunchAtLogin {
    /// Set once the default has been applied, so it is applied only once.
    static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    enum State: Equatable {
        case on
        case off
        /// Registered, but macOS wants the user to allow it in System Settings.
        case needsApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Astro: could not turn open-at-login \(enabled ? "on" : "off"): \(error.localizedDescription)")
        }
        // A manual choice counts as having decided; never override it later.
        UserDefaults.standard.set(true, forKey: defaultAppliedKey)
        if enabled, state == .needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Called at launch. Registers once, and only for the copy in
    /// /Applications: registering a build-folder copy would make every login
    /// start a stale debug build instead of the installed app.
    static func applyDefaultIfNeeded(bundleURL: URL = Bundle.main.bundleURL,
                                     defaults: UserDefaults = .standard) {
        guard shouldApplyDefault(alreadyApplied: defaults.bool(forKey: defaultAppliedKey),
                                 isInstalledCopy: AppDelegate.isInstalledCopy(bundleURL)) else { return }
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: defaultAppliedKey)
        } catch {
            // Not marked as applied, so the next launch tries again.
            NSLog("Astro: could not turn on open-at-login by default: \(error.localizedDescription)")
        }
    }

    nonisolated static func shouldApplyDefault(alreadyApplied: Bool, isInstalledCopy: Bool) -> Bool {
        !alreadyApplied && isInstalledCopy
    }
}
