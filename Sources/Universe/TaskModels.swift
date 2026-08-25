import Foundation

/// A single checkbox item inside a task list.
struct TaskItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var isCompleted: Bool = false
}

/// A named collection of task items, persisted as a JSON file in Application Support.
struct TaskList: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var items: [TaskItem]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var completedCount: Int { items.filter(\.isCompleted).count }
    var totalCount: Int { items.count }
    var progress: Double { totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount) }
}
