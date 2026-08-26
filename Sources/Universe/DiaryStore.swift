import Foundation

/// One dated diary page, holding every entry written on that day.
struct DiaryDay: Codable, Identifiable, Equatable {
    /// `yyyy-MM-dd` — also the filename, so a date lookup is just a path.
    let date: String
    var entries: [DiaryEntry]

    var id: String { date }
}

struct DiaryEntry: Codable, Identifiable, Equatable {
    var id: UUID = .init()
    var text: String
    var createdAt: Date = .init()
}

/// Persists the diary as one JSON file per day in Application Support.
///
/// Deliberately isolated from the agent: nothing here is exposed as a tool and
/// nothing is rendered into the prompt, so diary contents are never sent to a
/// model. The date is the filename, so lookup by day needs no index.
@MainActor
final class DiaryStore: ObservableObject {
    static let shared = DiaryStore()

    /// Newest day first.
    @Published private(set) var days: [DiaryDay] = []

    /// Cap on a single entry, so one runaway dictation cannot write an
    /// unbounded file.
    static let maxEntryChars = 10000

    private let directory: URL

    /// Injectable so tests never touch the real diary.
    init(directory: URL = DiaryStore.defaultDirectory()) {
        self.directory = directory
        loadAll()
    }

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Universe/diary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `yyyy-MM-dd` in the user's own timezone, so "today" means their today.
    /// POSIX locale keeps the format stable regardless of region settings.
    static func key(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func loadAll() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        days = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(DiaryDay.self, from: $0) }
            .sorted { $0.date > $1.date }
    }

    /// Appends an entry to the given day's page, creating it if needed.
    @discardableResult
    func addEntry(_ text: String, on date: Date = Date()) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let entry = DiaryEntry(text: String(trimmed.prefix(Self.maxEntryChars)))

        // Write first, then commit to memory. The other way round, a failed
        // write left the entry on screen but not on disk — and because the UI
        // keeps the draft on failure, retrying would have stored it twice.
        let key = Self.key(for: date)
        if let index = days.firstIndex(where: { $0.date == key }) {
            var day = days[index]
            day.entries.append(entry)
            guard write(day) else { return false }
            days[index] = day
            return true
        }
        let day = DiaryDay(date: key, entries: [entry])
        guard write(day) else { return false }
        days.append(day)
        days.sort { $0.date > $1.date }
        return true
    }

    func updateEntry(dayKey: String, entryID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let dayIndex = days.firstIndex(where: { $0.date == dayKey }),
              let entryIndex = days[dayIndex].entries.firstIndex(where: { $0.id == entryID })
        else { return }
        days[dayIndex].entries[entryIndex].text = String(trimmed.prefix(Self.maxEntryChars))
        write(days[dayIndex])
    }

    func deleteEntry(dayKey: String, entryID: UUID) {
        guard let dayIndex = days.firstIndex(where: { $0.date == dayKey }) else { return }
        days[dayIndex].entries.removeAll { $0.id == entryID }

        // An empty page is removed entirely rather than left as a blank day.
        if days[dayIndex].entries.isEmpty {
            let day = days.remove(at: dayIndex)
            try? FileManager.default.removeItem(at: fileURL(for: day.date))
        } else {
            write(days[dayIndex])
        }
    }

    /// The page for a given day, or nil if nothing was written.
    func day(for date: Date) -> DiaryDay? {
        days.first { $0.date == Self.key(for: date) }
    }

    // MARK: - Persistence

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    @discardableResult
    private func write(_ day: DiaryDay) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(day).write(to: fileURL(for: day.date), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
