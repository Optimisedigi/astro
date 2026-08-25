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
            Button("Settings…") {
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
        migrateLegacyDataDirectory()
        NSApp.setActivationPolicy(.accessory) // LSUIElement equivalent: no Dock icon
        HotKeyManager.shared.onHotKey = {
            PanelController.shared.toggle()
        }
        HotKeyManager.shared.register()
        ScheduleStore.shared.start()
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
