import Foundation

/// Streaming Anthropic client with tool-use support. SSE parse: text deltas plus
/// content_block_start(tool_use) + input_json_delta accumulation (SPEC.md §4).
actor ClaudeService {
    static let shared = ClaudeService()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-haiku-4-5-20251001"

    enum ServiceError: LocalizedError {
        case noAPIKey
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No API key. Add your Anthropic API key in Settings."
            case .httpError(let code, let body): return "API error (HTTP \(code)): \(body)"
            }
        }
    }

    private static let systemPrompt = """
    You are a personal assistant living on the user's desktop. \
    Talk like texting a close friend: chill, casual, concise. \
    Lead with the answer. No fluff, no corporate speak. \
    You have access to tools for working with the user's computer: bash, read, write, edit. \
    You can also create reminders (create_reminder) and routines (create_routine) that run on a schedule, \
    list them (list_schedules), and delete them (delete_schedule). \
    Reminders fire macOS notifications; routines run a prompt and notify with the result. \
    Use them proactively and finish tasks completely.
    """

    /// Streams events for one turn. Messages and tools are Anthropic API format.
    nonisolated func streamEvents(messages: [[String: Any]], tools: [[String: Any]]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = await MainActor.run(body: {
                        KeychainHelper.get(account: "anthropic")
                    }), !apiKey.isEmpty else {
                        throw ServiceError.noAPIKey
                    }

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue("tama-clone/0.1 (macOS)", forHTTPHeaderField: "user-agent")

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "stream": true,
                        "system": Self.systemPrompt,
                        "messages": messages,
                    ]
                    if !tools.isEmpty { body["tools"] = tools }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        throw ServiceError.httpError(http.statusCode, errorBody)
                    }

                    var toolID = ""
                    var toolName = ""
                    var toolInputJSON = ""
                    var inToolBlock = false
                    var stopReason = "end_turn"

                    func flushTool() {
                        guard inToolBlock else { return }
                        let input = (try? JSONSerialization.jsonObject(
                            with: toolInputJSON.isEmpty ? Data("{}".utf8) : Data(toolInputJSON.utf8)
                        )) as? [String: Any] ?? [:]
                        continuation.yield(.toolUse(id: toolID, name: toolName, input: input))
                        inToolBlock = false
                        toolInputJSON = ""
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard payload != "[DONE]",
                              let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String else { continue }

                        switch type {
                        case "content_block_start":
                            if let block = event["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use" {
                                inToolBlock = true
                                toolID = block["id"] as? String ?? ""
                                toolName = block["name"] as? String ?? ""
                                toolInputJSON = ""
                            }
                        case "content_block_delta":
                            guard let delta = event["delta"] as? [String: Any],
                                  let deltaType = delta["type"] as? String else { continue }
                            if deltaType == "text_delta", let text = delta["text"] as? String {
                                continuation.yield(.text(text))
                            } else if deltaType == "input_json_delta",
                                      let partial = delta["partial_json"] as? String {
                                toolInputJSON += partial
                            }
                        case "content_block_stop":
                            flushTool()
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any],
                               let reason = delta["stop_reason"] as? String {
                                stopReason = reason
                            }
                        case "message_stop":
                            continuation.yield(.stop(reason: stopReason))
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
