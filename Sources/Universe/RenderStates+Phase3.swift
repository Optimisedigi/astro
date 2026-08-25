import SwiftUI

/// Settings-sheet states asserted by `--render-states`.
@MainActor
extension RenderStates {
    private static func sheet<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    static var phase3States: [State] {
        let state = ChatState()
        return [
            State("topbar", size: CGSize(width: 420, height: 44)) {
                sheet { TopBar(title: "Claude Sonnet 5", hasSchedules: true) }
            },
            State("permissions-granted", size: CGSize(width: 420, height: 560)) {
                sheet {
                    PermissionsBody(checker: PermissionsChecker(fixed: [
                        .accessibility: .granted, .fullDisk: .granted, .microphone: .granted,
                        .speech: .granted, .appManagement: .granted, .screenRecording: .granted,
                        .notifications: .granted, .browser: .ready("Google Chrome detected."),
                    ]))
                }
            },
            State("permissions-mixed", size: CGSize(width: 420, height: 560)) {
                sheet {
                    PermissionsBody(checker: PermissionsChecker(fixed: [
                        .accessibility: .granted, .fullDisk: .denied, .microphone: .granted,
                        .speech: .unknown, .appManagement: .denied, .screenRecording: .denied,
                        .notifications: .granted, .browser: .ready("Safari detected."),
                    ]))
                }
            },
            State("ai-settings", size: CGSize(width: 420, height: 560)) {
                sheet { AISettingsBody(registry: ModelRegistry.shared, login: state.login) }
            },
            State("voice-settings", size: CGSize(width: 420, height: 560)) {
                sheet { VoiceSettingsBody(state: state) }
            },
        ]
    }
}
