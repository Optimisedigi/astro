import SwiftUI

@main
struct UniverseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Universe", systemImage: "bubble.left.and.bubble.right.fill") {
            Button("Open Chat (⌥Space)") {
                PanelController.shared.toggle()
            }
            Divider()
            Button("AI Settings…") { PanelController.shared.openSheet(.ai) }
            Button("Voice Settings…") { PanelController.shared.openSheet(.voice) }
            Button("Permissions…") { PanelController.shared.openSheet(.permissions) }
            Divider()
            Button("Advanced (API key)…") {
                SettingsWindowController.shared.show()
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            Task {
                let passed = await SelfTest.run()
                exit(passed ? 0 : 1)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-states") {
            guard i + 1 < CommandLine.arguments.count else {
                print("usage: Universe --render-states <dir>")
                exit(2)
            }
            exit(RenderStates.run(directory: CommandLine.arguments[i + 1]) ? 0 : 1)
        }
        guard claimSingleInstance() else { return }

        migrateLegacyDataDirectory()
        NSApp.setActivationPolicy(.accessory) // LSUIElement equivalent: no Dock icon
        HotKeyManager.shared.onHotKey = {
            PanelController.shared.toggle()
        }
        HotKeyManager.shared.register()
        ScheduleStore.shared.start()
        ClipboardMonitor.shared.start()

        /* Without a Dock icon or a launch window, double-clicking the app looks like
           nothing happened. Show the panel so launching has a visible result — except
           when macOS started us at login, where a panel appearing would be a jump scare. */
        if !launchedAsLoginItem {
            PanelController.shared.show()
            // First launch: walk through permissions before the user can ask anything.
            if !OnboardingModel().hasCompletedOnboarding {
                PanelController.shared.openSheet(.onboarding)
            }
        }
    }

    /// Clicking the app in Finder, the Dock, or Spotlight while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PanelController.shared.show()
        return true
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Two copies of the same bundle ID can run from different paths (a build folder
    /// and /Applications), which means two menubar icons and a hotkey that only reaches
    /// one of them. Hand off to the copy that got here first and exit.
    private func claimSingleInstance() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return true }
        existing.activate()
        NSApp.terminate(nil)
        return false
    }

    /// The app was renamed from TamaClone; move existing sessions, schedules and
    /// workspace files across so the rename doesn't look like data loss.
    ///
    /// Merges item by item rather than moving the whole directory: the new folder
    /// may already exist (a store touched disk first), and a blanket "skip if it
    /// exists" would strand the old data forever. Existing files always win, so
    /// this is safe to run on every launch and never overwrites newer state.
    private func migrateLegacyDataDirectory() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacy = base.appendingPathComponent("TamaClone", isDirectory: true)
        let current = base.appendingPathComponent("Universe", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }

        do {
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: legacy.path) {
                let from = legacy.appendingPathComponent(name)
                let to = current.appendingPathComponent(name)
                guard !fm.fileExists(atPath: to.path) else { continue }
                try fm.moveItem(at: from, to: to)
            }
            // Only remove the old folder once everything has been claimed.
            if (try fm.contentsOfDirectory(atPath: legacy.path)).isEmpty {
                try fm.removeItem(at: legacy)
            }
        } catch {
            NSLog("Universe: could not migrate legacy data directory: \(error.localizedDescription)")
        }
    }
}
