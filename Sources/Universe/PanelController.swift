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
        appearance = NSAppearance(named: .darkAqua) // Tama's panel is always dark glass
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
        let width: CGFloat = 680
        let height: CGFloat = 560
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        // Tama centers the panel on screen: top edge at midY + height/2, growing down.
        let rect = NSRect(
            x: screen.midX - width / 2,
            y: screen.midY - height / 2,
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

    /// Open the panel on the Diary tab and start dictating, for the notch
    /// pencil button. Deliberately never touches the agent: the transcript goes
    /// straight into the diary draft.
    func openDiaryDictation() {
        // The diary needs the microphone to itself. A live call running at the
        // same time hears the entry too and answers it as a request (it once
        // offered to put a dictated entry in the calendar), so end it first.
        if NotchCallButton.isInCall { NotchCallButton.endCall() }
        // Flag the dictation before showing: opening the panel checks it so it
        // does not start a live conversation on top of the diary.
        chatState.requestedTab = ChatView.diaryTabIndex
        chatState.startDiaryDictation = true
        show()
    }

    /// Open the panel on Chats ready to type, with the microphone off and any
    /// live call ended: for the notch keyboard and ⇧⌥Space. If the panel is
    /// already up, it switches from talking to typing instead. The Microphone
    /// setting is not changed, so ⌥Space still opens talking next time.
    func openForTyping() {
        chatState.requestedTab = ChatView.chatsTabIndex
        if panel.isVisible {
            chatState.switchToTyping()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        chatState.openForTypingOnly = true
        show()
    }

    /// ⇧⌥Space: open for typing (or switch an open panel to typing, like the
    /// notch keyboard); pressed again while typing, it closes the panel.
    func toggleForTyping() {
        if panel.isVisible, chatState.isTypingOnly {
            hide()
        } else {
            openForTyping()
        }
    }

    /// Open the panel with images dropped on the notch wing already staged, so
    /// the user only has to type the question.
    func openWithAttachments(_ attachments: [ImageAttachment]) {
        guard !attachments.isEmpty else { return }
        show()
        chatState.attach(attachments)
    }

    /// Bring the panel up (idempotent) — used on launch and on reopen.
    func show() {
        // Re-center on the current screen every open (display setups change).
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2,
                                         y: screen.midY - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        MascotController.shared.resume()
        chatState.panelDidOpen()
    }

    /// Hide the panel and release everything it was holding — in particular the
    /// microphone, which must not stay open behind a dismissed window.
    func hide() {
        panel.orderOut(nil)
        MascotController.shared.pause()
        chatState.panelDidClose()
    }

    /// Hide the panel but keep a live voice conversation going. The call's
    /// waveform wing by the notch brings the panel (and transcript) back.
    func minimize() {
        chatState.keepCallThroughNextClose()
        hide()
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }
}
