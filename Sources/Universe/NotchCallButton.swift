import AppKit
import os

private let logger = Logger(
    subsystem: "com.universe.app",
    category: "callbutton"
)

/// A persistent call button that extends seamlessly from the left side of the hardware notch.
///
/// The button is drawn as a compact black wing shape (icon-only) whose right edge is flush
/// with the notch, making it appear as a natural left-side extension of the notch itself.
/// Shows a white phone icon when idle and a red disconnect icon while a call is active.
/// Uses a non-activating `NSPanel` so it never steals focus.
@MainActor
enum NotchCallButton {
    // MARK: - State

    private static var panel: NSPanel?
    private static var shapeLayer: CAShapeLayer?
    private static var hoverLayer: CALayer?
    private static var isVisible = false
    private(set) static var isInCall = false
    private static var labelField: NSTextField?
    private static var pencilField: NSTextField?
    private static var keyboardField: NSTextField?

    /// The live voice call, or nil when idle. Held for the duration of the call
    /// so `endCall()` can shut the same session down.
    private static var callSession: (any VoiceCallSession)?

    /// Whether the panel is temporarily hidden because a notch overlay is active.
    private static var isHiddenByOverlay = false

    // MARK: - Constants

    /// Width of the wing extension. Sized to fit three icons plus corner
    /// curvature with comfortable padding on the left where the bottom-corner
    /// flare lives.
    private static let wingWidth: CGFloat = 122

    /// Width of each icon's slot. Left to right: pencil, phone, keyboard; the
    /// click zones divide on the boundaries between them.
    private static let iconSlotWidth: CGFloat = 30

    /// Where the first icon slot starts, clear of the bottom-left flare.
    private static let iconLeftPadding: CGFloat = bottomCornerRadius + 6

    /// What a click at `x` within the wing does.
    enum WingAction: Equatable { case diary, call, typing }

    /// The pencil and phone own their slots; everything from the keyboard's slot
    /// rightward, including the area tucked under the notch, opens typing.
    static func wingAction(atX x: CGFloat) -> WingAction {
        if x < iconLeftPadding + iconSlotWidth { return .diary }
        if x < iconLeftPadding + iconSlotWidth * 2 { return .call }
        return .typing
    }

    /// The panel is wider than the visible wing: the extra runs to the right,
    /// tucking under the notch's bottom flare. Because `windowWidth` and
    /// `notchOverlap` grow together, the left edge and the icon stay put.
    private static let windowWidth: CGFloat =
        wingWidth + NotchShapePath.defaultBottomCornerRadius

    /// Top corner radius on the left side (matches notch curvature).
    private static let topCornerRadius: CGFloat = 6

    /// How far the wing slides under the notch cutout.
    ///
    /// The notch shape's straight left side is inset from its own bounding box by
    /// `topCornerRadius` — only the very top edge reaches x=0. Meeting the boxes
    /// edge-to-edge therefore left a visible strip of wallpaper down the join.
    /// Overlap past that inset (plus a hair for subpixel rounding); both shapes
    /// are opaque black, so the overlap itself is invisible.
    ///
    /// Four parts: half the tuck (the anchor sits that far left of the drawn
    /// box), the notch's own corner inset, its bottom flare, and 1pt of slack.
    ///
    /// The bottom flare matters because the notch's bottom corners curve inward:
    /// covering only the top inset left an uncovered wedge under that curve.
    private static let notchOverlap: CGFloat =
        NSScreen.notchTuck / 2
            + NotchShapePath.defaultTopCornerRadius
            + NotchShapePath.defaultBottomCornerRadius
            + 1

    /// Exposed so the self-test can assert the wing actually reaches the notch's
    /// solid edge rather than stopping at its bounding box.
    static var notchOverlapForTests: CGFloat { notchOverlap }

    /// Bottom corner radius (matching notch aesthetic).
    private static let bottomCornerRadius: CGFloat = 10

    private static let expandDuration: TimeInterval = 0.4
    private static let collapseDuration: TimeInterval = 0.25

    // MARK: - Public API

