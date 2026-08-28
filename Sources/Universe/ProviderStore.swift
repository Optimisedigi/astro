import Foundation

/// Unified credential store for all providers.
///
/// OAuth tokens live in per-provider Keychain accounts (AnthropicOAuth.TokenStore,
/// OpenAIOAuth.TokenStore, GeminiOAuth.TokenStore, KimiOAuth.TokenStore). API-key
/// providers (Moonshot, MiniMax, MiMo) use a separate Keychain account. This enum
/// is the single place that answers "is this provider connected?" and "give me a
/// usable token/key".
enum ProviderStore {
    /// API keys for providers that don't support OAuth.
    enum APIKeyStore {
        private static func account(for provider: AIProvider) -> String { "apikey-\(provider.rawValue)" }

        static func get(_ provider: AIProvider) -> String? {
            KeychainHelper.get(account: account(for: provider))
        }

        static func set(_ key: String, for provider: AIProvider) {
            KeychainHelper.set(key, account: account(for: provider))
        }

        static func clear(_ provider: AIProvider) {
            KeychainHelper.remove(account: account(for: provider))
        }
    }

    /// Whether the provider has any credential at all.
    static func isConnected(_ provider: AIProvider) -> Bool {
        switch provider {
        case .anthropic:
            return AnthropicOAuth.isSignedIn || !(KeychainHelper.get(account: "anthropic")?.isEmpty ?? true)
        case .openai:
            return OpenAIOAuth.isSignedIn
        case .gemini:
            return GeminiOAuth.isSignedIn
        case .kimi:
            return KimiOAuth.isSignedIn
        case .moonshot:
            return !(APIKeyStore.get(.moonshot)?.isEmpty ?? true)
        case .minimax:
            return !(APIKeyStore.get(.minimax)?.isEmpty ?? true)
        case .xiaomi:
            return !(APIKeyStore.get(.xiaomi)?.isEmpty ?? true)
        case .xiaomiAPI:
            return !(APIKeyStore.get(.xiaomiAPI)?.isEmpty ?? true)
        }
    }

    /// Returns a usable access token or API key for the provider, refreshing if needed.
    static func validCredential(for provider: AIProvider) async throws -> String? {
        switch provider {
        case .anthropic:
            if let token = try await AnthropicOAuth.validAccessToken() { return token }
            return APIKeyStore.get(.anthropic)
        case .openai:
            return try await OpenAIOAuth.validAccessToken()
        case .gemini:
            return try await GeminiOAuth.validAccessToken()
        case .kimi:
            return try await KimiOAuth.validAccessToken()
        case .moonshot:
            return APIKeyStore.get(.moonshot)
        case .minimax:
            return APIKeyStore.get(.minimax)
        case .xiaomi:
            return APIKeyStore.get(.xiaomi)
        case .xiaomiAPI:
            return APIKeyStore.get(.xiaomiAPI)
        }
    }

    /// Sign out / disconnect a provider.
    static func disconnect(_ provider: AIProvider) {
        switch provider {
        case .anthropic:
            AnthropicOAuth.signOut()
            APIKeyStore.clear(.anthropic)
        case .openai:
            OpenAIOAuth.signOut()
        case .gemini:
            GeminiOAuth.signOut()
        case .kimi:
            KimiOAuth.signOut()
        case .moonshot:
            APIKeyStore.clear(.moonshot)
        case .minimax:
            APIKeyStore.clear(.minimax)
        case .xiaomi:
            APIKeyStore.clear(.xiaomi)
        case .xiaomiAPI:
            APIKeyStore.clear(.xiaomiAPI)
        }
    }
}
