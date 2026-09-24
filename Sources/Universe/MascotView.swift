import SwiftUI
import ThinkingOrbsKit

/// Pause state for the input-bar orb. The orb itself never changes: it is
/// always the same design, whatever the assistant is doing.
@MainActor
final class MascotController: ObservableObject {
    static let shared = MascotController()

    /// True while the panel is hidden, so the orb stops drawing frames.
    @Published private(set) var isPaused = false

    private init() {}

    func pause() { isPaused = true }

    func resume() { isPaused = false }

    /// The undulating multi-band sash (the library's `composing` design),
    /// chosen by the user from a screenshot. The other designs are unused.
    static let orbState: OrbState = .composing
}

/// The animated orb in the input bar, where the mascot used to be.
struct MascotBadge: View {
    @ObservedObject var controller = MascotController.shared

    var body: some View {
        // The 64 pt design (chat-avatar scale), drawn at 40 pt to fit the row.
        ThinkingOrb(state: MascotController.orbState, size: .px64, theme: .dark,
                    paused: controller.isPaused, displaySize: 40)
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }
}
