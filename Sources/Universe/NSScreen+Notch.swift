import AppKit

extension NSScreen {
    /// Whether this screen has a hardware notch (e.g. MacBook Pro 2021+).
    var hasNotch: Bool {
        auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// How far the wings tuck *under* the notch shape. Small overlap, so adjacent
    /// UI meets the black cutout with no seam of wallpaper between them.
    static let notchTuck: CGFloat = 4

    /// Width used for the virtual notch on displays with no hardware notch.
    private static let fallbackNotchWidth: CGFloat = 200

    /// The size wings and overlay shapes anchor to: the drawn notch plus a small
    /// tuck so they slide underneath it.
    ///
    /// Derived from `exactNotchSize` rather than recomputed. When the two carried
    /// independent fallbacks (220 here, 200 there) every wing on a non-notch
    /// display sat 10pt clear of the black box it was supposed to touch.
    var notchSize: NSSize {
        let exact = exactNotchSize
        return NSSize(width: exact.width + Self.notchTuck, height: exact.height)
    }

    /// The exact size of the notch as actually drawn — the hardware cutout on a
    /// notched Mac, or the virtual notch overlay elsewhere.
    var exactNotchSize: NSSize {
        if let leftPadding = auxiliaryTopLeftArea?.width,
           let rightPadding = auxiliaryTopRightArea?.width
        {
            let width = frame.width - leftPadding - rightPadding
            let height = safeAreaInsets.top
            return NSSize(width: width, height: max(height, NSStatusBar.system.thickness))
        }
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        return NSSize(width: Self.fallbackNotchWidth,
                      height: max(menuBarHeight, NSStatusBar.system.thickness))
    }

    /// The frame of the hardware notch in screen coordinates, positioned at top-center.
    var notchFrame: NSRect {
        let size = notchSize
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