    /// Show the call button joined to the notch.
    static func show() {
        guard !isVisible else { return }
        guard let screen = NSScreen.main else { return }

        logger.info("Showing call button")
        isVisible = true

        let notchSize = screen.notchSize
        let screenFrame = screen.frame

        // Wing is exactly the same height as the notch.
        let wingHeight = notchSize.height
        let windowHeight = wingHeight

        // Position: overlap into the notch so the wing blends seamlessly.
        let notchLeftX = screenFrame.midX - notchSize.width / 2
        let originX = notchLeftX - windowWidth + notchOverlap
        let originY = screenFrame.maxY - windowHeight

        // The panel runs past the wing and across the notch, so a screenshot can
        // be dropped anywhere on the black bar. Nothing extra is drawn there:
        // the notch draws itself, this only catches the drag. It stops exactly
        // at the notch's right edge — any further and it would swallow clicks on
        // the menu bar items beyond it.
        let panelWidth = windowWidth - notchOverlap + notchSize.width

        let newPanel = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: panelWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        // One level above the virtual notch: the two overlap where the wing
        // stretches under the notch, and the drag has to reach this panel rather
        // than stopping at the notch drawn on top of it.
        newPanel.level = .mainMenu + 3
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.isMovableByWindowBackground = false
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        newPanel.appearance = NSAppearance(named: .darkAqua)

        // Flipped root view (y=0 at top) — same pattern as NotchActivityIndicator.
        let rootView = FlippedCallButtonView(
            frame: NSRect(x: 0, y: 0, width: panelWidth, height: windowHeight)
        )
        rootView.wantsLayer = true
        // Not clear: AppKit drops mouse and drag events on fully transparent
        // parts of a non-opaque window, so the stretch across the notch — which
        // draws nothing of its own — would let every drag fall straight through.
        // A hair of alpha is invisible but makes the whole bar a real target.
        rootView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor

        // Shape layer: black wing joined to notch.
        let shape = CAShapeLayer()
        shape.fillColor = NSColor.black.cgColor

        let wingRect = CGRect(x: 0, y: 0, width: windowWidth, height: wingHeight)
        shape.path = leftWingPath(in: wingRect)
        shape.frame = rootView.bounds
        rootView.layer?.addSublayer(shape)

        // 1px bridge at the top-right to eliminate subpixel gap with hardware notch.
        let bridgeLayer = CALayer()
        bridgeLayer.backgroundColor = NSColor.black.cgColor
        bridgeLayer.frame = CGRect(
            x: wingRect.maxX - 1,
            y: 0,
            width: 2,
            height: wingHeight
        )
        rootView.layer?.addSublayer(bridgeLayer)

        // Hover highlight layer (clipped to the wing shape).
        let hover = CAShapeLayer()
        hover.path = shape.path
        hover.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
        hover.opacity = 0
        hover.frame = rootView.bounds
        rootView.layer?.addSublayer(hover)

        // Three icons in the wing's body: pencil (diary), phone (call), then
        // keyboard (type a question). The bottom-left flare (bottomCornerRadius)
        // visually pulls weight to the left, so all are offset rightward.
        let labelHeight: CGFloat = 18
        let labelY = (wingHeight - labelHeight) / 2

        let pencil = makeSymbolLabel("pencil", description: "Write a diary entry")
        pencil.frame = NSRect(
            x: iconLeftPadding,
            y: labelY,
            width: iconSlotWidth,
            height: labelHeight
        )
        pencil.alphaValue = 0
        rootView.addSubview(pencil)
        pencilField = pencil

        let label = makeLabel()
        label.frame = NSRect(
            x: iconLeftPadding + iconSlotWidth,
            y: labelY,
            width: iconSlotWidth,
            height: labelHeight
        )
        // Start with label invisible for fade-in.
        label.alphaValue = 0
        rootView.addSubview(label)
        labelField = label

        let keyboard = makeSymbolLabel("keyboard", description: "Type a question")
        keyboard.frame = NSRect(
            x: iconLeftPadding + iconSlotWidth * 2,
            y: labelY,
            width: iconSlotWidth,
            height: labelHeight
        )
        keyboard.alphaValue = 0
        rootView.addSubview(keyboard)
        keyboardField = keyboard

        // Click overlay.
        let overlay = CallButtonOverlay(frame: rootView.bounds)
        overlay.autoresizingMask = [.width, .height]
        // Clicks and hover belong to the wing only; the stretch over the notch
        // exists purely so a drop lands there too.
        //
        // Cost of that stretch: `VirtualNotch` passes clicks through, but this
        // panel sits above it and does not, so clicks on the notch strip are
        // swallowed instead of reaching the menu bar underneath. Accepted
        // because the strip is drawn to look like a hardware notch, which is not
        // clickable either. A drop needs a real window there — there is no way to
        // take drags without taking clicks.
        overlay.interactiveWidth = windowWidth
        overlay.enableImageDrops()
        rootView.addSubview(overlay)

        newPanel.contentView = rootView
        newPanel.orderFrontRegardless()

        panel = newPanel
        shapeLayer = shape
        hoverLayer = hover

        // Animate wing expanding from notch edge.
        animateExpand(shapeLayer: shape, hoverLayer: hover, label: label, wingHeight: wingHeight)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                reposition()
            }
        }

        // Hide when notch overlays appear, restore when they clear.
        NotificationCenter.default.addObserver(
            forName: .notchOverlayActive,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in hideForOverlay() }
        }
        NotificationCenter.default.addObserver(
            forName: .notchOverlayInactive,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in showAfterOverlay() }
        }

        // If an overlay is already active, hide immediately.
        if NotchOverlayTracker.isActive {
            hideForOverlay()
        }
    }

    /// Hide and tear down the call button with a collapse animation.
    static func hide() {
        guard isVisible else { return }
        logger.info("Hiding call button")
        isVisible = false

        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(self, name: .notchOverlayActive, object: nil)
        NotificationCenter.default.removeObserver(self, name: .notchOverlayInactive, object: nil)
        isHiddenByOverlay = false

        if isInCall {
            isInCall = false
            NotchCallTimer.hide()
        }

        guard let panel, let shapeLayer else {
            teardown()
            return
        }

        // Fade out both icons immediately.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            labelField?.animator().alphaValue = 0
            pencilField?.animator().alphaValue = 0
            keyboardField?.animator().alphaValue = 0
        }

        // Collapse shape back to notch edge.
        let wingHeight = panel.frame.height
        let collapsedPath = collapsedWingPath(wingHeight: wingHeight)

        let pathAnimation = CASpringAnimation(keyPath: "path")
        pathAnimation.fromValue = shapeLayer.path
        pathAnimation.toValue = collapsedPath
        pathAnimation.damping = 18
        pathAnimation.stiffness = 220
        pathAnimation.mass = 1.0
        pathAnimation.initialVelocity = 0
        pathAnimation.duration = pathAnimation.settlingDuration
        pathAnimation.isRemovedOnCompletion = false
        pathAnimation.fillMode = .forwards
        shapeLayer.add(pathAnimation, forKey: "collapsePath")
        shapeLayer.path = collapsedPath

        // After collapse, fade out and remove.
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    teardown()
                }
            }
        }
    }

    /// Temporarily hide the call button panel while a notch overlay is active.
    private static func hideForOverlay() {
        guard isVisible, !isHiddenByOverlay else { return }
        isHiddenByOverlay = true
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        if isInCall { NotchCallTimer.hideForOverlay() }
    }

    /// Restore the call button panel after notch overlays clear, with expand animation.
    private static func showAfterOverlay() {
        guard isVisible, isHiddenByOverlay else { return }
        isHiddenByOverlay = false

        guard let panel, let shapeLayer else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Re-run the expand animation so it slides in cleanly.
        let wingHeight = panel.frame.height
        if let label = labelField, let hoverLayer {
            label.alphaValue = 0
            pencilField?.alphaValue = 0
            keyboardField?.alphaValue = 0
            animateExpand(shapeLayer: shapeLayer, hoverLayer: hoverLayer, label: label, wingHeight: wingHeight)
        }

        if isInCall { NotchCallTimer.showAfterOverlay() }
    }

    private static func teardown() {
        panel?.orderOut(nil)
        panel = nil
        shapeLayer = nil
        hoverLayer = nil
        labelField = nil
        pencilField = nil
        keyboardField = nil
    }

    /// Called when the button is tapped. `x` is the click position within the
    /// wing, which decides whether the pencil, phone or keyboard was hit.
    fileprivate static func handleTap(atX x: CGFloat) {
        ButtonSound.shared.play()

        switch wingAction(atX: x) {
        case .diary:
            openDiary()
        case .typing:
            logger.info("Typing requested from the notch")
            PanelController.shared.openForTyping()
        case .call:
            if isInCall {
                endCall()
            } else {
                startCall()
            }
        }
    }

    /// Open the diary and start dictating — no agent, no model.
    private static func openDiary() {
        logger.info("Diary dictation requested from the notch")
        PanelController.shared.openDiaryDictation()
    }

    /// True while the permission prompt is up. `isInCall` is still false then,
    /// so without this a second click would stack another request.
    private static var isRequestingPermission = false

    /// Begin a call — switch icon to red disconnect, show the timer wing, and start the voice session.
    /// `stillWanted` is re-checked after the permission prompt, so a call the
    /// user no longer wants (the panel that asked for it was closed) never starts.
    /// Returns false only when nothing was started or queued.
    @discardableResult
    private static func startCall(greets: Bool = true, stillWanted: @escaping @MainActor () -> Bool = { true }) -> Bool {
        // Without the microphone the call would greet the user and then listen
        // to nothing, which looks like a hung call. Ask first, and only commit
        // to the call once access is granted.
        guard VoiceService.isAlreadyAuthorized else {
            guard !isRequestingPermission else { return false }
            isRequestingPermission = true
            logger.info("Call requested without microphone access — requesting")
            Task { @MainActor in
                let granted = await VoiceService.shared.requestPermissions()
                isRequestingPermission = false
                guard granted else {
                    logger.warning("Microphone denied — cannot start call")
                    PanelController.shared.openSheet(.permissions)
                    return
                }
                guard stillWanted(), !isInCall else {
                    logger.info("Call no longer wanted after permission prompt")
                    return
                }
                beginCall(greets: greets)
            }
            return true
        }
        beginCall(greets: greets)
        return true
    }

    private static func beginCall(greets: Bool) {
        logger.info("Call started")
        isInCall = true
        updateLabel(disconnect: true)
        NotchCallTimer.show()

        let session = RealtimeVoiceSettings.shared.makeCallSession(greets: greets)
        callSession = session
        LiveVoiceState.shared.setActive(!(session is CallSession))
        session.start()
    }

    /// Start a live call from the panel (shortcut or mic button). No greeting:
    /// the user opened the panel to talk. `stillWanted` is checked again if a
    /// permission prompt delays the start. Returns false when nothing started
    /// (a call is already running or a permission prompt is already up).
    @discardableResult
    static func startCallFromPanel(stillWanted: @escaping @MainActor () -> Bool) -> Bool {
        guard !isInCall else { return false }
        return startCall(greets: false, stillWanted: stillWanted)
    }

    /// End a call — revert icon to white phone, hide the timer wing, and stop the voice session.
    static func endCall() {
        logger.info("Call ended")
        isInCall = false
        isHiddenByOverlay = false
        updateLabel(disconnect: false)
        NotchCallTimer.hide()

        // Show the button panel if it was hidden by an overlay (e.g. tool indicator).
        if let panel, panel.parent == nil, isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        callSession?.end()
        callSession = nil
        LiveVoiceState.shared.setActive(false)
    }

    /// Update the icon and tint based on call state.
    private static func updateLabel(disconnect: Bool) {
        guard let labelField else { return }
        labelField.attributedStringValue = makeIconString(disconnect: disconnect)
    }

    /// Light the whole wing green while an image is held over it, so the drop
    /// target is unmistakable before the user lets go. Restores the ordinary
    /// white hover tint afterwards.
    static func setDropHighlight(_ active: Bool) {
        // The notch is a separate panel, so it has to be tinted alongside the
        // wing for the whole bar to read as one drop target.
        VirtualNotch.setDropHighlight(active)
        if let hover = hoverLayer as? CAShapeLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hover.fillColor = active
                ? VirtualNotch.dropTint.cgColor
                : NSColor.white.withAlphaComponent(0.08).cgColor
            CATransaction.commit()
        }
        setHovered(active)
    }

    /// Show hover highlight.
    fileprivate static func setHovered(_ hovered: Bool) {
        guard let hoverLayer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = hoverLayer.opacity
        animation.toValue = hovered ? Float(1.0) : Float(0)
        animation.duration = 0.15
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        hoverLayer.add(animation, forKey: "hover")
        hoverLayer.opacity = hovered ? 1.0 : 0
    }

    // MARK: - Animation

    /// A thin sliver path at the notch-touching (right) edge — the starting state for expand.
    private static func collapsedWingPath(wingHeight: CGFloat) -> CGPath {
        let tr = topCornerRadius
        let rect = CGRect(x: windowWidth - tr - 2, y: 0, width: tr + 2, height: wingHeight)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - tr))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private static func animateExpand(
        shapeLayer: CAShapeLayer,
        hoverLayer: CALayer,
        label: NSTextField,
        wingHeight: CGFloat
    ) {
        let collapsedPath = collapsedWingPath(wingHeight: wingHeight)
        let expandedPath = leftWingPath(in: CGRect(x: 0, y: 0, width: windowWidth, height: wingHeight))

        // Start from collapsed.
        shapeLayer.path = collapsedPath
        if let hoverShape = hoverLayer as? CAShapeLayer {
            hoverShape.path = collapsedPath
        }

        // Spring animate to full wing.
        let pathAnimation = CASpringAnimation(keyPath: "path")
        pathAnimation.fromValue = collapsedPath
        pathAnimation.toValue = expandedPath
        pathAnimation.damping = 14
        pathAnimation.stiffness = 180
        pathAnimation.mass = 1.0
        pathAnimation.initialVelocity = 0
        pathAnimation.duration = pathAnimation.settlingDuration
        pathAnimation.isRemovedOnCompletion = false
        pathAnimation.fillMode = .forwards
        shapeLayer.add(pathAnimation, forKey: "expandPath")
        shapeLayer.path = expandedPath

        // Also animate the hover layer shape.
        if let hoverShape = hoverLayer as? CAShapeLayer {
            let hoverPathAnim = CASpringAnimation(keyPath: "path")
            hoverPathAnim.fromValue = collapsedPath
            hoverPathAnim.toValue = expandedPath
            hoverPathAnim.damping = 14
            hoverPathAnim.stiffness = 180
            hoverPathAnim.mass = 1.0
            hoverPathAnim.initialVelocity = 0
            hoverPathAnim.duration = hoverPathAnim.settlingDuration
            hoverPathAnim.isRemovedOnCompletion = false
            hoverPathAnim.fillMode = .forwards
            hoverShape.add(hoverPathAnim, forKey: "expandPath")
            hoverShape.path = expandedPath
        }

        // Fade both icons in after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                label.animator().alphaValue = 1.0
                pencilField?.animator().alphaValue = 1.0
                keyboardField?.animator().alphaValue = 1.0
            }
        }
    }

    // MARK: - Positioning

    private static func reposition() {
        guard isVisible, let panel, let screen = NSScreen.main else { return }
        let notchSize = screen.notchSize
        let screenFrame = screen.frame
        let windowHeight = notchSize.height
        let notchLeftX = screenFrame.midX - notchSize.width / 2
        let originX = notchLeftX - windowWidth + notchOverlap
        let originY = screenFrame.maxY - windowHeight
        // Same stretch across the notch as at creation, so the drop target still
        // covers the whole bar after a display change.
        let panelWidth = windowWidth - notchOverlap + notchSize.width
        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: windowHeight), display: true)
    }

    // MARK: - Wing Path

    /// Generates a path for the left wing shape that joins the notch on its right edge.
    ///
    /// The right side body is inset by `topCornerRadius`, then flares out to the full
    /// width at both top and bottom — the same quad-curve wing pattern used by
    /// `NotchShapePath` for its top corners. This makes the wing look like a seamless
    /// extension of the hardware notch.
    ///
    /// ```
    /// ──────────────┐  ← flat top at full width (flush with notch)
    /// ╲            ╱   ← top-left & top-right: inward quad curves (wing flare)
    /// │          │     ← body: sides inset by topCornerRadius
    /// ╰────────╲       ← bottom-left: outward curve, bottom-right: inward quad curve (wing flare)
    ///           ┘      ← bottom at full width (flush with notch)
    /// ```
    static func leftWingPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let tr = topCornerRadius
        let br = bottomCornerRadius

        // Start at top-left corner (flat top edge).
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top edge → right at full width (flush with notch).
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // Right side straight down at full width. The wing butts directly into
        // the notch cutout, so any inward flare here would show as a seam of
        // wallpaper between the two black shapes.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))

        // Bottom edge ← left.
        path.addLine(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY))

        // Bottom-left corner: outward curve.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.maxY - br),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )

        // Left side straight up to the top-left corner area.
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr))

        // Top-left corner: inward quad curve (matches notch curvature).
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }

    // MARK: - Label

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithAttributedString: makeIconString(disconnect: false))
        label.alignment = .center
        return label
    }

    /// A wing icon (the diary pencil, the keyboard), drawn to match the phone
    /// icon's weight and colour.
    private static func makeSymbolLabel(_ symbolName: String, description: String) -> NSTextField {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let attachment = NSTextAttachment()
        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        )?.withSymbolConfiguration(config) {
            attachment.image = image
        }
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(
            [.foregroundColor: NSColor.white.withAlphaComponent(0.9)],
            range: NSRange(location: 0, length: string.length)
        )
        let label = NSTextField(labelWithAttributedString: string)
        label.alignment = .center
        return label
    }

    /// Build the attributed icon string. Idle: white phone. In-call: red disconnect.
    private static func makeIconString(disconnect: Bool) -> NSAttributedString {
        let symbolName = disconnect ? "phone.down.fill" : "phone.fill"
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let iconAttachment = NSTextAttachment()
        if let iconImage = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: disconnect ? "Disconnect" : "Call"
        )?
            .withSymbolConfiguration(iconConfig)
        {
            iconAttachment.image = iconImage
        }
        let iconColor: NSColor = disconnect
            ? NSColor.systemRed
            : NSColor.white.withAlphaComponent(0.9)
        let iconString = NSMutableAttributedString(attachment: iconAttachment)
        iconString.addAttributes(
            [.foregroundColor: iconColor],
            range: NSRange(location: 0, length: iconString.length)
        )
        return iconString
    }
}

