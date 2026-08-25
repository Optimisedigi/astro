import Foundation

/// Persists task lists as individual JSON files in Application Support.
@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published private(set) var taskLists: [TaskList] = []

    private init() { loadAll() }

    func loadAll() {
        do {
            let dir = try Self.directory()
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            taskLists = files.compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? decoder.decode(TaskList.self, from: $0) }
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            taskLists = []
        }
    }

    func save(_ list: TaskList) {
        var list = list
        list.updatedAt = Date()
        do {
            let dir = try Self.directory()
            let url = dir.appendingPathComponent("\(list.id.uuidString).json")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(list).write(to: url, options: .atomic)
            if let i = taskLists.firstIndex(where: { $0.id == list.id }) {
                taskLists[i] = list
            } else {
                taskLists.insert(list, at: 0)
            }
            taskLists.sort { $0.updatedAt > $1.updatedAt }
        } catch {}
    }

    func delete(id: UUID) {
        do {
            let dir = try Self.directory()
            try FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
            taskLists.removeAll { $0.id == id }
        } catch {}
    }

    func createList(title: String) -> TaskList {
        let list = TaskList(title: title, items: [])
        save(list)
        return list
    }

    func addItem(to listID: UUID, title: String) {
        guard let i = taskLists.firstIndex(where: { $0.id == listID }) else { return }
        taskLists[i].items.append(TaskItem(title: title))
        save(taskLists[i])
    }

    func toggleItem(listID: UUID, itemID: UUID) {
        guard let li = taskLists.firstIndex(where: { $0.id == listID }),
              let ii = taskLists[li].items.firstIndex(where: { $0.id == itemID }) else { return }
        taskLists[li].items[ii].isCompleted.toggle()
        save(taskLists[li])
    }

    func deleteItem(listID: UUID, itemID: UUID) {
        guard let li = taskLists.firstIndex(where: { $0.id == listID }) else { return }
        taskLists[li].items.removeAll { $0.id == itemID }
        save(taskLists[li])
    }

    /// Groups by date: Today / This Week / This Month / Older.
    func grouped() -> [(label: String, lists: [TaskList])] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let week = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? today
        let month = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? today

        var buckets: [(String, [TaskList])] = []
        let t = taskLists.filter { $0.updatedAt >= today }
        let w = taskLists.filter { $0.updatedAt >= week && $0.updatedAt < today }
        let m = taskLists.filter { $0.updatedAt >= month && $0.updatedAt < week }
        let o = taskLists.filter { $0.updatedAt < month }
        if !t.isEmpty { buckets.append(("Today", t)) }
        if !w.isEmpty { buckets.append(("This Week", w)) }
        if !m.isEmpty { buckets.append(("This Month", m)) }
        if !o.isEmpty { buckets.append(("Older", o)) }
        return buckets
    }

    private static func directory() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Universe/tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
