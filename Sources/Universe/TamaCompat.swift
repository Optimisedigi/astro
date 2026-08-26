import Foundation

/// Compatibility types bridging Tama's API surface to Universe's internals.
/// These let the ported Tama files compile without rewriting their logic.

// MARK: - Agent events (Tama's richer event model used by CallSession)

enum AgentEvent {
    case textDelta(String)
    case toolStart(name: String, id: String)
    case toolRunning(name: String, args: [String: String])
    case toolResult(name: String, output: String)
    case turnComplete(text: String)
    case error(String)
}

// MARK: - Anthropic response types (used by StreamParser)

enum ContentBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
}

struct ClaudeResponse {
    let content: [ContentBlock]
    let stopReason: String?
    let reasoningContent: String?
    let usage: TokenUsage?
}

struct TokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    var cacheHitRatio: Double {
        let total = inputTokens + cacheCreationInputTokens + cacheReadInputTokens
        guard total > 0 else { return 0 }
        return Double(cacheReadInputTokens) / Double(total) * 100
    }
}

// MARK: - Tool output (used by browser/screenshot tools)

struct ToolOutput {
    let content: String
    let imageData: Data?

    init(content: String, imageData: Data? = nil) {
        self.content = content
        self.imageData = imageData
    }
}

// MARK: - Tool image (used by screenshot tool)

struct ToolImage {
    let data: Data
    let mediaType: String
}


// MARK: - StreamEvent extensions for Tama's StreamParser

extension StreamEvent {
    static func textDelta(_ text: String) -> StreamEvent { .text(text) }
    static func toolUseStart(id: String, name: String) -> StreamEvent { .toolUse(id: id, name: name, input: [:]) }
}

// MARK: - Agent errors

struct AgentDismissError: Error {
    let conversation: [[String: Any]]
}

// MARK: - AIProvider extensions

extension AIProvider {
    var baseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .moonshot: return "https://api.moonshot.cn"
        case .minimax: return "https://api.minimax.chat"
        }
    }
}

// MARK: - MarkdownRenderer stub (Universe uses Markdown.parse, not NSAttributedString)

@MainActor
enum MarkdownRenderer {
    static func render(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text)
    }
}

// MARK: - Kokoro MToken stub (used only when KokoroSwift is not available)

#if !canImport(KokoroSwift)
struct MToken {
    let text: String
    let start_ts: Double?
    let end_ts: Double?
}
#endif

// MARK: - PermissionsChecker extensions

extension PermissionsChecker {
    func openScreenRecordingSettings() { openSettings(for: .screenRecording) }
    func requestScreenRecording() { grant(.screenRecording) }
}

// MARK: - Missing shared instances / methods

extension PermissionsChecker {
    static let shared = PermissionsChecker()
}

@MainActor
private enum _ProviderStoreHolder {
    static let compat = ProviderStoreCompat()
}
@MainActor
final class ProviderStoreCompat {
    var selectedModel: ModelInfo { ModelRegistry.shared.selectedModel }
}
extension ProviderStore {
    /// Tama's code accesses ProviderStore.shared.selectedModel.provider.
    @MainActor
    static var shared: ProviderStoreCompat { _ProviderStoreHolder.compat }
        @MainActor
    static var selectedModel: ModelInfo { ModelRegistry.shared.selectedModel }
}

extension ModelRegistry {
    static var availableModels: [ModelInfo] { models }
}

extension ToolIndicatorView {
    static func displayName(for toolName: String, args: [String: String]? = nil) -> String {
        if let args, let path = args["file_path"] ?? args["command"] ?? args["pattern"] {
            return "\(toolName) — \(path.prefix(40))"
        }
        return toolName
    }
}


// MARK: - PromptPanelController stub

@MainActor
enum PromptPanelController {
    static func ensureWorkspace() -> String {
        FileManager.default.currentDirectoryPath
    }
    static func screenshotsDirectory() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Universe/screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}

// MARK: - ClaudeService extensions for Tama's CallSession

extension ClaudeService {
    enum ClaudeServiceError: Error {
        case streamError(String)
    }

    func prewarmConnection(for provider: AIProvider) {
        // Connection prewarming is a later optimization.
    }
}

// MARK: - Shared instances Tama expects

// SpeechService owns its own `shared` instance and callbacks (SpeechService.swift).

// VoiceService owns its own `shared` instance, callbacks, AEC prewarm and
// capture lifecycle (VoiceService.swift) — no compatibility shim needed.

// MARK: - ToolRegistry extension for call mode

extension ToolRegistry {
    static func callRegistry() -> ToolRegistry {
        // Call mode uses the same tools as chat mode.
        shared
    }
}

// MARK: - AgentLoop compatibility (Tama inits with registry, Universe with workspace)

extension AgentLoop {
    static func withRegistry(_ registry: ToolRegistry) -> AgentLoop {
        AgentLoop(workspace: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    /// Tama's CallSession calls run(messages:systemPrompt:useBasePrompt:maxTokens:onEvent:).
    /// Universe's AgentLoop has a different signature. This bridges them.
    @MainActor
    func run(
        messages: [[String: Any]],
        systemPrompt: String,
        useBasePrompt: Bool,
        maxTokens: Int,
        onEvent: @escaping (AgentEvent) -> Void
    ) async throws -> [[String: Any]] {
        var result: [[String: Any]] = messages
        try await run(
            apiMessages: messages,
            streamProvider: ClaudeService.shared.streamEvents,
            onText: { text in onEvent(.textDelta(text)) },
            onToolActivity: { activity in
                switch activity {
                case .started(let id, let name, let detail):
                    onEvent(.toolStart(name: name, id: id))
                    if let detail { onEvent(.toolRunning(name: name, args: ["file_path": detail])) }
                case .finished(let id, let failed):
                    onEvent(.toolResult(name: "", output: failed ? "error" : "ok"))
                }
            }
        )
        return result
    }
}

// MARK: - SessionStore extension for Tama's ChatSession

extension SessionStore {
    func save(session: ChatSession) {
        // Convert Tama's ChatSession to Universe's Session format.
        let messages: [Session.Message] = session.messages.compactMap { msg in
            // Extract text from the first .text content block.
            let text = msg.content.compactMap { content -> String? in
                if case .text(let t) = content { return t }
                return nil
            }.joined(separator: "\n")
            return Session.Message(role: msg.role.rawValue, text: text)
        }
        var s = Session(id: session.id, title: session.title, messages: messages)
        s.createdAt = session.createdAt
        s.updatedAt = session.updatedAt
        save(s)
    }
}
