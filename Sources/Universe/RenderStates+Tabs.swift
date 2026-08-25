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
        ]
    }
}
