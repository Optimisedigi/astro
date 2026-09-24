import Foundation
import os

private let logger = Logger(subsystem: "com.universe.app", category: "tool.search.chatgpt")

/// Web search through OpenAI's hosted `web_search` tool, billed to the user's
/// ChatGPT plan via the OpenAI sign-in. Returns a short sourced answer plus the
/// cited links — much better than scraping search-engine HTML, and not rate
/// limited by bot detection.
enum ChatGPTWebSearch {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    /// GPT-5.5 leaves ChatGPT-plan Codex on 14 Oct 2026; Sol is its named replacement.
    private static let model = "gpt-6-sol"

    struct Citation: Equatable {
        let title: String
        let url: String
    }

    struct Result: Equatable {
        let answer: String
        let citations: [Citation]
    }

    enum SearchError: LocalizedError {
        case notSignedIn
        case http(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Not signed in to ChatGPT"
            case let .http(code): "ChatGPT search failed (HTTP \(code))"
            case .empty: "ChatGPT search returned nothing"
            }
        }
    }

    static func search(query: String, maxResults: Int, session: URLSession = .shared) async throws -> Result {
        guard let credentials = try await OpenAIOAuth.validCredentials() else { throw SearchError.notSignedIn }
        let started = CFAbsoluteTimeGetCurrent()

        // Kept short: on timeout the tool falls back to the scraping engines.
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("universe/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(query: query, maxResults: maxResults))

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            logger.warning("ChatGPT search HTTP \(status)")
            throw SearchError.http(status)
        }

        var lines: [String] = []
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            lines.append(String(line.dropFirst(6)))
        }
        let result = parse(eventPayloads: lines, maxResults: maxResults)
        let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        logger.info("ChatGPT search done in \(ms) ms — \(result.citations.count) sources")
        guard !result.answer.isEmpty || !result.citations.isEmpty else { throw SearchError.empty }
        return result
    }

    static func requestBody(query: String, maxResults: Int) -> [String: Any] {
        [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": """
            You are a web search backend for another assistant. Search the web and answer \
            the query with the most current facts in at most \(max(3, maxResults)) short bullet points. \
            Include concrete numbers, dates and names. No preamble.
            """,
            "input": [["role": "user", "content": [["type": "input_text", "text": query]]]],
            "tools": [["type": "web_search"]],
            "tool_choice": "auto",
            "reasoning": ["effort": "low"],
        ]
    }

    /// Builds the answer from streamed `data:` payloads. Pure, so it's testable.
    static func parse(eventPayloads: [String], maxResults: Int) -> Result {
        var deltaText = ""
        var finalText: String?
        var citations: [Citation] = []

        for payload in eventPayloads {
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "response.output_text.delta":
                deltaText += event["delta"] as? String ?? ""
            case "response.output_item.done":
                guard let item = event["item"] as? [String: Any], item["type"] as? String == "message" else { continue }
                let parts = item["content"] as? [[String: Any]] ?? []
                var text = ""
                for part in parts where part["type"] as? String == "output_text" {
                    text += part["text"] as? String ?? ""
                    for annotation in part["annotations"] as? [[String: Any]] ?? [] {
                        guard annotation["type"] as? String == "url_citation",
                              let url = annotation["url"] as? String,
                              !citations.contains(where: { $0.url == url })
                        else { continue }
                        citations.append(Citation(title: annotation["title"] as? String ?? url, url: url))
                    }
                }
                if !text.isEmpty { finalText = (finalText ?? "") + text }
            default:
                continue
            }
        }

        let answer = (finalText ?? deltaText).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(answer: answer, citations: Array(citations.prefix(maxResults)))
    }

    static func format(_ result: Result, query: String) -> String {
        var output = "Web search results for: \"\(query)\"\n\n\(result.answer)\n"
        if !result.citations.isEmpty {
            output += "\nSources:\n"
            for (index, citation) in result.citations.enumerated() {
                output += "\(index + 1). [\(citation.title)](\(citation.url))\n"
            }
        }
        output += "\n(via ChatGPT web search)"
        return output
    }
}
