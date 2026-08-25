import Foundation
import os

private let logger = Logger(
    subsystem: "com.universe.app",
    category: "test-notifications"
)

/// Cycles through test notification batches when the user presses "Test Notification".
/// Sequence: 1 → 2 → 5 → 1 (clears and restarts).
@MainActor
final class TestNotificationCoordinator {
    static let shared = TestNotificationCoordinator()

    private var currentIndex = 0
    private let batchSizes = [1, 2, 5]

    private init() {}

    /// Fire the next test batch in the sequence.
    func fireNextTest() {
        let batchSize = batchSizes[currentIndex]
        logger.info("Firing test batch: \(batchSize) notifications simultaneously")

        // Clear any existing notifications first for a clean test
        NotchNotificationPresenter.clearAll()

        // Small delay to let the clear happen visually
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }

            let prefix = batchTitle(for: currentIndex)
            NotchNotificationPresenter.showBatch(count: batchSize, prefix: prefix)

            // Advance to next index
            currentIndex = (currentIndex + 1) % batchSizes.count
        }
    }

    /// Get a descriptive title for the batch type.
    private func batchTitle(for index: Int) -> String {
        switch index {
        case 0: "Single"
        case 1: "Double"
        case 2: "Batch"
        default: "Test"
        }
    }
}
