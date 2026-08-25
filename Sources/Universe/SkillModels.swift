import Foundation

/// A reusable prompt template stored as a Markdown file with YAML frontmatter.
struct Skill: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var content: String
    var source: Source
    var createdAt: Date
    var updatedAt: Date

    enum Source: String, Codable { case global, project }
}

/// Parses a skill Markdown file with optional YAML frontmatter.
enum SkillParser {
    static func parse(content: String, source: Skill.Source, filename: String) -> Skill {
        var name = ""
        var description = ""
        var body = content

        if content.hasPrefix("---"),
           let end = content[content.index(content.startIndex, offsetBy: 3)...].range(of: "---") {
            let frontmatter = String(content[content.index(content.startIndex, offsetBy: 3)..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(content[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for line in frontmatter.components(separatedBy: "\n") {
                if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if key == "name" { name = value }
                    else if key == "description" { description = value }
                }
            }
        }
        if name.isEmpty { name = filename.replacingOccurrences(of: ".md", with: "") }
        return Skill(id: UUID(), name: name, description: description, content: body,
                     source: source, createdAt: Date(), updatedAt: Date())
    }
}
