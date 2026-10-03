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
        case allModelsFailed

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in or add an API key in AI Settings."
            case .noAPIKey: return "No API key. Add one in AI Settings."
            case .httpError(let code, let body): return "API error (HTTP \(code)): \(body)"
            case .unsupportedProvider(let name): return "\(name) is not wired up yet."
            case .allModelsFailed: return "Every connected model failed. Check AI Settings."
            }
        }
    }

    /// Read-only view of the chat persona for the offline self-test.
    static var chatSystemPromptForTesting: String { systemPrompt }

    private static let systemPrompt = """
    You are Astro, a personal assistant living on the user's desktop. \
    If asked your name, it's Astro. \
    Talk like texting a close friend: chill, casual, concise. \
    Lead with the answer. No fluff, no corporate speak. \
    You have access to tools for working with the user's computer: bash, read, write, edit. \
    You can also create reminders (create_reminder) and routines (create_routine) that run on a schedule, \
    list them (list_schedules), and delete them (delete_schedule). \
    Reminders fire macOS notifications; routines run a prompt and notify with the result. \
    Use them proactively and finish tasks completely.

    \(ResearchReportTool.workflowInstructions)

    The user has a personal knowledge library of saved videos, talks, transcripts and \
    documents, searchable with `knowledge_search`. Search it first for any question about \
    a topic, person, idea or piece of content they might have saved, before answering \
    from your own knowledge. When your answer uses the library, open by saying it came \
    from their knowledge library and name each source title (with its [mm:ss] timestamp \
    when there is one). If the library had nothing relevant, say so briefly and then \
    answer from your own knowledge.

    You have long-term memory. Use `remember` proactively whenever the user shares something \
    meaningful about themselves — their name, preferences, projects, people in their life. \
    Keep each fact atomic. Use `recall` to look up details not already in your context, and \
    `forget` when something stops being true or they ask you to drop it. \
    Use `soul_set` to record what you learn about working with *this* user — corrections they \
    make, boundaries they set, how they like you to communicate. Never announce that you are \
    saving to memory; just do it and carry on.
    """

    /// The system prompt plus everything the assistant remembers. Rebuilt per
    /// request so a fact saved mid-conversation applies on the very next turn.
    private static func systemPromptWithMemory() async -> String {
        let memory = await MainActor.run { MemoryStore.shared.promptContext() }
        let base = memory.isEmpty ? systemPrompt : systemPrompt + "\n\n" + memory
        // Last, so the unchanging part above stays a stable prefix; rebuilt
        // per request, so the time is fresh on every turn.
        return base + "\n\n" + ScheduleParser.currentTimeNote()
    }

    /// Streams events for one turn. Messages and tools are Anthropic API format.
    nonisolated func streamEvents(messages: [[String: Any]], tools: [[String: Any]]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let chain = await MainActor.run { ModelRegistry.shared.fallbackChain() }
                    var lastError: Error = ServiceError.allModelsFailed
                    for model in chain {
                        do {
                            try await streamWith(model: model, messages: messages, tools: tools, continuation: continuation)
                            return
                        } catch {
                            lastError = error
                            if Self.isContextOverflow(error) { throw error }
                            continue
                        }
                    }
                    throw lastError
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// One attempt against a single model. Failures here walk the fallback chain.
    private func streamWith(
        model: ModelInfo,
        messages: [[String: Any]], tools: [[String: Any]],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        // The chat builds pictures for the model the user picked; a fallback
        // that cannot see must not receive them, or it rejects the whole turn
        // (Kimi: "invalid part type: image").
        let messages = model.supportsVision ? messages : Self.withoutImages(messages)
        switch model.provider {
        case .anthropic:
            try await streamAnthropic(messages: messages, tools: tools, model: model, continuation: continuation)
        case .openai:
            try await streamOpenAI(messages: messages, tools: tools, model: model, continuation: continuation)
        case .gemini:
            try await streamGemini(messages: messages, tools: tools, model: model, continuation: continuation)
        case .kimi:
            try await streamKimi(messages: messages, tools: tools, model: model, continuation: continuation)
        case .moonshot, .minimax, .xiaomi, .xiaomiAPI:
            try await streamOpenAICompatible(messages: messages, tools: tools, model: model, provider: model.provider, continuation: continuation)
        }
    }

    /// Swap each picture for a short note, keeping the text read out of it
    /// (already its own block), for a model that cannot see images.
    static func withoutImages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard let blocks = message["content"] as? [[String: Any]],
                  blocks.contains(where: { $0["type"] as? String == "image" }) else { return message }
            var stripped = message
            stripped["content"] = blocks.map { block -> [String: Any] in
                guard block["type"] as? String == "image" else { return block }
                return ["type": "text", "text": "[An image was attached, but this model cannot see images.]"]
            }
            return stripped
        }
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        let text = (error as? ServiceError)?.errorDescription ?? error.localizedDescription
        return text.range(of: "context|too long|maximum", options: .regularExpression) != nil
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
        systemBlocks.append(["type": "text", "text": await Self.systemPromptWithMemory()])

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

        let systemText = await Self.systemPromptWithMemory()
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.openAIBody(
            messages: messages, tools: tools, model: model, system: systemText
        ))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw ServiceError.httpError(http.statusCode, errorBody)
        }

        // OpenAI SSE: response.output_text.delta for text, response.output_item.done for tools
        var calledTools = false
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
                    calledTools = true
                    continuation.yield(.toolUse(id: callId, name: name, input: input))
                }
            case "response.completed":
                // The agent loop runs the tools and asks again only after a
                // tool stop; "end_turn" here dropped every tool call.
                continuation.yield(.stop(reason: calledTools ? "tool_use" : "end_turn"))
            default:
                continue
            }
        }
        continuation.finish()
    }

    /// The Responses request body. Messages arrive in Anthropic format; the
    /// Codex converter turns pictures into `input_image`, and tool calls and
    /// results into `function_call` / `function_call_output`. Before it was
    /// used, the tools (the knowledge library among them) were never sent,
    /// and attached images went over in a shape OpenAI does not read.
    static func openAIBody(
        messages: [[String: Any]], tools: [[String: Any]], model: ModelInfo, system: String
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            // Required: without it the ChatGPT endpoint rejects every request
            // (HTTP 400 "Store must be set to false") and chat silently falls
            // through to the next connected model.
            "store": false,
            "input": [["role": "system", "content": system]] + CodexRequestBuilder.convertMessages(messages),
        ]
        if !tools.isEmpty {
            body["tools"] = CodexRequestBuilder.convertTools(tools)
            body["tool_choice"] = "auto"
        }
        return body
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

        // Pictures go over as `inlineData`; a text-only conversion dropped
        // attached images and left Gemini only the text read out of them.
        let contents = GeminiRequestBuilder.convertMessages(messages)

        let systemText = await Self.systemPromptWithMemory()
        var body: [String: Any] = [
            "model": model.id,
            "project": projectId,
            "request": [
                "contents": contents,
                "systemInstruction": ["parts": [["text": systemText]]],
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

    // MARK: - Kimi For Coding (OAuth)

    /// K3 silently downgrades to K2.6 unless thinking is enabled — same quirk as anti-social.
    private func streamKimi(
        messages: [[String: Any]], tools: [[String: Any]], model: ModelInfo,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        guard let token = try await KimiOAuth.validAccessToken(), !token.isEmpty else {
            throw ServiceError.notSignedIn
        }
        let url = URL(string: "\(KimiOAuth.apiBaseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (header, value) in KimiOAuth.requestHeaders(accessToken: token) {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let systemText = await Self.systemPromptWithMemory()
        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            "messages": Self.openAIMessages(from: messages, system: systemText),
        ]
        if model.id == "k3" {
            body["thinking"] = ["type": "enabled"]
            body["reasoning_effort"] = "low"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await parseOpenAIChatStream(request: request, continuation: continuation)
    }

    // MARK: - OpenAI-compatible (Moonshot, MiniMax, MiMo)

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
        case .xiaomi: baseURL = "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions"
        case .xiaomiAPI: baseURL = "https://api.xiaomimimo.com/v1/chat/completions"
        default: throw ServiceError.unsupportedProvider(provider.displayName)
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("universe/0.1 (macOS)", forHTTPHeaderField: "user-agent")

        let systemText = await Self.systemPromptWithMemory()
        var body: [String: Any] = [
            "model": model.id,
            "stream": true,
            "messages": Self.openAIMessages(from: messages, system: systemText),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await parseOpenAIChatStream(request: request, continuation: continuation)
    }

    private static func openAIMessages(from messages: [[String: Any]], system: String) -> [[String: Any]] {
        [["role": "system", "content": system]] + messages.map { msg -> [String: Any] in
            var m = msg
            if m["role"] as? String == "assistant", let content = m["content"] as? [[String: Any]] {
                m["content"] = content.compactMap { $0["text"] as? String }.joined()
            }
            return m
        }
    }

    private func parseOpenAIChatStream(
        request: URLRequest,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
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
