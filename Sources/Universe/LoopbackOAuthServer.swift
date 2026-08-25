import AppKit
import Foundation
import Network

/// A one-shot loopback HTTP listener for OAuth redirects.
///
/// OpenAI and Google register `http://localhost:<port>/...` as their redirect URI, so
/// unlike Anthropic's paste-code flow the browser hands the code straight back to us.
///
/// Security posture:
///  - Binds loopback only, serves exactly one request, then closes. It is not a server.
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
                    defer { listener.cancel() }
                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        connection.cancel()
                        return
                    }

                    let outcome = parseCallback(request, expectedPath: path, expectedState: expectedState)
                    respond(on: connection, success: outcome.code != nil, message: outcome.error)

                    guard once.claim() else { return }
                    if let code = outcome.code {
                        continuation.resume(returning: code)
                    } else {
                        continuation.resume(throwing: ServerError.cancelled(outcome.error ?? "no authorization code"))
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

    /// Parses the request line of the browser's redirect.
    /// Returns a code only when the path matches and the state is exactly the one we issued.
    static func parseCallback(
        _ raw: String,
        expectedPath: String,
        expectedState: String
    ) -> (code: String?, error: String?) {
        guard let requestLine = raw.split(whereSeparator: \.isNewline).first,
              let start = requestLine.range(of: " /"),
              let end = requestLine.range(of: " HTTP"),
              start.upperBound <= end.lowerBound else {
            return (nil, "malformed request")
        }

        let target = String(requestLine[start.upperBound..<end.lowerBound])
        guard let components = URLComponents(string: target) else { return (nil, "malformed callback URL") }
        // Browsers also fetch /favicon.ico on the same port; ignore anything else.
        guard components.path == expectedPath else { return (nil, "unexpected callback path") }

        let items = components.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        guard AnthropicOAuth.constantTimeEquals(state, expectedState) else {
            return (nil, "state mismatch")
        }
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return (code, nil)
        }
        let reason = items.first { $0.name == "error_description" }?.value
            ?? items.first { $0.name == "error" }?.value
        return (nil, reason.map { String($0.prefix(200)) } ?? "no authorization code")
    }

    private static func respond(on connection: NWConnection, success: Bool, message: String?) {
        let title = success ? "Signed in" : "Sign-in failed"
        let detail = success ? "You can close this tab and go back to Universe." : (message ?? "Unknown error")
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
