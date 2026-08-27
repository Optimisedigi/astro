import Foundation
import os

private let logger = Logger(subsystem: "com.universe.app", category: "tool.knowledge")

/// Searches the anti-social-social-app transcript library and returns raw
/// passages. The answer is written by *this* app's model, not the library's.
struct KnowledgeSearchTool: AgentTool {
    /// UserDefaults key holding the library base URL, e.g. http://localhost:3000
    static let baseURLDefaultsKey = "knowledgeBaseURL"
    /// Keychain account holding the bearer token for /api/library/search.
    static let tokenAccount = "knowledge-search-token"

    let name = "knowledge_search"

    let description = """
        Search the personal transcript and document library (YouTube/X transcripts, \
        uploaded documents) and return the most relevant passages. Use this for \
        questions about videos, talks, or papers the user has saved. When you use \
        a passage, say the answer came from the user's saved library and name the \
        source title, with its [mm:ss] timestamp when one is present, so stored \
        knowledge is never mistaken for your own. Say so plainly when the library \
        had nothing and you are answering from your own knowledge instead.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "question": ["type": "string", "description": "The question to search the library for"],
                "source_filter": [
                    "type": "string",
                    "enum": ["all", "transcript", "upload"],
                    "description": "Restrict to transcripts or uploads (default: all)",
                ],
            ],
            "required": ["question"],
        ]
    }

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        guard let question = input["question"] as? String, !question.isEmpty else {
            throw ToolError.missingParam("question")
        }
        guard let base = UserDefaults.standard.string(forKey: Self.baseURLDefaultsKey),
              let url = URL(string: base.trimmingCharacters(in: .init(charactersIn: "/")) + "/api/library/search"),
              // The token only ever travels to an http(s) library origin.
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let token = KeychainHelper.get(account: Self.tokenAccount)
        else {
            return "Error: the knowledge library is not configured. Set its URL and token in Settings."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "question": question,
            "sourceFilter": (input["source_filter"] as? String) ?? "all",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return "Error: invalid response from the library." }
        guard (200 ... 299).contains(http.statusCode) else {
            logger.error("knowledge_search HTTP \(http.statusCode, privacy: .public)")
            return "Error: the library returned HTTP \(http.statusCode)."
        }

        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let passages = root?["passages"] as? [[String: Any]] ?? []
        guard !passages.isEmpty else { return "No relevant passages were found in the library." }

        // Restate the attribution rule with the results: a tool description read
        // once at the top of a long conversation is easy for the model to drift from.
        let header = "Passages from the user's saved library. Attribute any answer "
            + "built on these to the library and name the source title."
        return header + "\n\n" + passages.enumerated().map { index, passage in
            let title = passage["title"] as? String ?? "Untitled"
            let stamp = (passage["startAt"] as? String).map { " [\($0)]" } ?? ""
            let link = (passage["sourceUrl"] as? String).map { "\nSource: \($0)" } ?? ""
            let content = passage["content"] as? String ?? ""
            return "[\(index + 1)] \(title)\(stamp)\(link)\n\(content)"
        }.joined(separator: "\n\n")
    }
}
