import AppKit

/// Generates a notch-shaped `CGPath` with configurable corner radii.
///
/// The shape has a flat top edge (flush against the screen top), small quad-curve
/// corners at the top (~6pt, matching the hardware notch curvature), vertical sides,
/// and larger quad-curve corners at the bottom (~14pt). Both radii are configurable
/// to allow smooth animation between a collapsed (notch-sized) and expanded state.
///
/// Path structure:
/// ```
/// ┌──────────────────────────┐  ← flat top
/// │╲                        ╱│  ← small top quad curves (topCornerRadius)
/// │ │                      │ │  ← vertical sides
/// │ │                      │ │
/// │ ╰──────────────────────╯ │  ← large bottom quad curves (bottomCornerRadius)
/// └──────────────────────────┘
/// ```
enum NotchShapePath {
    /// Generate a `CGPath` for the notch shape.
    ///
    /// - Parameters:
    ///   - rect: The bounding rectangle.
    ///   - topCornerRadius: Radius for the tight inner curves at the top (default: 6).
    ///   - bottomCornerRadius: Radius for the wider curves at the bottom (default: 14).
    /// - Returns: A closed `CGPath` representing the notch silhouette.
    static func path(
        in rect: CGRect,
        topCornerRadius: CGFloat = 6,
        bottomCornerRadius: CGFloat = 14
    ) -> CGPath {
        let path = CGMutablePath()

        // Start at top-left corner
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left corner: quad curve curving inward/downward
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )

        // Left side straight down to the bottom-left corner area
        path.addLine(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius)
        )

        // Bottom-left corner: quad curve curving outward
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY)
        )

        // Bottom-right corner: quad curve curving outward
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )

        // Right side straight up to the top-right corner area
        path.addLine(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius)
        )

        // Top-right corner: quad curve curving inward
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )

        // Top edge back to start
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}
