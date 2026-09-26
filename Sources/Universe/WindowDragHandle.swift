import AppKit
import SwiftUI

/// Marks the entire input section as draggable without covering its controls.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView {
        WindowDragView(frame: .zero)
    }

    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView, NSGestureRecognizerDelegate {
    private let pan = NSPanGestureRecognizer()
    private var dragStart: (pointer: NSPoint, origin: NSPoint)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        pan.target = self
        pan.action = #selector(didPan(_:))
        pan.delegate = self
        pan.buttonMask = 1
        // Clicks still focus the text field or activate a button. Only movement
        // becomes a window drag; dragging text in this section moves the window.
        pan.delaysPrimaryMouseButtonEvents = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // This view only measures the region. Normal clicks and incoming image drops
    // continue to the existing controls and DropHostingView.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        pan.view?.removeGestureRecognizer(pan)
        dragStart = nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Observe descendants too, including the native editor inside TextField.
        window?.contentView?.addGestureRecognizer(pan)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        dragStart = nil
        guard let window, event.window === window, window.isMovable,
              window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor,
              event.type == .leftMouseDown,
              bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) else { return false }
        dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        return true
    }

    @objc private func didPan(_ gesture: NSPanGestureRecognizer) {
        updateDrag(state: gesture.state, pointer: NSEvent.mouseLocation)
    }

    func updateDrag(state: NSGestureRecognizer.State, pointer: NSPoint) {
        guard let window, let start = dragStart else { return }
        switch state {
        case .began, .changed, .ended:
            // Screen coordinates avoid feedback/jitter as the window moves
            // underneath the pointer, and work across multiple displays.
            window.setFrameOrigin(NSPoint(x: start.origin.x + pointer.x - start.pointer.x,
                                          y: start.origin.y + pointer.y - start.pointer.y))
            if state == .ended { dragStart = nil }
        case .cancelled, .failed:
            dragStart = nil
        default:
            break
        }
    }
}
