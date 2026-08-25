import SwiftUI

/// Notch-notification states asserted by `--render-states`. The live presenter is
/// AppKit panels (not rasterisable offscreen), so we gate the exact same path
/// geometry and text layout the presenter uses.
@MainActor
extension RenderStates {
    private struct NotchSilhouette: View {
        let width: CGFloat
        let height: CGFloat
        let topRadius: CGFloat
        let bottomRadius: CGFloat
        var title: String?
        var subtitle: String?

        var body: some View {
            ZStack(alignment: .top) {
                Path(NotchShapePath.path(
                    in: CGRect(x: 0, y: 0, width: width, height: height),
                    topCornerRadius: topRadius,
                    bottomCornerRadius: bottomRadius
                ))
                .fill(Color.black)
                if let title {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.top, 34)
                }
            }
            .frame(width: width, height: height)
        }
    }

    static var notchStates: [State] {
        [
            State("notch-collapsed", size: CGSize(width: 220, height: 40)) {
                NotchSilhouette(width: 200, height: 32, topRadius: 6, bottomRadius: 10)
                    .frame(width: 220, height: 40, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
            },
            State("notch-expanded-toast", size: CGSize(width: 400, height: 120)) {
                NotchSilhouette(
                    width: 380, height: 100, topRadius: 14, bottomRadius: 20,
                    title: "⏰ Stand up",
                    subtitle: "Time to stretch your legs — you've been sitting for an hour."
                )
                .frame(width: 400, height: 120, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            },
        ]
    }
}
