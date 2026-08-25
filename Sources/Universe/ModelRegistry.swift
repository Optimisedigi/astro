import Foundation

/// Providers and models, in the shape tama-agent uses (`AIProvider` + `ModelInfo`),
/// extended with the newer models the learning-ai site ships.
///
/// Only Anthropic has a working credential path today. The other providers are still
/// listed because the picker has to tell the truth about what exists and what is not
/// connected — a card that silently does nothing would be worse than one that says so.
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case gemini
    case moonshot
    case minimax

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .moonshot: return "Moonshot"
        case .minimax: return "MiniMax"
        }
    }

    var summary: String {
        switch self {
        case .anthropic: return "Claude Sonnet 5 / Haiku 4.5 (via Claude account)"
        case .openai: return "GPT-5.5, Codex"
        case .gemini: return "Gemini 3 Pro / Flash (via Google account)"
        case .moonshot: return "Kimi K2.6"
        case .minimax: return "MiniMax M2.7"
        }
    }

    /// All providers have a sign-in path (OAuth or API key).
    var isImplemented: Bool { true }
}

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let provider: AIProvider
    let contextWindow: Int
    let maxOutputTokens: Int
    var supportsTools = true
    var supportsThinking = true
    var supportsVision = true
}

@MainActor
final class ModelRegistry: ObservableObject {
    static let shared = ModelRegistry()

    /// Anthropic IDs match the learning-ai site's catalog (verified Aug 2026);
    /// the rest carry tama-agent's IDs forward.
    static let models: [ModelInfo] = [
        // Anthropic
        .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", provider: .anthropic,
              contextWindow: 1_000_000, maxOutputTokens: 64_000),
        .init(id: "claude-opus-5", name: "Claude Opus 5", provider: .anthropic,
              contextWindow: 1_000_000, maxOutputTokens: 64_000),
        .init(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", provider: .anthropic,
              contextWindow: 200_000, maxOutputTokens: 64_000),
        .init(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", provider: .anthropic,
              contextWindow: 1_000_000, maxOutputTokens: 64_000),
        // OpenAI
        .init(id: "gpt-5.5", name: "GPT-5.5", provider: .openai,
              contextWindow: 400_000, maxOutputTokens: 128_000),
        .init(id: "gpt-5.5-pro", name: "GPT-5.5 Pro", provider: .openai,
              contextWindow: 400_000, maxOutputTokens: 128_000),
        .init(id: "gpt-5.3-codex", name: "GPT-5.3 Codex", provider: .openai,
              contextWindow: 400_000, maxOutputTokens: 128_000),
        // Google
        .init(id: "gemini-3-pro-preview", name: "Gemini 3 Pro (Preview)", provider: .gemini,
              contextWindow: 1_048_576, maxOutputTokens: 65_535),
        .init(id: "gemini-3-flash-preview", name: "Gemini 3 Flash (Preview)", provider: .gemini,
              contextWindow: 1_048_576, maxOutputTokens: 65_535),
        .init(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", provider: .gemini,
              contextWindow: 1_048_576, maxOutputTokens: 65_535),
        // Moonshot / MiniMax
        .init(id: "kimi-k2.6", name: "Kimi K2.6", provider: .moonshot,
              contextWindow: 256_000, maxOutputTokens: 32_768, supportsVision: false),
        .init(id: "MiniMax-M2.7", name: "MiniMax M2.7", provider: .minimax,
              contextWindow: 204_800, maxOutputTokens: 16_384, supportsVision: false),
    ]

    static func models(for provider: AIProvider) -> [ModelInfo] {
        models.filter { $0.provider == provider }
    }

    /// All models are selectable since all providers have a sign-in path.
    static var selectableModels: [ModelInfo] { models }

    private static let defaultsKey = "universe.selectedModel"

    @Published var selectedModelID: String {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: Self.defaultsKey) }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        // Fall back when a stored ID disappears from the catalog after an update.
        selectedModelID = Self.selectableModels.contains { $0.id == stored }
            ? stored!
            : Self.selectableModels[0].id
    }

    var selectedModel: ModelInfo {
        Self.models.first { $0.id == selectedModelID } ?? Self.selectableModels[0]
    }

    func isConnected(_ provider: AIProvider) -> Bool { ProviderStore.isConnected(provider) }
}
