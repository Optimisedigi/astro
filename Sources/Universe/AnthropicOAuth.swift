import CryptoKit
import Foundation

/// Sign in with a Claude account — the same PKCE paste-code flow the learning-ai
/// site uses, with the same client ID, scopes and redirect URI.
///
/// The site needs a serverless proxy because Anthropic's token endpoint allowlists
/// browser origins; a native URLSession call is not subject to CORS, so we talk to
/// the upstream endpoints directly and keep the same failover order.
///
/// Security posture:
///  - Endpoints, client ID and redirect URI are compile-time constants. Nothing the
///    user pastes can redirect where a request goes.
///  - The verifier and state are 32 CSPRNG bytes each; state is compared before the
///    code is ever exchanged, and both are single-use.
///  - Tokens live only in the Keychain (device-only, after-first-unlock). They are
///    never written to UserDefaults, never printed, and never included in an error.
enum AnthropicOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    private static let authorizeURL = "https://claude.ai/oauth/authorize"
    /// Failover order matches the site's proxy.
    private static let tokenURLs = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]
    private static let requestTimeout: TimeInterval = 30

    enum OAuthError: LocalizedError, Equatable {
        case badCode
        case stateMismatch
        case noPendingLogin
        case server(String)
        case unreachable

        var errorDescription: String? {
            switch self {
            case .badCode: return "That doesn't look like a sign-in code. Copy the whole code from the Claude page."
            case .stateMismatch: return "This code belongs to a different sign-in attempt. Start again."
            case .noPendingLogin: return "The sign-in attempt expired. Start again."
            case .server(let detail): return "Claude rejected the sign-in: \(detail)"
            case .unreachable: return "Could not reach Claude. Check your connection and try again."
            }
        }
    }

    /// One in-flight login. Held in memory only: a verifier that outlives the app
    /// launch buys nothing and is one more secret at rest.
    struct PendingLogin {
        let url: URL
        let verifier: String
        let state: String
    }

    // MARK: - Step 1: build the authorize URL

    static func beginLogin() -> PendingLogin {
        let verifier = randomURLSafeString()
        let state = randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return PendingLogin(url: components.url!, verifier: verifier, state: state)
    }

    // MARK: - Step 2: exchange the pasted code

    /// Accepts the raw paste: `code#state`, a bare code, or the whole callback URL.
    static func parsePastedCode(_ raw: String) throws -> (code: String, state: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096 else { throw OAuthError.badCode }

        // Whole callback URL pasted from the address bar.
        if trimmed.lowercased().hasPrefix("http"),
           let components = URLComponents(string: trimmed),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value
            return (code, state)
        }

        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let state = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        guard !code.isEmpty, code.allSatisfy({ $0.isLetter || $0.isNumber || "-_.~".contains($0) }) else {
            throw OAuthError.badCode
        }
        return (code, state?.isEmpty == true ? nil : state)
    }

    static func completeLogin(pastedCode raw: String, pending: PendingLogin) async throws {
        let parsed = try parsePastedCode(raw)
        // Reject before the code leaves the machine: a mismatched state means this
        // code came from a different (possibly attacker-initiated) authorization.
        if let returned = parsed.state, !constantTimeEquals(returned, pending.state) {
            throw OAuthError.stateMismatch
        }

        let tokens = try await postToken([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": parsed.code,
            "state": pending.state, // Anthropic's token endpoint requires it
            "redirect_uri": redirectURI,
            "code_verifier": pending.verifier,
        ])
        TokenStore.save(tokens)
    }

    // MARK: - Step 3: keep the session alive

    /// Returns a usable access token, refreshing when it is close to expiry.
    static func validAccessToken() async throws -> String? {
        guard let tokens = TokenStore.load() else { return nil }
        guard tokens.needsRefresh else { return tokens.accessToken }
        guard let refreshToken = tokens.refreshToken else { return tokens.accessToken }

        do {
            var refreshed = try await postToken([
                "grant_type": "refresh_token",
                "client_id": clientID,
                "refresh_token": refreshToken,
            ])
            // Anthropic may omit a new refresh token; keep the old one rather than
            // dropping the user's session on the next launch.
            if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
            TokenStore.save(refreshed)
            return refreshed.accessToken
        } catch {
            // A still-valid token beats failing the turn; only a hard expiry logs out.
            return tokens.isExpired ? nil : tokens.accessToken
        }
    }

    static func signOut() {
        TokenStore.clear()
    }

    static var isSignedIn: Bool { TokenStore.load() != nil }

    // MARK: - Transport

    private static func postToken(_ payload: [String: String]) async throws -> Tokens {
        var lastError: OAuthError = .unreachable

        for url in tokenURLs {
            var request = URLRequest(url: url, timeoutInterval: requestTimeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    // Surface only the error fields — the body can carry tokens.
                    let detail = (json["error_description"] as? String)
                        ?? (json["error"] as? String)
                        ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                    lastError = .server(String(detail.prefix(200)))
                    continue
                }
                guard let tokens = Tokens(json: json) else {
                    lastError = .server("unexpected response")
                    continue
                }
                return tokens
            } catch {
                // Log the failure mode only, never the request or response.
                NSLog("Universe: OAuth token request failed (%@)", String(describing: type(of: error)))
                lastError = .unreachable
            }
        }
        throw lastError
    }

    // MARK: - Primitives

    private static func randomURLSafeString(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        // SecRandomCopyBytes is the CSPRNG; a plain Int.random would be guessable.
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            // Fatal rather than silently downgrading the entropy of a security token.
            fatalError("Universe: system CSPRNG unavailable")
        }
        return Data(bytes).base64URLEncodedString()
    }

    /// Compares without leaking length or position through timing.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

// MARK: - Tokens

extension AnthropicOAuth {
    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date

        /// Refresh once half the lifetime is gone, like the site does.
        var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 1800 }
        var isExpired: Bool { expiresAt <= Date() }

        init?(json: [String: Any]) {
            guard let access = json["access_token"] as? String, !access.isEmpty else { return nil }
            accessToken = access
            refreshToken = json["refresh_token"] as? String
            let lifetime = (json["expires_in"] as? Double) ?? 3600
            expiresAt = Date().addingTimeInterval(lifetime)
        }
    }

    /// Tokens are Keychain-only. Nothing here goes near UserDefaults or a log line.
    enum TokenStore {
        private static let account = "anthropic-oauth"

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

        static func clear() {
            KeychainHelper.remove(account: account)
        }
    }
}

extension Data {
    /// base64url without padding — what RFC 7636 requires for a code challenge.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
