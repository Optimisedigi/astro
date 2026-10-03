import SwiftUI

/// Follows the laid-out transcript, including its bottom padding, rather than
/// scrolling to a bubble before streaming text has finished changing its size.
struct TranscriptScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    private enum Anchor: Hashable {
        case bottom
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content()
                    Color.clear
                        .frame(height: 1)
                        .accessibilityHidden(true)
                        .id(Anchor.bottom)
                }
                .onGeometryChange(for: CGSize.self) { geometry in
                    geometry.size
                } action: { _ in
                    // No repeated animations while words stream in; this also
                    // respects Reduce Motion without delaying the final layout.
                    proxy.scrollTo(Anchor.bottom, anchor: .bottom)
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onGeometryChange(for: CGSize.self) { geometry in
                geometry.size
            } action: { _ in
                // The composer can wrap and shrink the transcript viewport.
                proxy.scrollTo(Anchor.bottom, anchor: .bottom)
            }
        }
    }
}
