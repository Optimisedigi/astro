import AppKit
import Foundation
import Network

/// A one-shot loopback HTTP listener for OAuth redirects.
///
/// OpenAI and Google register `http://localhost:<port>/...` as their redirect URI, so
/// unlike Anthropic's paste-code flow the browser hands the code straight back to us.
///
/// Security posture:
///  - Binds loopback only and closes as soon as the callback arrives. Stray requests
///    (a browser's favicon fetch) get a 404 and do not end sign-in. It is not a server.
///  - `state` is compared before the code is accepted, so a request forged by another
///    local process (the port is reachable by anything on the machine) is rejected.
///  - The request is size-capped and only the query string is parsed; nothing is executed.
///  - Always times out, so a user who abandons the browser tab does not leak a listener.
enum LoopbackOAuthServer {
    enum ServerError: LocalizedError {
        case portUnavailable(UInt16, String)
        case cancelled(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .portUnavailable(let port, let detail):
                return "Could not listen on port \(port): \(detail). Quit whatever is using it and try again."
            case .cancelled(let detail):
                return "Sign-in did not complete: \(detail)"
            case .timedOut:
                return "Sign-in timed out. Try again."
            }
        }
    }

    /// Opens `authorizeURL` in the browser and resolves with the returned `code`.
    static func awaitCode(
        authorizeURL: URL,
        port: UInt16,
        path: String,
        expectedState: String,
        timeout: TimeInterval = 120
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            } catch {
                continuation.resume(throwing: ServerError.portUnavailable(port, error.localizedDescription))
                return
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                // 8 KB is far more than a redirect needs; anything larger is not our callback.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        connection.cancel()
                        return
                    }

                    let outcome = parseCallback(request, expectedPath: path, expectedState: expectedState)
                    switch outcome {
                    case .ignore:
                        // Not the redirect: keep listening for the real one.
                        respondNotFound(on: connection)
                    case let .code(code):
                        respond(on: connection, success: true, message: nil)
                        listener.cancel()
                        guard once.claim() else { return }
                        continuation.resume(returning: code)
                    case let .failure(reason):
                        respond(on: connection, success: false, message: reason)
                        listener.cancel()
                        guard once.claim() else { return }
                        continuation.resume(throwing: ServerError.cancelled(reason))
                    }
                }
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSWorkspace.shared.open(authorizeURL)
                case .failed(let error):
                    guard once.claim() else { return }
                    listener.cancel()
                    continuation.resume(throwing: ServerError.portUnavailable(port, error.localizedDescription))
                default:
                    break
                }
            }

            listener.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                listener.cancel()
                continuation.resume(throwing: ServerError.timedOut)
            }
        }
    }

    /// What one incoming request means for the sign-in.
    enum Callback: Equatable {
        /// The redirect, carrying our state and an authorization code.
        case code(String)
        /// The redirect, but it failed: wrong state, or the provider reported an error.
        case failure(String)
        /// Some other request (favicon, malformed): answer 404 and keep waiting.
        case ignore
    }

    /// Parses the request line of the browser's redirect, e.g.
    /// `GET /auth/callback?code=…&state=… HTTP/1.1`.
    /// Returns a code only when the path matches and the state is exactly the one we issued.
    static func parseCallback(
        _ raw: String,
        expectedPath: String,
        expectedState: String
    ) -> Callback {
        guard let requestLine = raw.split(whereSeparator: \.isNewline).first else { return .ignore }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "GET", parts[1].hasPrefix("/"),
              let components = URLComponents(string: String(parts[1])),
              components.path == expectedPath
        else { return .ignore }

        let items = components.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        guard AnthropicOAuth.constantTimeEquals(state, expectedState) else {
            return .failure("state mismatch")
        }
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return .code(code)
        }
        let reason = items.first { $0.name == "error_description" }?.value
            ?? items.first { $0.name == "error" }?.value
        return .failure(reason.map { String($0.prefix(200)) } ?? "no authorization code")
    }

    private static func respondNotFound(on connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func respond(on connection: NWConnection, success: Bool, message: String?) {
        let title = success ? "Signed in" : "Sign-in failed"
        let detail = success ? "You can close this tab and go back to Astro." : (message ?? "Unknown error")
        // The detail can echo a provider string, so escape it rather than interpolating raw.
        let body = """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <body style="font-family:-apple-system,sans-serif;text-align:center;padding-top:80px">
        <h1>\(escapeHTML(title))</h1><p>\(escapeHTML(detail))</p></body>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A continuation must resume exactly once; timeout and callback race here.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}
