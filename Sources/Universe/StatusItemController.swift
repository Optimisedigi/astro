import AppKit
import SwiftUI

/// The menubar mascot, as a hand-built `NSStatusItem` rather than SwiftUI's
/// `MenuBarExtra`.
///
/// The reason is the click: `MenuBarExtra` always opens its menu, so there is no
/// way to make a single click *interrupt* Universe. Owning the status item lets
/// the first click mean "stop" whenever she is talking or listening, and only
/// fall through to the menu when she is idle.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private lazy var menu: NSMenu = buildMenu()

    /// True while audio is playing or the microphone is open — i.e. while a
    /// click should interrupt rather than open the menu.
    private var isActive: Bool {
        SpeechService.shared.isSpeaking || VoiceService.shared.isListening
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        // Right-click always means "menu", never "stop" — otherwise there is no
        // way to reach Quit while she is mid-sentence.
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem = item
        redraw()
        observeMood()
    }

    // MARK: - Click

    @objc private func handleClick() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseDown
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true

        if !isRightClick, isActive {
            interrupt()
            return
        }
        showMenu()
    }

    /// Stops speech and microphone capture immediately.
    ///
    /// Suspends rather than disables: "be quiet now" is about this moment, but
    /// `disableVoiceMode()` writes the preference to disk, so one stop click
    /// left the panel mute forever — opening it with the shortcut no longer
    /// started the microphone, even across relaunches. Suspending releases the
    /// mic and stops the post-reply resume without touching the saved intent;
    /// the next panel open listens again.
    func interrupt() {
        let chat = PanelController.shared.chatState
        SpeechService.shared.stop()
        if chat.voiceMode {
            chat.suspendVoiceMode()
        } else {
            VoiceService.shared.stopListening()
        }
        MenuBarMood.shared.setActivity(nil)
    }

    private func showMenu() {
        guard let statusItem else { return }
        // A status item shows its menu only when `menu` is set, which would
        // swallow the click above. Attach it just for this pop, then detach.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        func add(_ title: String, _ action: Selector, key: String = "") {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }

        add("Stop", #selector(stopFromMenu))
        add("Open Chat (⌥Space)", #selector(openChat))
        menu.addItem(.separator())
        add("AI Settings…", #selector(openAI))
        add("Voice Settings…", #selector(openVoice))
        add("Memory…", #selector(openMemory))
        add("Permissions…", #selector(openPermissions))
        menu.addItem(.separator())
        add("Advanced (API key)…", #selector(openAdvanced))
        menu.addItem(.separator())
        add("Quit", #selector(quit), key: "q")
        return menu
    }

    /// Hide "Stop" unless there is something to stop.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(at: 0)?.isHidden = !isActive
    }

    @objc private func stopFromMenu() { interrupt() }
    @objc private func openChat() { PanelController.shared.toggle() }
    @objc private func openAI() { PanelController.shared.openSheet(.ai) }
    @objc private func openVoice() { PanelController.shared.openSheet(.voice) }
    @objc private func openMemory() { PanelController.shared.openSheet(.memory) }
    @objc private func openPermissions() { PanelController.shared.openSheet(.permissions) }
    @objc private func openAdvanced() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Icon

    /// `MenuBarMood` is `@Observable`, so each tracked read fires once. Re-arm
    /// after every change to keep following it.
    private func observeMood() {
        withObservationTracking {
            _ = MenuBarMood.shared.mood
            _ = MenuBarMood.shared.animationFrame
        } onChange: {
            Task { @MainActor [weak self] in
                self?.redraw()
                self?.observeMood()
            }
        }
    }

    private func redraw() {
        guard let button = statusItem?.button else { return }
        let mood = MenuBarMood.shared
        let image = MenuBarIcon.create(mood: mood.mood, animationFrame: mood.animationFrame)
        image.isTemplate = true
        button.image = image
        button.toolTip = isActive ? "Click to stop" : "Universe"
        button.setAccessibilityLabel(
            isActive ? "Universe: \(mood.mood.rawValue). Click to stop."
                : "Universe: \(mood.mood.rawValue)"
        )
    }
}
