import Foundation

/// Long-term memory, modelled on pocket-agent's `facts` + `soul` tables.
///
/// Two deliberately separate stores:
/// - **Facts** — things that are true about the user (name, projects, preferences).
/// - **Soul** — what the assistant has learned about *working with* this user
///   (communication corrections, boundaries, tone). Not facts about them.
///
/// Both are injected into every system prompt under a hard character budget, so
/// memory can never grow into an unbounded token bill. pocket-agent uses SQLite
/// plus embeddings for semantic top-k retrieval; this is the same data model and
/// the same budgets, with importance ordering instead of embeddings.
///
/// simplification: sorted-by-importance truncation, not semantic retrieval. Fine
/// while the store is small (~150 facts); revisit if it grows past the budget
/// often enough that the wrong facts start getting dropped.
@MainActor
final class MemoryStore: ObservableObject {
    // MARK: - Models

    struct Fact: Codable, Identifiable, Equatable {
        var id = UUID()
        /// user_info, preferences, projects, people, work, notes, decisions
        var category: String
        /// Specific key, e.g. "partner_name" — not a broad bucket like "family".
        var subject: String
        var content: String
        /// Higher sorts first when the budget forces truncation.
        var importance: Int = 5
        /// Private or emotionally heavy (health, relationships, finances).
        /// Still remembered, but never proactively raised unprompted.
        var sensitive: Bool = false
        var createdAt = Date()
        var updatedAt = Date()
    }

    struct SoulAspect: Codable, Identifiable, Equatable {
        var id = UUID()
        /// e.g. "communication_style", "boundaries", "relationship"
        var aspect: String
        var content: String
        var createdAt = Date()
        var updatedAt = Date()
    }

    // MARK: - Budgets

    /// Character budget for facts injected into the system prompt (~1,000 tokens).
    static let factsCharBudget = 3000
    /// Character budget for soul aspects in the prompt (~500 tokens).
    static let soulCharBudget = 1500
    /// Budget for the fact *store* on disk. Larger than the injection budget
    /// because only the top slice is ever sent.
    static let factsStoreBudget = 15000

    static let shared = MemoryStore()

    @Published private(set) var facts: [Fact] = []
    @Published private(set) var soul: [SoulAspect] = []

    /// The rendered prompt block, recomputed only when something changes.
    private var contextCache: String?

    private let storageURL: URL

