import Foundation

/// Kimi For Coding OAuth — device-code flow, matching anti-social's kimi-cli client.
///
/// Unlike Anthropic's paste-code or OpenAI's loopback PKCE, this is a true
/// device-code grant: we show a short user code, the user approves it in a
/// browser, and we poll until the token appears. Requests must carry kimi-cli
/// device headers or the API rejects them; the device id is stored so refreshes
/// reuse the same fingerprint.
enum KimiOAuth {
    private static let cliVersion = "1.36.0"
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private static let deviceAuthURL = URL(string: "https://auth.kimi.com/api/oauth/device_authorization")!
    private static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    static let apiBaseURL = "https://api.kimi.com/coding/v1"
    private static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"
    private static let requestTimeout: TimeInterval = 30
    fileprivate static let refreshSafety: TimeInterval = 60

    enum OAuthError: LocalizedError {
        case expired
        case denied
        case server(String)
        case unreachable

        var errorDescription: String? {
            switch self {
            case .expired: return "The Kimi sign-in code expired. Start again."
            case .denied: return "Kimi sign-in was denied."
            case .server(let detail): return "Kimi rejected the sign-in: \(detail)"
            case .unreachable: return "Could not reach Kimi. Check your connection and try again."
            }
        }
    }

    struct DeviceAuth {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let interval: TimeInterval
        let expiresAt: Date
        let deviceId: String
    }

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var deviceId: String

        var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < KimiOAuth.refreshSafety }
        var isExpired: Bool { expiresAt <= Date() }
    }

    // MARK: - Public API

    static var isSignedIn: Bool { TokenStore.load() != nil }

    static func beginLogin() async throws -> DeviceAuth {
        let deviceId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let json = try await postForm(deviceAuthURL, params: ["client_id": clientID], deviceId: deviceId)
        guard let deviceCode = json["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = json["user_code"] as? String, !userCode.isEmpty,
              let uriString = (json["verification_uri_complete"] as? String)
                ?? (json["verification_uri"] as? String),
              let uri = URL(string: uriString)
        else { throw OAuthError.server("unexpected device-auth response") }
        let expiresIn = (json["expires_in"] as? Double) ?? 300
        let interval = (json["interval"] as? Double) ?? 5
        return DeviceAuth(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            interval: max(interval, 1),
            expiresAt: Date().addingTimeInterval(expiresIn),
            deviceId: deviceId
        )
    }

    /// Poll until the user approves, denies, or the code expires.
    static func completeLogin(_ auth: DeviceAuth) async throws {
        while Date() < auth.expiresAt {
            do {
                let json = try await postForm(tokenURL, params: [
                    "client_id": clientID,
                    "device_code": auth.deviceCode,
                    "grant_type": deviceGrant,
                ], deviceId: auth.deviceId)
                guard let tokens = Tokens(json: json, deviceId: auth.deviceId) else {
                    throw OAuthError.server("token response missing tokens")
                }
                TokenStore.save(tokens)
                return
            } catch let error as OAuthError {
                switch error {
                case .server(let code) where code == "authorization_pending":
                    try await Task.sleep(for: .seconds(auth.interval))
                    continue
                case .server(let code) where code == "slow_down":
                    try await Task.sleep(for: .seconds(auth.interval + 2))
                    continue
                case .server(let code) where code == "expired_token":
                    throw OAuthError.expired
                case .server(let code) where code == "access_denied":
                    throw OAuthError.denied
                default:
                    throw error
                }
            }
        }
        throw OAuthError.expired
    }

    static func validAccessToken() async throws -> String? {
        guard var tokens = TokenStore.load() else { return nil }
        guard tokens.needsRefresh else { return tokens.accessToken }
        do {
            tokens = try await refresh(tokens)
            TokenStore.save(tokens)
            return tokens.accessToken
        } catch {
            return tokens.isExpired ? nil : tokens.accessToken
        }
    }

    static func signOut() { TokenStore.clear() }

    static func requestHeaders(accessToken: String, extra: [String: String] = [:]) -> [String: String] {
        var headers = deviceHeaders(deviceId: TokenStore.load()?.deviceId)
        headers["Authorization"] = "Bearer \(accessToken)"
        for (k, v) in extra { headers[k] = v }
        return headers
    }

    // MARK: - Refresh

    private static func refresh(_ tokens: Tokens) async throws -> Tokens {
        let json = try await postForm(tokenURL, params: [
            "client_id": clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ], deviceId: tokens.deviceId)
        guard var refreshed = Tokens(json: json, deviceId: tokens.deviceId) else {
            throw OAuthError.server("refresh response missing tokens")
        }
        if refreshed.refreshToken.isEmpty { refreshed.refreshToken = tokens.refreshToken }
        return refreshed
    }

    // MARK: - HTTP

    private static func postForm(_ url: URL, params: [String: String], deviceId: String) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        for (k, v) in deviceHeaders(deviceId: deviceId) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = params
            .map { "\(urlEncoded($0.key))=\(urlEncoded($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OAuthError.unreachable
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let http = response as? HTTPURLResponse
        if let http, (200..<300).contains(http.statusCode) { return json }
        let code = (json["error"] as? String)
            ?? "HTTP \(http?.statusCode ?? 0)"
        throw OAuthError.server(String(code.prefix(200)))
    }

    private static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func deviceHeaders(deviceId: String?) -> [String: String] {
        let id = deviceId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return [
            "User-Agent": "KimiCLI/\(cliVersion)",
            "X-Msh-Platform": "kimi_cli",
            "X-Msh-Version": cliVersion,
            "X-Msh-Device-Name": asciiHeader(Host.current().localizedName ?? "unknown"),
            "X-Msh-Device-Model": asciiHeader(kimiDeviceModel()),
            "X-Msh-Device-Id": id,
            "X-Msh-Os-Version": asciiHeader(ProcessInfo.processInfo.operatingSystemVersionString),
        ]
    }

    private static func kimiDeviceModel() -> String {
        let info = ProcessInfo.processInfo
        let release = "\(info.operatingSystemVersion.majorVersion).\(info.operatingSystemVersion.minorVersion)"
        return "macOS \(release) \(unameMachine())"
    }

    private static func unameMachine() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }

    private static func asciiHeader(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7e }
        let trimmed = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    // MARK: - Store

    enum TokenStore {
        private static let account = "kimi-oauth"

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
}

extension KimiOAuth.Tokens {
    init?(json: [String: Any], deviceId: String) {
        guard let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        accessToken = access
        refreshToken = json["refresh_token"] as? String ?? ""
        let lifetime = (json["expires_in"] as? Double) ?? 3600
        expiresAt = Date().addingTimeInterval(lifetime - 60)
        self.deviceId = deviceId
    }
}
