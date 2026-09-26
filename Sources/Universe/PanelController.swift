import AppKit
import SwiftUI

/// Borderless floating panel that drops down from the top-center of the screen.
@MainActor
final class FloatingPanel: NSPanel {
    /// Runs instead of a normal paste when ⌘V carries an image, so a copied
    /// picture attaches to the next message rather than doing nothing.
    var onPasteImage: ((NSPasteboard) -> Void)?

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

    /// While a text box is being typed in, its editor would take any image or
    /// file dragged onto it, so the panel never saw the drop. Once SwiftUI has
    /// set that editor up, it keeps only text drags and images fall through to
    /// the panel. The editor itself is never replaced: SwiftUI's text box
    /// requires its own, and swapping it crashed the app on focus.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            editor.unregisterDraggedTypes()
            editor.registerForDraggedTypes([.string])
        }
        return made
    }

    /// Key equivalents reach the window before the Edit menu, so this is where
    /// ⌘V can be claimed for images. Text pastes fall through untouched.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, let onPasteImage, Self.isPaste(event),
           ImageAttachmentLoader.pasteIsImage(.general) {
            onPasteImage(.general)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    static func isPaste(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }
}

/// The panel's content, and its drop target: an image dropped anywhere on the
/// panel is attached to the next message.
final class DropHostingView<Content: View>: NSHostingView<Content> {
    var onDropImages: (([ImageAttachmentLoader.Payload]) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes(ImageAttachmentLoader.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // .copy puts the "+" badge on the pointer: the only sign needed.
        ImageAttachmentLoader.containsImage(sender.draggingPasteboard) ? .copy : []
    }

    /// Without this the drag goes dead after its first moment over the view.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageAttachmentLoader.containsImage(sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ImageAttachmentLoader.containsImage(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let deliver = onDropImages
        return ImageAttachmentLoader.receiveDrop(from: sender.draggingPasteboard) { deliver?($0) }
    }
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
        let hostingView = DropHostingView(rootView: ChatView(state: chatState))
        panel = FloatingPanel(contentRect: rect, contentView: hostingView)

        hostingView.onDropImages = { payloads in PanelController.shared.openWithAttachments(payloads) }
        panel.onPasteImage = { pasteboard in
            PanelController.shared.openWithAttachments(ImageAttachmentLoader.payloads(from: pasteboard))
        }
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

    /// ⌃⌥I, and any image dropped or pasted: bring the panel up to take an
    /// image — typing mode, mic off, cursor in the question box. It only ever
    /// opens, never closes, so a second press cannot hang up a call. During a
    /// live call it opens as it is, so the call keeps going and can talk about
    /// the picture: typing mode would hang it up.
    func openForImage() {
        guard NotchCallButton.isInCall else {
            openForTyping()
            return
        }
        chatState.requestedTab = ChatView.chatsTabIndex
        if panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            show()
        }
    }

    /// Open the panel (for typing, or as it is during a live call) and attach
    /// images dropped or pasted onto it or onto the notch wing, so the user
    /// only has to ask the question.
    /// The picture is read (shrunk, text recognised) after the panel is up, so
    /// the drop feels instant; "Reading image…" shows meanwhile.
    func openWithAttachments(_ payloads: [ImageAttachmentLoader.Payload]) {
        if panel.isVisible {
            // Already open: stay in whatever mode it is in (a live call keeps
            // running and can discuss the picture), just bring up Chats.
            chatState.requestedTab = ChatView.chatsTabIndex
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            openForImage()
        }
        let state = chatState
        Task { @MainActor in await state.loadImages(payloads) }
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
        chatState.imageNotice = nil
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
