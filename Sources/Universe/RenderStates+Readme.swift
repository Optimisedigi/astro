import SwiftUI

/// Documentation captures use sample content and real content views, never the
/// user's stores, credentials, microphone or network. Run only the `readme` set.
@MainActor
extension RenderStates {
    static func readmeStates(directory: String) -> [State] {
        // Render the journal first: the image-chat example attaches this public sample.
        [
            State("journal-timeline", size: CGSize(width: 640, height: 560)) {
                JournalPreview(contentHeight: 478)
            },
            State("chat", size: CGSize(width: 640, height: 220)) {
                documentationPanel {
                    MessageListView(messages: [
                        user("Help me plan a quiet afternoon of focused work."),
                        assistant("""
                        Start with the one task that matters most:

                        1. Spend 45 minutes on your first draft.
                        2. Take a short break away from the screen.
                        3. Review what you finished and write down tomorrow's next step.
                        """),
                    ])
                }
            },
            State("image-generation", size: CGSize(width: 640, height: 180)) {
                documentationPanel {
                    MessageListView(messages: [user("Make a landscape picture of a colourful nebula."), assistant("")],
                                    toolRuns: [ToolRun(id: "sample-image", name: "generate_image", detail: nil)],
                                    isStreaming: true)
                }
            },
            State("image-chat", size: CGSize(width: 640, height: 380)) {
                let image = ImageAttachment(
                    displayName: "journal-example.png", mediaType: "image/png",
                    path: URL(fileURLWithPath: directory).appendingPathComponent("journal-timeline.png").path,
                    text: "", pixelWidth: 1280, pixelHeight: 1120
                )
                documentationPanel {
                    MessageListView(messages: [
                        .init(role: "user", text: "What ideas are in this journal screenshot?", attachments: [image]),
                        assistant("""
                        The entries explore two ideas:

                        - **Conceptual integrity:** a consistent design matters more than a collection of disconnected features.
                        - **An undercover game:** two teams complete missions in an NPC world, using secret codes to find each other.

                        There's also a reminder to try the game with friends.
                        """),
                    ])
                }
            },
            State("reminders", size: CGSize(width: 640, height: 190)) {
                documentationPanel {
                    VStack(spacing: 0) {
                        Text("Reminders")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        Divider()
                        RoutineRow(job: .init(name: "Take a screen break", kind: .reminder,
                                              scheduleType: "interval", schedule: "every 45 minutes",
                                              message: "Stretch and rest your eyes.",
                                              nextRun: Date(timeIntervalSince1970: 1_790_422_200)),
                                   isRunning: false, onRun: {}, onDelete: {})
                        RoutineRow(job: .init(name: "Write today's journal", kind: .reminder,
                                              scheduleType: "interval", schedule: "every 24 hours",
                                              message: "Capture one highlight from today.",
                                              nextRun: Date(timeIntervalSince1970: 1_790_424_000)),
                                   isRunning: false, onRun: {}, onDelete: {})
                    }
                }
            },
            State("memory", size: CGSize(width: 640, height: 210)) {
                documentationPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Facts").font(.caption).foregroundStyle(.secondary)
                        MemoryRow(title: "Writing preferences", detail: "Use short paragraphs and plain language.",
                                  badge: nil, save: { _ in }, delete: {})
                        Divider()
                        Text("Soul").font(.caption).foregroundStyle(.secondary)
                        MemoryRow(title: "Working together", detail: "Offer one clear next step when planning a task.",
                                  badge: nil, save: { _ in }, delete: {})
                    }
                    .padding(16)
                }
            },
        ]
    }

    private static func documentationPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
            .background(Color(white: 0.11))
    }
}
