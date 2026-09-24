import SwiftUI
import ThinkingOrbsKit

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
            State("input-row", size: CGSize(width: 680, height: 60)) {
                HStack(spacing: 10) {
                    MascotBadge()
                    Text("Ask anything…")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    Image(systemName: "mic").foregroundStyle(.secondary)
                }
                .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 24))
                .frame(width: 680, height: 58)
                .environment(\.colorScheme, .dark)
                .background(Color.black.opacity(0.85))
                .orbFrozenTime(1.3)
            },
            // A live voice call mid-sentence: your words in the box as if typed,
            // red mic, minimise button and "Live voice" header.
            State("panel-live-call", size: CGSize(width: 700, height: 580)) {
                let open = ChatState()
                let _ = open.showAsOpenForRendering()
                ChatView(state: open, live: .forRendering([
                    Session.Message(role: "user", text: "What's your name?"),
                    Session.Message(role: "assistant", text: "I'm Astro. What can I do for you?"),
                ], draft: "What's the weather going to be like in Sydney"))
                    .orbFrozenTime(1.3)
                    .beamFrozenTime(1.0)
                    .frame(width: 700, height: 580)
                    .background(Color.black)
            },
            // The real panel: orb and input row on top, the tabs box below with
            // the border beam on its edge. ImageRenderer skips the text field and
            // list contents. Beam frames need the Xcode build (its shader is
            // compiled there); `swift build` renders no beam.
            State("panel-beam", size: CGSize(width: 700, height: 580)) {
                let open = ChatState()
                let _ = open.showAsOpenForRendering()
                ChatView(state: open)
                    .orbFrozenTime(1.3)
                    .beamFrozenTime(1.0)
                    .frame(width: 700, height: 580)
                    .background(Color.black)
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
