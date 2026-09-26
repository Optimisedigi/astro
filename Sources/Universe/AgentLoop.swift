import Foundation

/// Events from a streaming LLM turn. Provider-agnostic so the loop is testable offline.
enum StreamEvent {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case stop(reason: String)
}

/// What the UI is told about a tool call, so it can show a row rather than a status string.
enum ToolActivity {
    case started(id: String, name: String, detail: String?)
    case finished(id: String, failed: Bool)

    /// The most useful single argument to show next to the tool name.
    static func detail(for input: [String: Any]) -> String? {
        for key in ["file_path", "command", "pattern", "path", "url", "name", "query"] {
            if let value = input[key] as? String, !value.isEmpty { return String(value.prefix(80)) }
        }
        return nil
    }

    /// Tools report failure in their output text; there is no separate error channel.
    static func looksLikeFailure(_ output: String) -> Bool {
        let head = output.prefix(200).lowercased()
        return head.hasPrefix("error") || head.contains("escapes workspace") || head.contains("could not")
    }
}

typealias EventStreamProvider = @Sendable ([[String: Any]], [[String: Any]]) -> AsyncThrowingStream<StreamEvent, Error>

/// The agent loop: stream → execute tool calls → feed results back → repeat (SPEC.md §2).
/// Mirrors Tama's AgentLoop.swift with a maxTurns cap.
struct AgentLoop {
    let maxTurns = 10
    let workspace: URL
    let registry = ToolRegistry.shared

    /// Runs the loop. `apiMessages` are Anthropic-format messages (content blocks).
    /// `onText` fires per streamed delta; `onToolActivity` reports tool start/finish for UI.
    func run(
        apiMessages: [[String: Any]],
        streamProvider: EventStreamProvider,
        onText: @escaping @MainActor (String) -> Void,
        onToolActivity: @escaping @MainActor (ToolActivity) -> Void
    ) async throws {
        var messages = apiMessages
        var turns = 0

        while turns < maxTurns {
            turns += 1
            var assistantBlocks: [[String: Any]] = []
            var pendingTools: [(id: String, name: String, input: [String: Any])] = []
            var textBuffer = ""

            for try await event in streamProvider(messages, registry.schemas) {
                switch event {
                case .text(let delta):
                    textBuffer += delta
                    await onText(delta)
                case .toolUse(let id, let name, let input):
                    pendingTools.append((id, name, input))
                case .stop:
                    continue
                }
            }

            if !textBuffer.isEmpty {
                assistantBlocks.append(["type": "text", "text": textBuffer])
            }

            // Any tool call is answered, whatever stop reason the provider
            // reports: breaking on "end_turn" silently dropped OpenAI's tool
            // calls (the knowledge library among them).
            if pendingTools.isEmpty {
                break
            }

            // Assistant turn with tool_use blocks
            assistantBlocks += pendingTools.map {
                ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input]
            }
            messages.append(["role": "assistant", "content": assistantBlocks])

            // Execute tools, collect tool_result blocks
            var results: [[String: Any]] = []
            for tool in pendingTools {
                await onToolActivity(.started(id: tool.id, name: tool.name, detail: ToolActivity.detail(for: tool.input)))
                let output = await registry.run(name: tool.name, input: tool.input, workingDirectory: workspace)
                await onToolActivity(.finished(id: tool.id, failed: ToolActivity.looksLikeFailure(output)))
                results.append([
                    "type": "tool_result",
                    "tool_use_id": tool.id,
                    "content": String(output.prefix(50_000)),
                ])
            }
            messages.append(["role": "user", "content": results])
        }
    }
}
