import Foundation

/// Memory and soul tools, ported from pocket-agent's `memory-tools.ts` and
/// `soul-tools.ts`. Tool names and descriptions are kept close to the originals
/// so model behaviour carries over.

private func requiredParam(_ input: [String: Any], _ key: String) throws -> String {
    guard let value = input[key] as? String, !value.isEmpty else { throw ToolError.missingParam(key) }
    return value
}

struct RememberTool: AgentTool {
    let name = "remember"
    let description = """
    Save a fact to long-term memory. Keep each fact atomic (under 30 words, one piece of \
    info per call). Use specific keys like "partner_name" not "family". Save proactively when \
    the user shares something meaningful. If the user asks you NOT to remember something, do \
    not save it. For private or emotionally heavy facts (health, relationships, finances), save \
    with sensitive: true so they are never proactively brought up.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "category": ["type": "string",
                         "description": "Category: user_info, preferences, projects, people, work, notes, decisions"],
            "subject": ["type": "string",
                        "description": "Specific, descriptive key (e.g. \"partner_name\", \"coffee_preference\")"],
            "content": ["type": "string",
                        "description": "The fact to remember (max 25-30 words, one piece of info only)"],
            "importance": ["type": "integer",
                           "description": "1-10, higher survives truncation when memory is full. Default 5."],
            "sensitive": ["type": "boolean",
                          "description": "True for private facts (health, relationships, finances). Remembered but never raised unprompted."],
        ],
        "required": ["category", "subject", "content"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let category = try requiredParam(input, "category")
        let subject = try requiredParam(input, "subject")
        let content = try requiredParam(input, "content")
        let importance = input["importance"] as? Int ?? 5
        let sensitive = input["sensitive"] as? Bool ?? false
        return await MainActor.run {
            MemoryStore.shared.saveFact(
                category: category, subject: subject, content: content,
                importance: min(max(importance, 1), 10), sensitive: sensitive
            )
        }
    }
}

struct ForgetTool: AgentTool {
    let name = "forget"
    let description = "Remove a fact from long-term memory by its subject key. Use when the user asks you to forget something or a fact is no longer true."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "subject": ["type": "string", "description": "The subject key of the fact to forget"],
        ],
        "required": ["subject"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let subject = try requiredParam(input, "subject")
        return await MainActor.run {
            MemoryStore.shared.forgetFact(subject: subject)
                ? "Forgot: \(subject)"
                : "No fact found with subject '\(subject)'"
        }
    }
}

struct RecallTool: AgentTool {
    let name = "recall"
    let description = "Search long-term memory for facts matching a query. The most important facts are already in your context — use this to look up older or more specific details."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "What to search for"],
        ],
        "required": ["query"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let query = try requiredParam(input, "query")
        let matches = await MainActor.run { MemoryStore.shared.searchFacts(query: query) }
        guard !matches.isEmpty else { return "No matching facts." }
        return matches.map { "[\($0.category)] \($0.subject): \($0.content)" }.joined(separator: "\n")
    }
}

struct SoulSetTool: AgentTool {
    let name = "soul_set"
    let description = """
    Record what you learn about working with this user. Not facts about them, but about your \
    dynamic together: communication corrections, frustrations, boundaries, working style.
    """
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "aspect": ["type": "string",
                       "description": "Name of the aspect (e.g. \"communication_style\", \"boundaries\", \"relationship\")"],
            "content": ["type": "string", "description": "The content/description of this aspect"],
        ],
        "required": ["aspect", "content"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let aspect = try requiredParam(input, "aspect")
        let content = try requiredParam(input, "content")
        return await MainActor.run { MemoryStore.shared.setSoulAspect(aspect: aspect, content: content) }
    }
}

struct SoulDeleteTool: AgentTool {
    let name = "soul_delete"
    let description = "Delete a soul aspect that is no longer relevant."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "aspect": ["type": "string", "description": "Name of the aspect to delete"],
        ],
        "required": ["aspect"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let aspect = try requiredParam(input, "aspect")
        return await MainActor.run {
            MemoryStore.shared.deleteSoulAspect(aspect: aspect)
                ? "Deleted soul aspect: \(aspect)"
                : "No soul aspect named '\(aspect)'"
        }
    }
}
