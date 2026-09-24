import SwiftUI

/// First-run onboarding: walks through each permission Universe needs, one step at a time.
///
/// The flow is driven by `PermissionsChecker`, so the steps are always in sync with
/// what the app actually needs. Optional rows can be skipped; required ones must be
/// granted before the user can continue.
///
/// The `hasCompletedOnboarding` flag is persisted in UserDefaults so the sheet only
/// shows once. It can be reset by deleting the app or by calling
/// `OnboardingModel.reset()` (used by the selftest).
@MainActor
final class OnboardingModel: ObservableObject {
    static let defaultsKey = "universe.hasCompletedOnboarding"

    @Published var currentStep = 0
    @Published private(set) var isComplete = false

    let checker: PermissionsChecker
    /// Only the permissions that are not yet satisfied.
    private(set) var outstanding: [PermissionsChecker.Permission] = []

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    init(checker: PermissionsChecker? = nil) {
        self.checker = checker ?? PermissionsChecker()
        rebuildOutstanding()
    }

    /// For `--render-states`: inject a fixed checker so the view is deterministic.
    init(fixed: [PermissionsChecker.Kind: PermissionsChecker.Status]) {
        self.checker = PermissionsChecker(fixed: fixed)
        rebuildOutstanding()
    }

    func rebuildOutstanding() {
        outstanding = checker.outstanding
        // If everything is already satisfied, skip straight to done.
        if outstanding.isEmpty { complete() }
    }

    var currentPermission: PermissionsChecker.Permission? {
        guard currentStep < outstanding.count else { return nil }
        return outstanding[currentStep]
    }

    var isLastStep: Bool { currentStep >= outstanding.count - 1 }

    /// Grant the current permission (opens System Settings or triggers a request).
    func grantCurrent() {
        guard let permission = currentPermission else { return }
        checker.grant(permission.kind)
    }

    /// Skip the current step — only allowed for optional permissions.
    func skipCurrent() {
        guard let permission = currentPermission, permission.optional else { return }
        advance()
    }

    /// Move to the next step, or finish if we're at the end.
    func advance() {
        if isLastStep {
            complete()
        } else {
            currentStep += 1
        }
    }

    /// Mark onboarding as done and persist the flag.
    func complete() {
        isComplete = true
        UserDefaults.standard.set(true, forKey: Self.defaultsKey)
    }

    /// Reset the onboarding flag — used by the selftest and by a debug action.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onDone: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isComplete {
                completeState
            } else {
                stepContent
            }
        }
        .frame(width: 420, height: 560)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack {
            Text("Welcome to Astro")
                .font(.headline)
            Spacer()
            Text("Step \(model.currentStep + 1) of \(model.outstanding.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stepContent: some View {
        if let permission = model.currentPermission {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: symbol(for: permission.kind))
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)

                Text(permission.title)
                    .font(.title2.bold())

                Text(permission.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                Spacer()

                VStack(spacing: 10) {
                    Button(action: { model.grantCurrent(); model.advance() }) {
                        Text(buttonLabel(for: permission))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if permission.optional {
                        Button("Skip for now") { model.skipCurrent() }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
        }
    }

    private var completeState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.green)

            Text("You're all set")
                .font(.title2.bold())

            Text("Astro is ready. You can change permissions anytime from the menubar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Spacer()

            Button("Start using Astro", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 24)
        }
    }

    private func symbol(for kind: PermissionsChecker.Kind) -> String {
        switch kind {
        case .accessibility: return "hand.raised"
        case .fullDisk: return "folder"
        case .microphone: return "mic"
        case .speech: return "waveform"
        case .appManagement: return "app.badge"
        case .screenRecording: return "rectangle.dashed"
        case .notifications: return "bell"
        case .browser: return "globe"
        }
    }

    private func buttonLabel(for permission: PermissionsChecker.Permission) -> String {
        switch permission.status {
        case .denied: return permission.optional ? "Get" : "Grant"
        case .unknown: return "Check"
        case .granted, .ready: return "Continue"
        }
    }
}
