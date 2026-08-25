import AppKit
import SwiftUI

#if canImport(RiveRuntime)
import RiveRuntime
#endif

/// The different animation states for the mascot (ported verbatim from tama-agent).
/// Each state maps to inputs on the avatar_pack.riv "avatar" state machine.
enum MascotState: String, CaseIterable {
    /// Default — mascot is idle, gently breathing/blinking.
    case idle
    /// User is typing in the prompt field.
    case typing
    /// Prompt submitted, waiting for AI response.
    case waiting
    /// AI response is streaming in.
    case responding
    /// Mascot is thinking/concerned.
    case thinking
    /// Mascot is happy/pleased.
    case happy
}

#if canImport(RiveRuntime)

/// Drives the Rive avatar's state machine inputs, cycling micro-expressions per
/// state so the mascot never freezes (logic ported from tama-agent's MascotView;
/// ours hosts the Rive view inline in SwiftUI rather than a child window).
@MainActor
final class MascotController: ObservableObject {
    static let shared = MascotController()

    private(set) var currentState: MascotState = .idle
    let riveViewModel: RiveViewModel

    private var cycleTimer: Timer?
    private var typingIdleTimer: Timer?
    private var idleBreathTimer: Timer?
    private var revertTimer: Timer?

    private init() {
        riveViewModel = RiveViewModel(
            fileName: "avatar_pack",
            stateMachineName: "avatar",
            autoPlay: true,
            artboardName: "Avatar 1"
        )
        applyState(.idle)
    }

    func setState(_ state: MascotState) {
        guard state != currentState else { return }
        currentState = state
        applyState(state)
    }

    /// Called on every keystroke — resets the "stopped typing" timer.
    func notifyKeystroke() {
        typingIdleTimer?.invalidate()
        if currentState != .typing {
            setState(.typing)
        }
        // If no keystroke for 1.2s, ease back to idle (matches tama-agent).
        typingIdleTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .typing else { return }
                self.setState(.idle)
            }
        }
    }

    /// Stops the state machine and timers to save GPU/CPU while the panel is hidden.
    func pause() {
        riveViewModel.pause()
        stopAllTimers()
    }

    func resume() {
        riveViewModel.play()
        applyState(currentState)
    }

    // MARK: - State application (cycles ported from tama-agent)

    private func applyState(_ state: MascotState) {
        stopAllTimers()
        switch state {
        case .idle:
            setInputs(happy: false, sad: false)
            startIdleBreathing()
        case .typing:
            startTypingCycle()
        case .waiting:
            startWaitingCycle()
        case .responding:
            startRespondingCycle()
        case .thinking:
            setInputs(happy: false, sad: true)
        case .happy:
            setInputs(happy: true, sad: false)
        }
    }

    private func setInputs(happy: Bool, sad: Bool) {
        riveViewModel.setInput("isHappy", value: happy)
        riveViewModel.setInput("isSad", value: sad)
    }

    /// Idle has periodic subtle micro-expressions to feel alive.
    private func startIdleBreathing() {
        idleBreathTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .idle else { return }
                self.riveViewModel.setInput("isHappy", value: true)
                self.scheduleRevert(delay: 0.4, expectedState: .idle) {
                    $0.setInputs(happy: false, sad: false)
                }
            }
        }
    }

    /// Typing: attentive — brief happy flickers.
    private func startTypingCycle() {
        setInputs(happy: true, sad: false)
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .typing else {
                    self?.cycleTimer?.invalidate()
                    self?.cycleTimer = nil
                    return
                }
                self.riveViewModel.setInput("isHappy", value: false)
                self.scheduleRevert(delay: 0.3, expectedState: .typing) {
                    $0.riveViewModel.setInput("isHappy", value: true)
                }
            }
        }
    }

    /// Waiting: mostly sad, but flickers briefly to look nervous/alive.
    private func startWaitingCycle() {
        setInputs(happy: false, sad: true)
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .waiting else {
                    self?.cycleTimer?.invalidate()
                    self?.cycleTimer = nil
                    return
                }
                self.riveViewModel.setInput("isSad", value: false)
                self.scheduleRevert(delay: 0.4, expectedState: .waiting) {
                    $0.riveViewModel.setInput("isSad", value: true)
                }
            }
        }
    }

    /// Responding: happy, with gentle idle dips so it doesn't freeze.
    private func startRespondingCycle() {
        setInputs(happy: true, sad: false)
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == .responding else {
                    self?.cycleTimer?.invalidate()
                    self?.cycleTimer = nil
                    return
                }
                self.riveViewModel.setInput("isHappy", value: false)
                self.scheduleRevert(delay: 0.5, expectedState: .responding) {
                    $0.riveViewModel.setInput("isHappy", value: true)
                }
            }
        }
    }

    /// Runs a delayed revert only if the mascot is still in the expected state.
    private func scheduleRevert(
        delay: TimeInterval,
        expectedState: MascotState,
        action: @escaping (MascotController) -> Void
    ) {
        revertTimer?.invalidate()
        revertTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentState == expectedState else { return }
                action(self)
            }
        }
    }

    private func stopAllTimers() {
        cycleTimer?.invalidate(); cycleTimer = nil
        typingIdleTimer?.invalidate(); typingIdleTimer = nil
        idleBreathTimer?.invalidate(); idleBreathTimer = nil
        revertTimer?.invalidate(); revertTimer = nil
    }
}

/// The mascot as an inline SwiftUI view for the input bar.
struct MascotBadge: View {
    @ObservedObject var controller = MascotController.shared

    var body: some View {
        controller.riveViewModel.view()
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }
}

#else

/// CLI builds (swift build has no RiveRuntime): a static mascot face keeps the
/// input-bar layout identical, and render-state gates still exercise the layout.
@MainActor
final class MascotController: ObservableObject {
    static let shared = MascotController()
    private(set) var currentState: MascotState = .idle
    private init() {}
    func setState(_ state: MascotState) { currentState = state }
    func notifyKeystroke() { currentState = .typing }
    func pause() {}
    func resume() {}
}

struct MascotBadge: View {
    var body: some View {
        Image(nsImage: MenuBarIcon.create(mood: .afternoon, animationFrame: false, size: 32))
            .renderingMode(.template)
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }
}

#endif
