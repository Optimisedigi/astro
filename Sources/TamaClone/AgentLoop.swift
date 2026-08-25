import Foundation

/// Events from a streaming LLM turn. Provider-agnostic so the loop is testable offline.
enum StreamEvent {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case stop(reason: String)
}

typealias EventStreamProvider = @Sendable ([[String: Any]], [[String: Any]]) -> AsyncThrowingStream<StreamEvent, Error>

/// The agent loop: stream → execute tool calls → feed results back → repeat (SPEC.md §2).
/// Mirrors Tama's AgentLoop.swift with a maxTurns cap.
struct AgentLoop {
    let maxTurns = 10
    let workspace: URL
    let registry = ToolRegistry.shared

    /// Runs the loop. `apiMessages` are Anthropic-format messages (content blocks).
    /// `onText` fires per streamed delta; `onToolActivity` reports tool start/result for UI.
    func run(
        apiMessages: [[String: Any]],
        streamProvider: EventStreamProvider,
        onText: @escaping @MainActor (String) -> Void,
        onToolActivity: @escaping @MainActor (String) -> Void
    ) async throws {
        var messages = apiMessages
        var turns = 0

        while turns < maxTurns {
            turns += 1
            var assistantBlocks: [[String: Any]] = []
            var pendingTools: [(id: String, name: String, input: [String: Any])] = []
            var textBuffer = ""
            var stopReason = ""

            for try await event in streamProvider(messages, registry.schemas) {
                switch event {
                case .text(let delta):
                    textBuffer += delta
                    await onText(delta)
                case .toolUse(let id, let name, let input):
                    pendingTools.append((id, name, input))
                case .stop(let reason):
                    stopReason = reason
                }
            }

            if !textBuffer.isEmpty {
                assistantBlocks.append(["type": "text", "text": textBuffer])
            }

            if pendingTools.isEmpty || stopReason == "end_turn" {
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
                await onToolActivity(tool.name)
                let output = await registry.run(name: tool.name, input: tool.input, workingDirectory: workspace)
                await onToolActivity("\(tool.name) done")
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
