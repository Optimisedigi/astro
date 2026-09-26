import AppKit

extension SelfTest {
    @MainActor
    static func checkWindowDragging(_ check: (Bool, String) -> Void) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let region = WindowDragView(frame: NSRect(x: 0, y: 142, width: 400, height: 58))
        let input = NSTextField(frame: NSRect(x: 50, y: 151, width: 280, height: 40))
        let button = NSButton(frame: NSRect(x: 340, y: 151, width: 40, height: 40))
        content.addSubview(input)
        content.addSubview(button)
        content.addSubview(region)
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content

        guard let pan = content.gestureRecognizers.first as? NSPanGestureRecognizer else {
            check(false, "window drag: the input region installs a native pan recognizer")
            return
        }
        check(!pan.delaysPrimaryMouseButtonEvents,
              "window drag: normal clicks are not delayed")
        check(content.hitTest(NSPoint(x: 100, y: 170)) === input
                && content.hitTest(NSPoint(x: 360, y: 170)) === button,
              "window drag: clicks still reach the input and buttons under the region")
        check(region.registeredDraggedTypes.isEmpty,
              "window drag: incoming image drops remain with the hosting view")

        func press(_ point: NSPoint, type: NSEvent.EventType = .leftMouseDown) -> Bool {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            return region.gestureRecognizer(pan, shouldAttemptToRecognizeWith: event)
        }
        for x: CGFloat in [10, 100, 200, 360, 395] {
            check(press(NSPoint(x: x, y: 170)),
                  "window drag: accepts the input section at x=\(Int(x)), including text and buttons")
        }
        // AppKit's visibleRect can extend beyond an unclipped view's bounds.
        check(!press(NSPoint(x: 100, y: 80)), "window drag: content below the input section does not move the window")
        check(!press(NSPoint(x: 100, y: 170), type: .rightMouseDown),
              "window drag: right-click is not a window drag")
        region.isHidden = true
        check(!press(NSPoint(x: 100, y: 170)), "window drag: a hidden region is inactive")
        region.isHidden = false

        let location = NSPoint(x: 100, y: 170)
        let origin = window.frame.origin
        let pointer = window.convertPoint(toScreen: location)
        check(press(location) && window.frame.origin == origin,
              "window drag: pressing alone leaves the window in place")
        region.updateDrag(state: .began, pointer: NSPoint(x: pointer.x + 8, y: pointer.y + 3))
        region.updateDrag(state: .changed, pointer: NSPoint(x: pointer.x + 80, y: pointer.y + 30))
        check(window.frame.origin == NSPoint(x: origin.x + 80, y: origin.y + 30),
              "window drag: moves the real window by the screen-space pointer delta without drift")
        region.updateDrag(state: .ended, pointer: NSPoint(x: pointer.x + 90, y: pointer.y + 35))
        let finalOrigin = window.frame.origin
        region.updateDrag(state: .changed, pointer: .zero)
        check(finalOrigin == NSPoint(x: origin.x + 90, y: origin.y + 35) && window.frame.origin == finalOrigin,
              "window drag: release keeps the final position and ends movement")

        check(press(location), "window drag: another drag can begin")
        region.updateDrag(state: .cancelled, pointer: .zero)
        region.updateDrag(state: .changed, pointer: .zero)
        check(window.frame.origin == finalOrigin, "window drag: cancellation clears movement")

        check(press(location), "window drag: teardown starts with an active drag")
        region.removeFromSuperview()
        region.updateDrag(state: .changed, pointer: .zero)
        check(content.gestureRecognizers.isEmpty && window.frame.origin == finalOrigin,
              "window drag: teardown removes the recognizer and cannot move a stale window")
    }
}
