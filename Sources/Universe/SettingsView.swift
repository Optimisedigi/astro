import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView())
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Settings"
            win.contentView = hosting
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var apiKey = KeychainHelper.get(account: "anthropic") ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            SecureField("Anthropic API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") {
                    KeychainHelper.set(apiKey, account: "anthropic")
                    saved = true
                }
                if saved { Text("Saved to Keychain").foregroundStyle(.secondary) }
            }
        }
        .padding()
        .frame(width: 460)
    }
}
