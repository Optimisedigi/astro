import Foundation

/// Manages loading, saving, and discovering skills from the workspace's `.gg/skills` directory.
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published private(set) var skills: [Skill] = []

    private init() { loadAll() }

    func loadAll() {
        do {
            let dir = try Self.directory()
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }
            skills = files.compactMap { file in
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return SkillParser.parse(content: content, source: .global, filename: file.lastPathComponent)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch {
            skills = []
        }
    }

    func save(_ skill: Skill) {
        do {
            let dir = try Self.directory()
            let url = dir.appendingPathComponent("\(skill.name).md")
            var lines = ["---", "name: \(skill.name)", "description: \(skill.description)", "---", "", skill.content]
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            if let i = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[i] = skill
            } else {
                skills.append(skill)
                skills.sort { $0.name.lowercased() < $1.name.lowercased() }
            }
        } catch {}
    }

    func delete(id: UUID) {
        guard let skill = skills.first(where: { $0.id == id }) else { return }
        do {
            let dir = try Self.directory()
            try FileManager.default.removeItem(at: dir.appendingPathComponent("\(skill.name).md"))
            skills.removeAll { $0.id == id }
        } catch {}
    }

    func skill(named name: String) -> Skill? {
        skills.first { $0.name.lowercased() == name.lowercased() }
    }

    func search(_ query: String) -> [Skill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return skills }
        return skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    private static func directory() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Universe/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
