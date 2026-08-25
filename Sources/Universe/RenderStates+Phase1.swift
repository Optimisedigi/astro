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
            State("chat-streaming", size: CGSize(width: 420, height: 300)) {
                panel {
                    MessageListView(
                        messages: [user("Explain the agent loop"), assistant("The loop streams a turn, runs any tools the model asked for, then feeds the")],
                        isStreaming: true
                    )
                }
            },
            State("chat-thinking", size: CGSize(width: 420, height: 260)) {
                panel {
                    MessageListView(messages: [user("Summarise DESIGN.md"), assistant("")], isStreaming: true)
                }
            },
            State("chat-code-block", size: CGSize(width: 420, height: 380)) {
                panel {
                    MessageListView(messages: [assistant("""
                    Here is the shape of it:

                    ```swift
                    func send(_ text: String) async throws {
                        let reply = try await client.stream(text) // one turn
                        print("done: \\(reply.count)")
                    }
                    ```
                    """)])
                }
            },
            State("chat-table", size: CGSize(width: 420, height: 300)) {
                panel {
                    MessageListView(messages: [assistant("""
                    | Gate | Command |
                    |---|---|
                    | Build | swift build |
                    | Logic | --selftest |
                    | UI | --render-states |
                    """)])
                }
            },
            State("chat-checklist", size: CGSize(width: 420, height: 300)) {
                panel {
                    MessageListView(messages: [assistant("""
                    ### Phase 1

                    - [x] Markdown scanner
                    - [x] Streaming text
                    - [ ] Tool rows

                    > Everything else waits for phase 2.
                    """)])
                }
            },
            State("chat-tools-running", size: CGSize(width: 420, height: 320)) {
                panel {
                    MessageListView(
                        messages: [user("Fix the failing test"), assistant("")],
                        toolRuns: [
                            ToolRun(id: "1", name: "read", detail: "Sources/Universe/SelfTest.swift", status: .done),
                            ToolRun(id: "2", name: "bash", detail: "swift test --filter Markdown", status: .failed),
                            ToolRun(id: "3", name: "edit", detail: "Sources/Universe/MarkdownRenderer.swift"),
                        ],
                        isStreaming: true
                    )
                }
            },
            State("chat-error", size: CGSize(width: 420, height: 260)) {
                panel {
                    MessageListView(
                        messages: [user("What's the weather?"), assistant("")],
                        errorMessage: "The request timed out after 60 seconds.",
                        retry: {}
                    )
                }
            },
            State("chat-long-content") {
                panel {
                    MessageListView(messages: [assistant(String(repeating: "Long answers keep wrapping inside the bubble rather than clipping or overflowing the panel. ", count: 8))])
                }
            },
        ]
    }
}
