import SwiftUI

/// Onboarding states asserted by `--render-states`.
@MainActor
extension RenderStates {
    static var onboardingStates: [State] {
        [
            State("onboarding-step1-required", size: CGSize(width: 420, height: 560)) {
                OnboardingView(model: OnboardingModel(fixed: [
                    .accessibility: .denied,
                    .fullDisk: .denied,
                    .microphone: .granted,
                    .speech: .granted,
                    .appManagement: .granted,
                    .screenRecording: .granted,
                    .notifications: .granted,
                    .browser: .ready("Google Chrome detected."),
                ]))
            },
            State("onboarding-step2-optional", size: CGSize(width: 420, height: 560)) {
                OnboardingView(model: {
                    let m = OnboardingModel(fixed: [
                        .accessibility: .granted,
                        .fullDisk: .granted,
                        .microphone: .granted,
                        .speech: .granted,
                        .appManagement: .denied,
                        .screenRecording: .granted,
                        .notifications: .granted,
                        .browser: .ready("Safari detected."),
                    ])
                    m.currentStep = 0 // App Management is the only outstanding, and it's optional
                    return m
                }())
            },
            State("onboarding-complete", size: CGSize(width: 420, height: 560)) {
                OnboardingView(model: {
                    let m = OnboardingModel(fixed: [
                        .accessibility: .granted,
                        .fullDisk: .granted,
                        .microphone: .granted,
                        .speech: .granted,
                        .appManagement: .granted,
                        .screenRecording: .granted,
                        .notifications: .granted,
                        .browser: .ready("Google Chrome detected."),
                    ])
                    // All granted → goes straight to complete
                    return m
                }())
            },
        ]
    }
}
