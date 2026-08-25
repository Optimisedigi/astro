import SwiftUI

/// Chat states asserted by `--render-states`.
/// States render the panel's *content* views: ImageRenderer does not rasterise
/// ScrollView contents or TextFields, so registering the whole panel would gate on nothing.
@MainActor
extension RenderStates {
    static func user(_ text: String) -> Session.Message { .init(role: "user", text: text) }
    static func assistant(_ text: String) -> Session.Message { .init(role: "assistant", text: text) }

    private static func panel<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    static var phase1States: [State] {
        [
            State("chat-empty", size: CGSize(width: 420, height: 300)) {
                panel { EmptyChatView() }
            },
            State("chat-conversation") {
                panel {
                    MessageListView(messages: [
                        user("What does this repo do?"),
                        assistant("It is a menubar assistant for macOS. Ask it anything: it can read files, run commands and set reminders for you."),
                    ])
                }
            },
        ]
    }
}