// MARK: - Flipped View

private final class FlippedCallButtonView: NSView {
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        return layer
    }
}

// MARK: - Click / Hover Overlay

/// Internal rather than private so the self-test can drive a real drop through
/// the same view the notch wing installs.
final class CallButtonOverlay: NSView {
    private var trackingArea: NSTrackingArea?

    /// How much of the view responds to clicks and hover. The view is wider than
    /// this — it stretches across the notch to catch drops — but the notch is not
    /// a button, so pointer handling stops at the wing's edge.
    var interactiveWidth: CGFloat?

    private var interactiveRect: NSRect {
        guard let interactiveWidth else { return bounds }
        return NSRect(x: 0, y: 0, width: min(interactiveWidth, bounds.width), height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: interactiveRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        NSCursor.pointingHand.push()
        NotchCallButton.setHovered(true)
    }

    override func mouseExited(with _: NSEvent) {
        NSCursor.pop()
        NotchCallButton.setHovered(false)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The stretch across the notch is a drop target, not a button. Clicks
        // there do nothing rather than starting a call.
        guard interactiveRect.contains(point) else { return }
        NotchCallButton.handleTap(atX: point.x)
    }

    // MARK: - Dropping a screenshot on the wing

    /// Drop an image here and it is staged on the next message: the panel opens
    /// with the picture attached and its text already read out.
    func enableImageDrops() {
        registerForDraggedTypes(ImageAttachmentLoader.draggedTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ImageAttachmentLoader.containsImage(sender.draggingPasteboard) else { return [] }
        NotchCallButton.setDropHighlight(true)
        return .copy
    }

    /// Without this the drag goes dead after the first moment inside the view,
    /// and the drop never arrives — `draggingEntered` alone is not enough.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ImageAttachmentLoader.containsImage(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_: NSDraggingInfo?) {
        NotchCallButton.setDropHighlight(false)
    }

    override func draggingEnded(_: NSDraggingInfo) {
        NotchCallButton.setDropHighlight(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ImageAttachmentLoader.containsImage(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        NotchCallButton.setDropHighlight(false)
        // The drag pasteboard dies with this call, so copy the bytes out now and
        // do the decoding, shrinking and text recognition afterwards.
        let payloads = ImageAttachmentLoader.payloads(from: sender.draggingPasteboard)
        if !payloads.isEmpty {
            CallButtonOverlay.stage(payloads)
            return true
        }

        // Nothing readable yet: this is a promised file, which is how a
        // screenshot dragged from its corner thumbnail arrives. The sender
        // writes it for us, then we attach it.
        let receivers = ImageAttachmentLoader.promiseReceivers(from: sender.draggingPasteboard)
        guard !receivers.isEmpty else {
            logger.warning("Drop contained no usable image")
            return false
        }
        // Not captured weakly on purpose: the wing can collapse (and this view
        // go away) between the drop and the promised file arriving, and the
        // image must still be attached.
        ImageAttachmentLoader.fulfill(receivers) { payloads in
            guard !payloads.isEmpty else {
                logger.warning("Promised drop delivered no usable image")
                return
            }
            CallButtonOverlay.stage(payloads)
        }
        return true
    }

    private static func stage(_ payloads: [ImageAttachmentLoader.Payload]) {
        Task { @MainActor in
            let attachments = await ImageAttachmentLoader.attachments(from: payloads)
            guard !attachments.isEmpty else {
                logger.warning("Drop contained no usable image")
                return
            }
            PanelController.shared.openWithAttachments(attachments)
        }
    }
}
