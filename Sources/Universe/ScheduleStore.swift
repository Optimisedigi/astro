import Foundation
import UserNotifications

/// Reminders + routines (SPEC.md §3). JSON store at schedules.json, 30s poll timer.
/// Reminders fire macOS notifications; routines run the agent loop and notify with the result.
@MainActor
final class ScheduleStore: ObservableObject {
    struct Job: Codable, Identifiable {
        enum Kind: String, Codable { case reminder, routine }
        var id = UUID()
        var name: String
        var kind: Kind
        var scheduleType: String // "once" | "interval" | "cron"
        var schedule: String     // original schedule expression (for re-arming)
        var message: String      // reminder text or routine prompt
        var nextRun: Date
    }

    static let shared = ScheduleStore()
    @Published private(set) var jobs: [Job] = []
    private var pollTimer: Timer?

    /// Titles of notifications that couldn't be posted because the app is unbundled (selftest only).
    private(set) var deliveredWithoutBundle: [String] = []

    private let storageURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Universe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("schedules.json")
    }()

    func start() {
        load()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fireDue() }
        }
        fireDue()
    }

    // MARK: - CRUD (JSON responses match Tama's tool output format)

    func create(name: String, kind: Job.Kind, schedule: String, message: String) -> String {
        guard let parsed = ScheduleParser.parse(schedule),
              let nextRun = ScheduleParser.nextRun(parsed) else {
            return #"{"error": "Could not parse schedule: \#(schedule)"}"#
        }
        let job = Job(name: name, kind: kind, scheduleType: parsed.scheduleType,
                      schedule: schedule, message: message, nextRun: nextRun)
        jobs.append(job)
        save()
        let formatter = ISO8601DateFormatter()
        return """
        {"success": true, "name": "\(name)", "type": "\(kind.rawValue)", "schedule_type": "\(parsed.scheduleType)", "next_run": "\(formatter.string(from: nextRun))"}
        """
    }

    func list() -> String {
        guard !jobs.isEmpty else { return #"{"schedules": [], "message": "No active schedules."}"# }
        let formatter = ISO8601DateFormatter()
        let items = jobs.map {
            #"{"name": "\#($0.name)", "type": "\#($0.kind.rawValue)", "schedule_type": "\#($0.scheduleType)", "next_run": "\#(formatter.string(from: $0.nextRun))"}"#
        }
        return #"{"schedules": [\#(items.joined(separator: ", "))]}"#
    }

    func delete(name: String) -> String {
        guard let index = jobs.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
            return #"{"success": false, "message": "No schedule found with name '\#(name)'"}"#
        }
        let removed = jobs.remove(at: index)
        save()
        return #"{"success": true, "message": "Deleted schedule '\#(removed.name)'"}"#
    }

    // MARK: - Firing

    /// Fires every due job. Internal (not private) so the selftest can drive it directly.
    func fireDue(now: Date = Date()) {
        // Remove every due job first, then re-append re-armed recurring ones.
        // (Keeping them in place would duplicate the job on each poll and re-fire forever.)
        var fired: [Job] = []
        jobs.removeAll { job in
            guard job.nextRun <= now else { return false }
            fired.append(job)
            return true
        }
        for var job in fired {
            deliver(job)
            // Re-arm recurring jobs; one-shot jobs stay consumed
            if job.scheduleType != "once",
               let parsed = ScheduleParser.parse(job.schedule),
               let next = ScheduleParser.nextRun(parsed, after: now) {
                job.nextRun = next
                jobs.append(job)
            }
        }
        if !fired.isEmpty { save() }
    }

    private func deliver(_ job: Job) {
        switch job.kind {
        case .reminder:
            notify(title: "⏰ \(job.name)", body: job.message)
        case .routine:
            Task { await runRoutine(job) }
        }
    }

    private func runRoutine(_ job: Job) async {
        let systemNote = "You are a helpful assistant running a scheduled routine. Be concise."
        let apiMessages: [[String: Any]] = [[
            "role": "user",
            "content": [["type": "text", "text": "\(systemNote)\n\nRoutine: \(job.message)"]],
        ]]
        var result = ""
        do {
            let workspace = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Universe/Workspace", isDirectory: true)
            let loop = AgentLoop(workspace: workspace)
            try await loop.run(apiMessages: apiMessages, streamProvider: ClaudeService.shared.streamEvents) { delta in
                result += delta
            } onToolActivity: { _ in }
            notify(title: "🔁 \(job.name)", body: String(result.prefix(200)))
        } catch {
            notify(title: "🔁 \(job.name)", body: "Routine failed: \(error.localizedDescription)")
        }
    }

    private func notify(title: String, body: String) {
        // UNUserNotificationCenter requires a bundle identifier; skip when running unbundled (selftest/CLI)
        guard Bundle.main.bundleIdentifier != nil else {
            deliveredWithoutBundle.append(title)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        jobs = (try? decoder.decode([Job].self, from: Data(contentsOf: storageURL))) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
