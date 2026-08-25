import SwiftUI

/// Tab bar states asserted by `--render-states`.
@MainActor
extension RenderStates {
    static var tabStates: [State] {
        [
            State("tab-bar", size: CGSize(width: 420, height: 44)) {
                AnimatedTabBar(tabs: [
                    .init(id: "chat", label: "Chat", symbol: "bubble.left"),
                    .init(id: "tasks", label: "Tasks", symbol: "checklist"),
                    .init(id: "routines", label: "Routines", symbol: "clock"),
                    .init(id: "skills", label: "Skills", symbol: "wand.and.stars"),
                ], selectedIndex: .constant(0))
                .background(Color(nsColor: .windowBackgroundColor))
            },
            State("tasks-empty", size: CGSize(width: 420, height: 400)) {
                TaskListView(store: {
                    let store = TaskStore.shared
                    // Clear for render-state determinism
                    for list in store.taskLists { store.delete(id: list.id) }
                    return store
                }())
                .background(Color(nsColor: .windowBackgroundColor))
            },
            State("tasks-with-items", size: CGSize(width: 420, height: 400)) {
                TaskListDetailView(
                    list: TaskList(title: "Groceries", items: [
                        TaskItem(title: "Oat milk", isCompleted: true),
                        TaskItem(title: "Sourdough"),
                        TaskItem(title: "Avocados"),
                    ]),
                    store: TaskStore.shared,
                    onBack: {}
                )
                .background(Color(nsColor: .windowBackgroundColor))
            },
            State("routines-empty", size: CGSize(width: 420, height: 400)) {
                RoutineListView(store: ScheduleStore.shared)
                    .background(Color(nsColor: .windowBackgroundColor))
            },
            State("skills-empty", size: CGSize(width: 420, height: 400)) {
                SkillListView(store: SkillStore.shared)
                    .background(Color(nsColor: .windowBackgroundColor))
            },
            State("sessions-empty", size: CGSize(width: 420, height: 400)) {
                SessionListView(store: SessionStore.shared, onSelectSession: { _ in }, onDeleteSession: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor))
            },
            // ScrollView bodies don't rasterise offscreen; gate the rows directly.
            State("tools-rows", size: CGSize(width: 420, height: 200)) {
                VStack(spacing: 0) {
                    ForEach(PanelToolRegistry.shared.allTools, id: \.id) { tool in
                        PanelToolRow(tool: tool, tick: 0, onTap: {}, onToggled: {})
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            },
            State("clipboard-rows", size: CGSize(width: 420, height: 200)) {
                VStack(spacing: 0) {
                    ClipboardRow(entry: ClipboardEntry(
                        id: UUID(), timestamp: Date(), contentType: .text,
                        textContent: "swift build && ./install.sh", imageData: nil, fileURL: nil,
                        sourceAppName: "Terminal", sourceAppBundle: "com.apple.Terminal"), onCopy: {}, onDelete: {})
                    ClipboardRow(entry: ClipboardEntry(
                        id: UUID(), timestamp: Date(), contentType: .fileURL,
                        textContent: nil, imageData: nil, fileURL: "/Users/Pe/Documents/report.pdf",
                        sourceAppName: "Finder", sourceAppBundle: "com.apple.finder"), onCopy: {}, onDelete: {})
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            },
        ]
    }
}
