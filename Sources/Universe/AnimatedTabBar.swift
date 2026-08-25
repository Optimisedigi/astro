import SwiftUI

/// A custom tab bar with a sliding highlight indicator that animates between tabs.
/// Matches tama-agent's AnimatedTabBar but built in SwiftUI.
struct AnimatedTabBar: View {
    let tabs: [Tab]
    @Binding var selectedIndex: Int

    struct Tab: Identifiable {
        let id: String
        let label: String
        let symbol: String
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedIndex = index
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab.label)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(selectedIndex == index ? Color.white : Color.white.opacity(0.5))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        selectedIndex == index
                            ? Color(white: 0.38)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color(white: 0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}