    nonisolated static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Universe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }

    /// `storageURL` is injectable so tests get a throwaway file — a test store
    /// pointed at the real path would wipe the user's memory on the first save.
    init(storageURL: URL = MemoryStore.defaultStorageURL()) {
        self.storageURL = storageURL
        load()
    }

    // MARK: - Facts

    /// Saves a fact, replacing any existing one with the same category+subject.
    /// Returns a short confirmation for the tool result.
    @discardableResult
    func saveFact(category: String, subject: String, content: String,
                  importance: Int = 5, sensitive: Bool = false) -> String {
        let key = { (f: Fact) in
            f.category.caseInsensitiveCompare(category) == .orderedSame
                && f.subject.caseInsensitiveCompare(subject) == .orderedSame
        }
        if let index = facts.firstIndex(where: key) {
            facts[index].content = content
            facts[index].importance = importance
            facts[index].sensitive = sensitive
            facts[index].updatedAt = Date()
        } else {
            facts.append(Fact(category: category, subject: subject, content: content,
                              importance: importance, sensitive: sensitive))
        }
        didChange()
        return "Remembered: \(subject)"
    }

    /// Deletes by subject (what the agent knows); returns false if nothing matched.
    @discardableResult
    func forgetFact(subject: String) -> Bool {
        let before = facts.count
        facts.removeAll { $0.subject.caseInsensitiveCompare(subject) == .orderedSame }
        guard facts.count != before else { return false }
        didChange()
        return true
    }

    func deleteFact(_ fact: Fact) {
        facts.removeAll { $0.id == fact.id }
        didChange()
    }

    /// Substring search over subject and content, for the `recall` tool.
    func searchFacts(query: String) -> [Fact] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return facts.filter {
            $0.subject.lowercased().contains(q)
                || $0.content.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
        }
        .sorted { $0.importance > $1.importance }
    }

    // MARK: - Soul

    @discardableResult
    func setSoulAspect(aspect: String, content: String) -> String {
        if let index = soul.firstIndex(where: { $0.aspect.caseInsensitiveCompare(aspect) == .orderedSame }) {
            soul[index].content = content
            soul[index].updatedAt = Date()
        } else {
            soul.append(SoulAspect(aspect: aspect, content: content))
        }
        didChange()
        return "Soul updated: \(aspect)"
    }

    @discardableResult
    func deleteSoulAspect(aspect: String) -> Bool {
        let before = soul.count
        soul.removeAll { $0.aspect.caseInsensitiveCompare(aspect) == .orderedSame }
        guard soul.count != before else { return false }
        didChange()
        return true
    }

    func deleteSoulAspect(_ aspect: SoulAspect) {
        soul.removeAll { $0.id == aspect.id }
        didChange()
    }

    // MARK: - Prompt injection

    /// The memory block appended to the system prompt. Empty when nothing is
    /// stored, so a fresh install sends no extra tokens.
    func promptContext() -> String {
        if let contextCache { return contextCache }
        var blocks: [String] = []
        if let f = factsBlock() { blocks.append(f) }
        if let s = soulBlock() { blocks.append(s) }
        let result = blocks.joined(separator: "\n\n")
        contextCache = result
        return result
    }

    /// Facts grouped by category, highest importance first, truncated to budget.
    private func factsBlock() -> String? {
        guard !facts.isEmpty else { return nil }
        let ordered = facts.sorted {
            $0.importance != $1.importance ? $0.importance > $1.importance : $0.updatedAt > $1.updatedAt
        }

        let header = "## Known Facts"
        var used = header.count
        var byCategory: [(String, [Fact])] = []

        for fact in ordered {
            let line = "- \(fact.subject): \(fact.content)"
            let existing = byCategory.firstIndex { $0.0 == fact.category }
            let categoryHeader = existing == nil ? "\n### \(fact.category)\n".count : 0
            let cost = categoryHeader + line.count + 1
            if used + cost > Self.factsCharBudget { break }
            used += cost
            if let existing {
                byCategory[existing].1.append(fact)
            } else {
                byCategory.append((fact.category, [fact]))
            }
        }
        guard !byCategory.isEmpty else { return nil }

        var lines = [header]
        for (category, categoryFacts) in byCategory {
            lines.append("\n### \(category)")
            for fact in categoryFacts {
                // Sensitive facts are marked so the model keeps them out of
                // unprompted conversation — it may still use them when asked.
                let mark = fact.sensitive ? " (sensitive — do not raise unprompted)" : ""
                lines.append("- \(fact.subject): \(fact.content)\(mark)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func soulBlock() -> String? {
        guard !soul.isEmpty else { return nil }
        let header = "## Soul\nWhat you have learned about working with this user:"
        var used = header.count
        var lines = [header]
        for aspect in soul.sorted(by: { $0.aspect < $1.aspect }) {
            let entry = "\n### \(aspect.aspect)\n\(aspect.content)"
            if used + entry.count > Self.soulCharBudget { break }
            used += entry.count
            lines.append(entry)
        }
        guard lines.count > 1 else { return nil }
        return lines.joined(separator: "\n")
    }

    /// How full the fact store is, for a settings-pane indicator.
    var factsStoreUsage: (usedChars: Int, budget: Int, pct: Int) {
        let used = facts.reduce(0) { $0 + $1.subject.count + $1.content.count + 4 }
        return (used, Self.factsStoreBudget,
                Int((Double(used) / Double(Self.factsStoreBudget) * 100).rounded()))
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var facts: [Fact]
        var soul: [SoulAspect]
    }

    private func didChange() {
        contextCache = nil
        save()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL),
              let payload = try? decoder.decode(Payload.self, from: data) else { return }
        facts = payload.facts
        soul = payload.soul
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Payload(facts: facts, soul: soul)) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    /// Wipes everything — used by the settings pane and the self-test.
    func removeAll() {
        facts = []
        soul = []
        didChange()
    }
}
