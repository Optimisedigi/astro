import SwiftUI

/// SwiftUI mirror of tama-agent's AnimatedTabBar (AppKit): text-only labels,
/// 1×14 dividers between tabs, dark track (white 0.25), sliding highlight pill
/// (white 0.38, radius 6), 14pt semibold, white / 50%-white text, 0.2s ease.
struct AnimatedTabBar: View {
    let labels: [String]
    @Binding var selectedIndex: Int
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 14)
                }
                Button {
                    ButtonSound.shared.play()
                    withAnimation(.easeInOut(duration: 0.2)) { selectedIndex = index }
                } label: {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selectedIndex == index ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if selectedIndex == index {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(white: 0.38))
                                    .matchedGeometryEffect(id: "pill", in: highlight)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}
