import SwiftUI

/// Mood icon states asserted by `--render-states`: the full 10-mood sheet at 4x,
/// both animation frames for the animated moods.
@MainActor
extension RenderStates {
    static var moodStates: [State] {
        [
            State("mood-icons", size: CGSize(width: 420, height: 200)) {
                let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(MenuBarMood.Mood.allCases, id: \.rawValue) { mood in
                        VStack(spacing: 2) {
                            Image(nsImage: MenuBarIcon.create(mood: mood, animationFrame: false, size: 36))
                                .renderingMode(.template)
                                .foregroundStyle(.primary)
                            Text(mood.rawValue).font(.system(size: 8))
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor))
            },
        ]
    }
}
