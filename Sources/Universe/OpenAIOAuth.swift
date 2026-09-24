import AppKit
import CryptoKit
import Foundation

/// OpenAI PKCE OAuth — same client ID and flow as tama-agent.
///
/// Unlike Anthropic's paste-code flow, OpenAI's redirect URI points at a loopback
/// server (`http://localhost:1455/auth/callback`), so the browser hands the code
/// straight back to us.
///
/// Security posture:
///  - Client ID, redirect URI and token endpoint are compile-time constants.
///  - Verifier and state are 32 CSPRNG bytes each; state is compared before the code
///    is ever exchanged.
///  - Tokens live only in the Keychain (device-only, after-first-unlock).
///  - The access token is a JWT; we extract the `chatgpt_account_id` from it for the
///    Codex endpoint, but never log or persist the JWT payload.
enum OpenAIOAuth {
    private nonisolated static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private nonisolated static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    private nonisolated static let tokenURL = "https://auth.openai.com/oauth/token"
    private nonisolated static let redirectURI = "http://localhost:1455/auth/callback"
    private nonisolated static let callbackPath = "/auth/callback"
    private nonisolated static let callbackPort: UInt16 = 1455
    private nonisolated static let scope = "openid profile email offline_access"

    enum OAuthError: LocalizedError {
        case noAccountId
        case server(String)

        var errorDescription: String? {
            switch self {
            case .noAccountId: return "Could not extract account ID from OpenAI token."
            case .server(let detail): return "OpenAI rejected the sign-in: \(detail)"
            }
        }
    }

    // MARK: - Public API

    static func authenticate() async throws {
        let verifier = randomURLSafeString()
        let state = randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: "universe"),
        ]

        let code = try await LoopbackOAuthServer.awaitCode(
            authorizeURL: components.url!,
            port: callbackPort,
            path: callbackPath,
            expectedState: state
        )

        let tokens = try await exchangeCode(code, verifier: verifier)
        TokenStore.save(tokens)
    }

    static func validAccessToken() async throws -> String? {
        guard let tokens = TokenStore.load() else { return nil }
        guard tokens.needsRefresh else { return tokens.accessToken }
        guard let refreshToken = tokens.refreshToken else { return tokens.accessToken }

        do {
            let refreshed = try await refresh(refreshToken: refreshToken)
            TokenStore.save(refreshed)
            return refreshed.accessToken
        } catch {
            return tokens.isExpired ? nil : tokens.accessToken
        }
    }

    /// A fresh access token plus the ChatGPT account it belongs to — the pair
    /// every subscription-billed endpoint needs.
    static func validCredentials() async throws -> (accessToken: String, accountId: String)? {
        guard let token = try await validAccessToken(),
              let accountId = TokenStore.load()?.accountId
        else { return nil }
        return (token, accountId)
    }

    static func signOut() { TokenStore.clear() }
    static var isSignedIn: Bool { TokenStore.load() != nil }

    // MARK: - Token Exchange

    private static func exchangeCode(_ code: String, verifier: String) async throws -> Tokens {
        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "client_id", value: clientID),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_verifier", value: verifier),
        ]
        return try await postToken(body: body)
    }

    private static func refresh(refreshToken: String) async throws -> Tokens {
        var body = URLComponents()
        body.queryItems = [
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "client_id", value: clientID),
        ]
        return try await postToken(body: body)
    }

    private static func postToken(body: URLComponents) async throws -> Tokens {
        var request = URLRequest(url: URL(string: tokenURL)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (json["error_description"] as? String)
                ?? (json["error"] as? String)
                ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw OAuthError.server(String(detail.prefix(200)))
        }
        guard let tokens = Tokens(json: json) else { throw OAuthError.server("unexpected response") }
        return tokens
    }

    // MARK: - Tokens

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var accountId: String

        var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 300 }
        var isExpired: Bool { expiresAt <= Date() }

        init?(json: [String: Any]) {
            guard let access = json["access_token"] as? String, !access.isEmpty,
                  let refresh = json["refresh_token"] as? String, !refresh.isEmpty,
                  let expiresIn = json["expires_in"] as? Int
            else { return nil }
            guard let accountID = extractAccountId(from: access) else { return nil }
            accessToken = access
            refreshToken = refresh
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            accountId = accountID
        }
    }

    /// Extract `chatgpt_account_id` from the JWT access token payload.
    private static func extractAccountId(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any],
              let accountId = auth["chatgpt_account_id"] as? String, !accountId.isEmpty
        else { return nil }
        return accountId
    }

    enum TokenStore {
        private static let account = "openai-oauth"

        static func save(_ tokens: Tokens) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(tokens),
                  let string = String(data: data, encoding: .utf8) else { return }
            KeychainHelper.set(string, account: account)
        }

        static func load() -> Tokens? {
            guard let string = KeychainHelper.get(account: account),
                  let data = string.data(using: .utf8) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Tokens.self, from: data)
        }

        static func clear() { KeychainHelper.remove(account: account) }
    }

    // MARK: - Primitives

    private static func randomURLSafeString(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            fatalError("Universe: system CSPRNG unavailable")
        }
        return Data(bytes).base64URLEncodedString()
    }
}
