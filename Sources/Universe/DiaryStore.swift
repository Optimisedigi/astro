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
    /// The coloured marker picked from the entry's dot, if any. Optional, so
    /// entries saved before markers existed still load.
    var highlight: JournalHighlight?
}

/// Markers for journal entries, with Pile's default names and colours.
enum JournalHighlight: String, Codable, CaseIterable, Identifiable {
    case highlight, doLater, newIdea

    var id: String { rawValue }

    var name: String {
        switch self {
        case .highlight: "Highlight"
        case .doLater: "Do later"
        case .newIdea: "New idea"
        }
    }

    /// sRGB components of Pile's #FF703A, #4DE64D and #017AFF.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .highlight: (1.0, 0.439, 0.227)
        case .doLater: (0.302, 0.902, 0.302)
        case .newIdea: (0.004, 0.478, 1.0)
        }
    }
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
        // A page absent from memory may have failed to decode. Never replace
        // its on-disk bytes with an apparently new day; the UI keeps the draft
        // when saving fails, so the original file can be recovered separately.
        guard !FileManager.default.fileExists(atPath: fileURL(for: key).path) else { return false }
        let day = DiaryDay(date: key, entries: [entry])
        guard write(day) else { return false }
        days.append(day)
        days.sort { $0.date > $1.date }
        return true
    }

    @discardableResult
    func updateEntry(dayKey: String, entryID: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let dayIndex = days.firstIndex(where: { $0.date == dayKey }),
              let entryIndex = days[dayIndex].entries.firstIndex(where: { $0.id == entryID })
        else { return false }
        var updated = days[dayIndex]
        updated.entries[entryIndex].text = String(trimmed.prefix(Self.maxEntryChars))
        guard write(updated) else { return false }
        days[dayIndex] = updated
        return true
    }

    /// Sets or clears an entry's marker. Commit to memory only once it is on
    /// disk, so a failed write cannot make an unsaved marker look saved.
    @discardableResult
    func setHighlight(dayKey: String, entryID: UUID, highlight: JournalHighlight?) -> Bool {
        guard let dayIndex = days.firstIndex(where: { $0.date == dayKey }),
              let entryIndex = days[dayIndex].entries.firstIndex(where: { $0.id == entryID })
        else { return false }
        var day = days[dayIndex]
        day.entries[entryIndex].highlight = highlight
        guard write(day) else { return false }
        days[dayIndex] = day
        return true
    }

    /// Applies an asynchronous format result only to the exact saved text it
    /// formatted. A concurrent edit or deletion leaves the user's work alone.
    @discardableResult
    func updateEntry(dayKey: String, entryID: UUID, text: String, ifUnchangedFrom original: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = days.firstIndex(where: { $0.date == dayKey }),
              let entryIndex = days[index].entries.firstIndex(where: { $0.id == entryID }),
              days[index].entries[entryIndex].text == original else { return false }
        var updated = days[index]
        updated.entries[entryIndex].text = String(trimmed.prefix(Self.maxEntryChars))
        guard write(updated) else { return false }
        days[index] = updated
        return true
    }

    @discardableResult
    func deleteEntry(dayKey: String, entryID: UUID) -> Bool {
        guard let dayIndex = days.firstIndex(where: { $0.date == dayKey }),
              let entryIndex = days[dayIndex].entries.firstIndex(where: { $0.id == entryID }) else { return false }
        var updated = days[dayIndex]
        updated.entries.remove(at: entryIndex)

        // An empty page is removed entirely rather than left as a blank day.
        // Keep the entry visible if removing its file fails.
        if updated.entries.isEmpty {
            do { try FileManager.default.removeItem(at: fileURL(for: dayKey)) }
            catch { return false }
            days.remove(at: dayIndex)
        } else {
            guard write(updated) else { return false }
            days[dayIndex] = updated
        }
        return true
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
