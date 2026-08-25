import Foundation

/// Streaming multi-provider client with tool-use support.
///
/// Routes to the right API based on the selected model's provider:
///  - Anthropic: Anthropic Messages API with Claude Code identity headers for OAuth tokens
///  - OpenAI: Codex responses endpoint with OAuth bearer
///  - Gemini: Cloud Code Assist streaming endpoint with OAuth bearer
///  - Moonshot / MiniMax: OpenAI-compatible chat completions with API key
///
/// SSE parse: text deltas plus content_block_start(tool_use) + input_json_delta
/// accumulation for Anthropic-format responses; OpenAI-format responses use
/// response.output_item.done for tool calls.
actor ClaudeService {
    static let shared = ClaudeService()

    /* Subscription (OAuth) tokens are issued to the Claude Code client, and Anthropic
       rejects inference on them unless the request presents that identity: the first
       system block must be this exact line and the client must identify as the CLI.
       Without it the API answers 429 rate_limit_error. API-key requests skip this. */
    private static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."
    private static let claudeCLIUserAgent = "claude-cli/2.1.75 (external, cli)"

    enum ServiceError: LocalizedError {
        case notSignedIn
        case noAPIKey
        case httpError(Int, String)
        case unsupportedProvider(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in or add an API key in AI Settings."
            case .noAPIKey: return "No API key. Add one in AI Settings."
            case .httpError(let code, let body): return "API error (HTTP \(code)): \(body)"
            case .unsupportedProvider(let name): return "\(name) is not wired up yet."
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
                    let model = await MainActor.run { ModelRegistry.shared.selectedModel }
                    let provider = model.provider

                    switch provider {
                    case .anthropic:
                        try await streamAnthropic(messages: messages, tools: tools, model: model, continuation: continuation)
                    case .openai:
                        try await streamOpenAI(messages: messages, tools: tools, model: model, continuation: continuation)
                    case .gemini:
                        try await streamGemini(messages: messages, tools: tools, model: model, continuation: continuation)
                    case .moonshot, .minimax:
                        try await streamOpenAICompatible(messages: messages, tools: tools, model: model, provider: provider, continuation: continuation)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Anthropic

    private func streamAnthropic(
        messages: [[String: Any]], tools: [[String: Any]], model: ModelInfo,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let oauthToken = try await AnthropicOAuth.validAccessToken()
        let apiKey = oauthToken == nil
            ? await MainActor.run(body: { KeychainHelper.get(account: "anthropic") })
            : nil

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var systemBlocks: [[String: Any]] = []
        if let oauthToken {
            request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "authorization")
            request.setValue("claude-code-20250219, oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue(Self.claudeCLIUserAgent, forHTTPHeaderField: "user-agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            systemBlocks.append(["type": "text", "text": Self.claudeCodeIdentity])
        } else if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("universe/0.1 (macOS)", forHTTPHeaderField: "user-agent")
        } else {
            throw ServiceError.notSignedIn
        }
        systemBlocks.append(["type": "text", "text": Self.systemPrompt])

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 4096,
            "stream": true,
            "system": systemBlocks,
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
    }

    // MARK: - OpenAI (Codex)

    private func streamOpenAI(
        messages: [[String: Any]], tools: [[String: Any]], model: ModelInfo,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard let token = try await OpenAIOAuth.validAccessToken() else {
            throw ServiceError.notSignedIn
        }
        let accountId = OpenAIOAuth.TokenStore.load()?.accountId ?? ""

        let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("universe/0.1 (macOS)", forHTTPHeaderField: "user-agent")

        // Convert Anthropic message format to OpenAI format
        let openAIMessages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt],
        ] + messages.map { msg -> [String: Any] in
            var m = msg
            if m["role"] as? String == "assistant", let content = m["content"] as? [[String: Any]] {
                // Convert Anthropic content blocks to plain text for OpenAI
                let text = content.compactMap { block -> String? in
                    if let t = block["text"] as? String { return t }
                    return nil
                }.joined()
                m["content"] = text
            }
            return m
        }

        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            "input": openAIMessages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw ServiceError.httpError(http.statusCode, errorBody)
        }

        // OpenAI SSE: response.output_text.delta for text, response.output_item.done for tools
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    continuation.yield(.text(delta))
                }
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any],
                   item["type"] as? String == "function_call",
                   let name = item["name"] as? String,
                   let callId = item["call_id"] as? String {
                    let args = item["arguments"] as? String ?? "{}"
                    let input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
                    continuation.yield(.toolUse(id: callId, name: name, input: input))
                }
            case "response.completed":
                continuation.yield(.stop(reason: "end_turn"))
            default:
                continue
            }
        }
        continuation.finish()
    }

    // MARK: - Gemini

    private func streamGemini(
        messages: [[String: Any]], tools: [[String: Any]], model: ModelInfo,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard let token = try await GeminiOAuth.validAccessToken(),
              let projectId = GeminiOAuth.TokenStore.load()?.projectId else {
            throw ServiceError.notSignedIn
        }

        let endpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("universe/0.1 (macOS)", forHTTPHeaderField: "user-agent")

        // Convert to Gemini format
        let contents: [[String: Any]] = messages.map { msg in
            let role = (msg["role"] as? String == "assistant") ? "model" : "user"
            var parts: [[String: Any]] = []
            if let content = msg["content"] as? String {
                parts.append(["text": content])
            } else if let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    if let text = block["text"] as? String {
                        parts.append(["text": text])
                    }
                }
            }
            return ["role": role, "parts": parts]
        }

        var body: [String: Any] = [
            "model": model.id,
            "project": projectId,
            "request": [
                "contents": contents,
                "systemInstruction": ["parts": [["text": Self.systemPrompt]]],
                "generationConfig": ["maxOutputTokens": 4096],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw ServiceError.httpError(http.statusCode, errorBody)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let candidates = event["candidates"] as? [[String: Any]],
               let candidate = candidates.first,
               let content = candidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String {
                        continuation.yield(.text(text))
                    }
                }
                if let finish = candidate["finishReason"] as? String, !finish.isEmpty {
                    continuation.yield(.stop(reason: finish))
                }
            }
        }
        continuation.finish()
    }

    // MARK: - OpenAI-compatible (Moonshot, MiniMax)

    private func streamOpenAICompatible(
        messages: [[String: Any]], tools: [[String: Any]], model: ModelInfo, provider: AIProvider,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard let apiKey = ProviderStore.APIKeyStore.get(provider), !apiKey.isEmpty else {
            throw ServiceError.noAPIKey
        }

        let baseURL: String
        switch provider {
        case .moonshot: baseURL = "https://api.moonshot.ai/v1/chat/completions"
        case .minimax: baseURL = "https://api.minimax.io/v1/chat/completions"
        default: throw ServiceError.unsupportedProvider(provider.displayName)
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("universe/0.1 (macOS)", forHTTPHeaderField: "user-agent")

        let openAIMessages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt],
        ] + messages.map { msg -> [String: Any] in
            var m = msg
            if m["role"] as? String == "assistant", let content = m["content"] as? [[String: Any]] {
                let text = content.compactMap { ($0["text"] as? String) }.joined()
                m["content"] = text
            }
            return m
        }

        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            "messages": openAIMessages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw ServiceError.httpError(http.statusCode, errorBody)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = event["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            if let delta = choice["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                continuation.yield(.text(content))
            }
            if let finish = choice["finish_reason"] as? String, !finish.isEmpty {
                continuation.yield(.stop(reason: finish))
            }
        }
        continuation.finish()
    }
}
