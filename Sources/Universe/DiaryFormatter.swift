import Foundation

/// Tidies a dictated diary entry into readable prose, on explicit request.
///
/// This is the one place diary text is sent to a model, and only when the user
/// presses Format. Nothing here is automatic and nothing is stored remotely:
/// the raw entry goes out, the cleaned version comes back, and the user decides
/// whether to keep it.
enum DiaryFormatter {
    /// Deliberately narrow: dictation produces run-on text with no punctuation,
    /// and the job is to make that readable — not to interpret, summarise, or
    /// add anything the speaker did not say.
    private static let instructions = """
    Reformat this dictated diary entry so it reads well.

    Rules:
    - Keep the author's own words, voice and meaning. Do not invent details.
    - Fix punctuation, capitalisation and obvious dictation slips.
    - Break it into paragraphs where the subject changes.
    - Do not add a title, date, heading, preamble or commentary.
    - Return only the reformatted entry.

    Entry:
    """

    /// Returns the reformatted entry, or throws if the request fails.
    static func format(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let messages: [[String: Any]] = [
            ["role": "user", "content": "\(instructions)\n\n\(trimmed)"],
        ]

        var formatted = ""
        // No tools: this is a single text transformation, so the agent loop and
        // its tool surface are not involved.
        for try await event in ClaudeService.shared.streamEvents(messages: messages, tools: []) {
            if case let .text(chunk) = event { formatted += chunk }
        }

        let result = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty reply means the model gave us nothing usable; keep the
        // original rather than wiping what the user dictated.
        return result.isEmpty ? trimmed : result
    }
}
