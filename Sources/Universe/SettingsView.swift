import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView())
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
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
    @StateObject private var login = LoginModel()
    @State private var apiKey = KeychainHelper.get(account: "anthropic") ?? ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoginView(model: login)
            Divider()
            advanced
        }
        .frame(width: 460)
    }

    /// The API key stays as a fallback for anyone without a Claude subscription.
    private var advanced: some View {
        DisclosureGroup("Use an API key instead") {
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Anthropic API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        KeychainHelper.set(apiKey, account: "anthropic")
                        saved = true
                    }
                    if saved { Text("Saved to Keychain").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Signing in with Claude is preferred: it uses your subscription and the key never leaves the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .font(.callout)
        .padding(20)
    }
}
