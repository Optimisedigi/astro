import Foundation

/// Wire contract for OpenAI GPT‑Live on a ChatGPT plan (`gpt-live-1-codex`).
///
/// Unlike the GA Realtime models, GPT‑Live has no tools of its own. It talks to
/// the user over a WebRTC audio call and *delegates* real work to the client:
/// the client runs the request (here: Universe's agent) and appends the answer
/// back to the delegation for the model to speak in its own words.
///
/// Endpoints and events mirror OpenAI's Codex client and OpenClaw's GPT‑Live
/// bridge — this is an unlisted ChatGPT endpoint, so it may change.
enum GPTLiveProtocol {
    static let model = "gpt-live-1-codex"
    static let callURL = URL(string: "https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas")!
    /// Appends larger than this are split; results are capped so speech stays short.
    static let appendMaxBytes = 500
    static let resultMaxChars = 1_800

    static let voices = ["cove", "arbor", "breeze", "ember", "juniper", "maple", "sol", "spruce", "vale"]
    static let defaultVoice = "cove"

    static let instructions = """
    You are Astro's realtime voice layer. Your name is Astro. You have no tools of your own.
    Delegate any request that requires real work, reasoning, current information, or actions to the client through a delegation.
    Delegate each user request once and wait for its result. New user follow-ups, corrections, and explicit retries are new requests. Results are not user requests; do not delegate them.
    Keep the conversation natural while delegated work runs.
    Context on the commentary channel is silent background. You may use it, but never read it aloud.
    Context on the speakable channel is your answer to deliver naturally in your own words. Never mention the channel or the delegation.
    Keep spoken replies to one to three short sentences. When the user says goodbye, say a brief goodbye.
    """

    struct RequestIds {
        let sessionId: String
        let threadId: String
        let realtimeSessionId: String

        static func fresh() -> RequestIds {
            RequestIds(sessionId: UUID().uuidString.lowercased(),
                       threadId: UUID().uuidString.lowercased(),
                       realtimeSessionId: UUID().uuidString.lowercased())
        }
    }

    static func headers(accessToken: String, accountId: String, ids: RequestIds) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "chatgpt-account-id": accountId,
            "OpenAI-Alpha": "quicksilver=v2",
            "session-id": ids.sessionId,
            "thread-id": ids.threadId,
            "x-session-id": ids.realtimeSessionId,
            "User-Agent": "universe/0.1 (macOS)",
        ]
    }

    static func session(voice: String, persona: String) -> [String: Any] {
        [
            "model": model,
            "instructions": persona.isEmpty ? instructions : persona + "\n\n" + instructions,
            "audio": ["output": ["voice": voices.contains(voice) ? voice : defaultVoice]],
            "delegation": ["type": "client"],
        ]
    }

    /// ChatGPT's call endpoint takes JSON `{sdp, session}` and answers with raw SDP.
    static func callRequestBody(offerSDP: String, session: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["sdp": offerSDP, "session": session])
    }

    /// The sideband WebSocket that carries transcripts and delegations for a call.
    static func sidebandURL(callId: String) -> URL? {
        guard isCallId(callId) else { return nil }
        return URL(string: "wss://api.openai.com/v1/live/\(callId)")
    }

    /// Call id from the `Location` header, falling back to `openai-session-id`.
    static func callId(location: String?, sessionIdHeader: String?) -> String? {
        if let location, let url = URL(string: location, relativeTo: callURL),
           let id = url.path.split(separator: "/").map(String.init).first(where: isCallId) {
            return id
        }
        if let header = sessionIdHeader?.trimmingCharacters(in: .whitespaces), isCallId(header) { return header }
        return nil
    }

    static func isCallId(_ value: String) -> Bool {
        value.range(of: #"^rtc_[\w-]+$"#, options: .regularExpression) != nil
            || value.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#,
                           options: .regularExpression) != nil
    }

    enum Event: Equatable {
        case sessionStarted
        case speaking(role: String)
        case turnDone(role: String, text: String)
        case audioCleared
        case delegation(id: String, prompt: String?)
        case error(message: String, fatal: Bool)
        case closed(reason: String)
        case ignored
    }

    static func parse(_ text: String) -> Event {
        guard let data = text.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String
        else { return .ignored }

        switch type {
        case "session.started":
            return .sessionStarted
        case "input_transcript.added":
            return .speaking(role: "user")
        case "output_transcript.added":
            return .speaking(role: "assistant")
        case "turn.done":
            guard let turn = event["turn"] as? [String: Any],
                  let role = turn["role"] as? String, role == "user" || role == "assistant"
            else { return .ignored }
            return .turnDone(role: role, text: turn["transcript"] as? String ?? "")
        case "output_audio_buffer.cleared":
            return .audioCleared
        case "delegation.created":
            guard let item = event["item"] as? [String: Any],
                  item["type"] as? String == "delegation", item["target"] as? String == "client",
                  let id = item["id"] as? String, !id.isEmpty
            else { return .ignored }
            let parts = item["content"] as? [[String: Any]]
            let prompt = parts.map { $0.filter { $0["type"] as? String == "input_text" }
                .compactMap { $0["text"] as? String }.joined() }
            return .delegation(id: id, prompt: prompt)
        case "session.closed":
            return .closed(reason: event["reason"] as? String ?? "closed")
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? event["message"] as? String ?? "GPT-Live error"
            let status = error?["status"] as? Int ?? event["status"] as? Int
            let code = (error?["code"] ?? event["code"]) as? String ?? ""
            let fatal = status == 401
                || ["authentication_error", "invalid_api_key", "invalid_token", "token_expired"].contains(code)
            return .error(message: message, fatal: fatal)
        default:
            return .ignored
        }
    }

    /// `delegation.context.append` events carrying `text`, split to stay under
    /// the per-append size limit.
    static func contextAppends(text: String, delegationId: String, channel: String = "speakable") -> [[String: Any]] {
        chunks(text, maxBytes: appendMaxBytes).map { chunk in
            [
                "type": "delegation.context.append",
                "delegation_item_id": delegationId,
                "channel": channel,
                "content": [["type": "input_text", "text": chunk]],
            ]
        }
    }

    static func boundResult(_ text: String) -> String {
        text.count <= resultMaxChars ? text : String(text.prefix(resultMaxChars - 1)) + "…"
    }

    static func chunks(_ text: String, maxBytes: Int) -> [String] {
        var result: [String] = []
        var current = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if !current.isEmpty, bytes + size > maxBytes {
                result.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
