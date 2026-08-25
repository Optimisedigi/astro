import SwiftUI

@main
struct TamaCloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("TamaClone", systemImage: "bubble.left.and.bubble.right.fill") {
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
        NSApp.setActivationPolicy(.accessory) // LSUIElement equivalent: no Dock icon
        HotKeyManager.shared.onHotKey = {
            PanelController.shared.toggle()
        }
        HotKeyManager.shared.register()
        ScheduleStore.shared.start()
    }
}
