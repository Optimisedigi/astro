import AppKit
import SwiftUI

/// Borderless floating panel that drops down from the top-center of the screen.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect, contentView: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    static let shared = PanelController()

    private let panel: FloatingPanel
    let chatState = ChatState()

    private init() {
        let width: CGFloat = 420
        let height: CGFloat = 560
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(
            x: screen.midX - width / 2,
            y: screen.maxY - height - 12,
            width: width,
            height: height
        )
        let hostingView = NSHostingView(rootView: ChatView(state: chatState))
        panel = FloatingPanel(contentRect: rect, contentView: hostingView)
    }

    var isVisible: Bool { panel.isVisible }

    /// Open the panel on a specific settings sheet, for the menubar menu.
    func openSheet(_ kind: SettingsSheetKind) {
        show()
        chatState.requestedSheet = kind
    }

    /// Bring the panel up (idempotent) — used on launch and on reopen.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        MascotController.shared.resume()
    }

    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
            MascotController.shared.pause()
        } else {
            show()
        }
    }
}
