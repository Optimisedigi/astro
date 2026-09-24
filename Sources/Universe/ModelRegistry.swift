import Foundation

/// Providers and models, in the shape tama-agent uses (`AIProvider` + `ModelInfo`),
/// extended with the anti-social catalog (Kimi For Coding OAuth, Xiaomi MiMo).
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case gemini
    case kimi
    case moonshot
    case minimax
    case xiaomi
    case xiaomiAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .kimi: return "Kimi"
        case .moonshot: return "Moonshot"
        case .minimax: return "MiniMax"
        case .xiaomi: return "MiMo Token Plan"
        case .xiaomiAPI: return "MiMo API credits"
        }
    }

    var summary: String {
        switch self {
        case .anthropic: return "Claude Opus 5.5 / Sonnet 5 (via Claude account)"
        case .openai: return "GPT-6 Astra / Sol / Luna (via ChatGPT account)"
        case .gemini: return "Gemini 3 Pro / Flash (via Google account)"
        case .kimi: return "Kimi K3 / For Coding (subscription)"
        case .moonshot: return "Kimi K2.6 (API key)"
        case .minimax: return "MiniMax M2.7"
        case .xiaomi: return "mimo-v2.5-pro"
        case .xiaomiAPI: return "mimo-v2.5-pro-ultraspeed"
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

    /// Anthropic and OpenAI IDs checked against the vendors' model pages on
    /// 24 Sep 2026 (`claude-opus-5-5`; `gpt-6-astra`, `gpt-6-sol`, `gpt-6-luna`).
    /// The rest carry tama-agent's IDs forward.
    static let models: [ModelInfo] = [
        // Anthropic
        .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", provider: .anthropic,
              contextWindow: 1_000_000, maxOutputTokens: 64_000),
        .init(id: "claude-opus-5-5", name: "Claude Opus 5.5", provider: .anthropic,
              contextWindow: 1_000_000, maxOutputTokens: 64_000),
        .init(id: "claude-opus-5", name: "Claude Opus 5", provider: .anthropic,
              contextWindow: 1_000_000, maxOutputTokens: 64_000),
        .init(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", provider: .anthropic,
              contextWindow: 200_000, maxOutputTokens: 64_000),
        .init(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", provider: .anthropic,
              contextWindow: 1_000_000, maxOutputTokens: 64_000),
        // OpenAI (ChatGPT plan). Sol first: it is the fallback for OpenAI and
        // is on every paid plan; Astra needs Plus or above, Luna is the fast tier.
        .init(id: "gpt-6-sol", name: "GPT-6 Sol", provider: .openai,
              contextWindow: 1_050_000, maxOutputTokens: 128_000),
        .init(id: "gpt-6-astra", name: "GPT-6 Astra", provider: .openai,
              contextWindow: 1_050_000, maxOutputTokens: 128_000),
        .init(id: "gpt-6-luna", name: "GPT-6 Luna", provider: .openai,
              contextWindow: 1_050_000, maxOutputTokens: 128_000),
        .init(id: "gpt-5.5", name: "GPT-5.5", provider: .openai,
              contextWindow: 400_000, maxOutputTokens: 128_000),
        // Google
        .init(id: "gemini-3-pro-preview", name: "Gemini 3 Pro (Preview)", provider: .gemini,
              contextWindow: 1_048_576, maxOutputTokens: 65_535),
        .init(id: "gemini-3-flash-preview", name: "Gemini 3 Flash (Preview)", provider: .gemini,
              contextWindow: 1_048_576, maxOutputTokens: 65_535),
        .init(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", provider: .gemini,
              contextWindow: 1_048_576, maxOutputTokens: 65_535),
        // Kimi For Coding (OAuth subscription)
        .init(id: "k3", name: "Kimi K3", provider: .kimi,
              contextWindow: 1_000_000, maxOutputTokens: 32_768, supportsVision: false),
        .init(id: "kimi-for-coding", name: "Kimi For Coding", provider: .kimi,
              contextWindow: 256_000, maxOutputTokens: 32_768, supportsVision: false),
        // Moonshot billed API-key fallback for the OAuth path
        .init(id: "kimi-k2.6", name: "Kimi K2.6", provider: .moonshot,
              contextWindow: 256_000, maxOutputTokens: 32_768, supportsVision: false),
        .init(id: "MiniMax-M2.7", name: "MiniMax M2.7", provider: .minimax,
              contextWindow: 204_800, maxOutputTokens: 16_384, supportsVision: false),
        // Xiaomi MiMo (OpenAI-compatible API key)
        .init(id: "mimo-v2.5-pro", name: "MiMo v2.5 Pro", provider: .xiaomi,
              contextWindow: 1_000_000, maxOutputTokens: 32_768, supportsVision: false),
        .init(id: "mimo-v2.5-pro-ultraspeed", name: "MiMo v2.5 Pro UltraSpeed", provider: .xiaomiAPI,
              contextWindow: 1_000_000, maxOutputTokens: 32_768, supportsVision: false),
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

    /// Selected model first, then every other connected model's first catalog entry.
    /// A failed stream walks this list; context-overflow stops it.
    func fallbackChain() -> [ModelInfo] {
        let selected = selectedModel
        var chain: [ModelInfo] = []
        var seenProviders: Set<AIProvider> = []
        if ProviderStore.isConnected(selected.provider) {
            chain.append(selected)
            seenProviders.insert(selected.provider)
        }
        for provider in AIProvider.allCases where !seenProviders.contains(provider) {
            guard ProviderStore.isConnected(provider),
                  let model = Self.models.first(where: { $0.provider == provider }) else { continue }
            chain.append(model)
            seenProviders.insert(provider)
        }
        // Empty chain still tries the selected model so the stream surfaces
        // "not signed in" instead of silently doing nothing.
        return chain.isEmpty ? [selected] : chain
    }
}
