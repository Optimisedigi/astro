import Foundation
import os

private let logger = Logger(subsystem: "com.universe.app", category: "gptlive.call")

/// A notch voice call on OpenAI GPT‑Live 1 (`gpt-live-1-codex`), billed to the
/// user's ChatGPT plan.
///
/// Flow:
/// 1. Build a WebRTC audio offer and POST it with the session to ChatGPT's call
///    endpoint using the ChatGPT sign-in; the reply is the SDP answer and a call id.
/// 2. Open the call's sideband WebSocket for transcripts and delegations.
/// 3. Each delegation runs through Universe's normal agent (the chat model plus
///    the call tools); its answer goes back on the speakable channel and
///    GPT‑Live says it in its own words.
@MainActor
final class GPTLiveCallSession: VoiceCallSession {
    private let voice: String
    private let urlSession: URLSession
    private let agentLoop = AgentLoop.withRegistry(ToolRegistry.callRegistry())

    private var peer: (any GPTLiveAudioPeer)?
    private var sideband: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Never>?
    private var delegationTask: Task<Void, Never>?
    private var activeImageID: String?
    private var isActive = false
    private var suspendedChatVoiceMode = false
    private var chatSession: ChatSession?
    /// The conversation as handed to the agent on each delegation.
    private var transcript: [[String: Any]] = []
    /// The same conversation as shown in the panel and saved to Chats.
    private var lines: [Session.Message] = []

    init(voice: String, urlSession: URLSession = .shared) {
        self.voice = voice
        self.urlSession = urlSession
    }

    // MARK: - VoiceCallSession

    func start() {
        guard !isActive else { return }
        isActive = true
        logger.info("━━━ GPT-LIVE CALL START (\(self.voice, privacy: .public)) ━━━")

        // Saved when the call ends, and only if something was said, so each
        // ⌥Space open does not leave an empty "Voice Call" in Chats.
        chatSession = ChatSession(
            id: UUID(), title: "Voice Call", messages: [],
            createdAt: Date(), updatedAt: Date(), sessionType: .chat
        )

        NotchCallTimer.setMode(.responding)
        NotchCallTimer.setAudioLevel(0)
        // WebRTC owns the mic for the call; pause chat mic mode like the diary does.
        PanelController.shared.chatState.suspendVoiceMode()
        suspendedChatVoiceMode = true

        connectTask = Task { [weak self] in await self?.connect() }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        logger.info("━━━ GPT-LIVE CALL END ━━━")
        connectTask?.cancel()
        connectTask = nil
        delegationTask?.cancel()
        delegationTask = nil
        stopImageProgress()
        if let sideband {
            sideband.send(.string(#"{"type":"session.close"}"#)) { _ in }
            sideband.cancel(with: .normalClosure, reason: nil)
        }
        sideband = nil
        peer?.close()
        peer = nil
        NotchActivityIndicator.removeProcess(id: "call-agent")
        saveSession()
        if suspendedChatVoiceMode {
            suspendedChatVoiceMode = false
            PanelController.shared.chatState.resumeVoiceModeIfSuspended()
        }
    }

    // MARK: - Connect

    private func connect() async {
        let started = CFAbsoluteTimeGetCurrent()
        do {
            guard let credentials = try await OpenAIOAuth.validCredentials() else {
                throw RealtimeCallError.notSignedIn
            }
            let peer = try makeGPTLiveAudioPeer()
            peer.onFailure = { [weak self] message in
                self?.fail(RealtimeCallError.rejected(status: 0, message: message))
            }
            self.peer = peer
            let offer = try await peer.makeOffer()
            guard isActive else { return }

            let ids = GPTLiveProtocol.RequestIds.fresh()
            let headers = GPTLiveProtocol.headers(
                accessToken: credentials.accessToken, accountId: credentials.accountId, ids: ids
            )
            var request = URLRequest(url: GPTLiveProtocol.callURL, timeoutInterval: 20)
            request.httpMethod = "POST"
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try GPTLiveProtocol.callRequestBody(
                offerSDP: offer,
                session: GPTLiveProtocol.session(voice: voice, persona: buildCallSystemPrompt())
            )

            let (data, response) = try await urlSession.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                logger.error("GPT-Live call creation failed: HTTP \(status)")
                throw RealtimeCallError.rejected(status: status, message: Self.errorDetail(data))
            }
            guard let answer = String(data: data, encoding: .utf8), answer.contains("v=0"),
                  let callId = GPTLiveProtocol.callId(
                      location: http?.value(forHTTPHeaderField: "Location"),
                      sessionIdHeader: http?.value(forHTTPHeaderField: "openai-session-id")
                  ),
                  let sidebandURL = GPTLiveProtocol.sidebandURL(callId: callId)
            else { throw RealtimeCallError.rejected(status: status, message: "unexpected call response") }

            try await peer.applyAnswer(answer)
            guard isActive else { return }

            var sidebandRequest = URLRequest(url: sidebandURL)
            headers.forEach { sidebandRequest.setValue($1, forHTTPHeaderField: $0) }
            let socket = urlSession.webSocketTask(with: sidebandRequest)
            sideband = socket
            socket.resume()
            receive(on: socket)

            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            logger.info("GPT-Live connected in \(ms) ms")
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    private static func errorDetail(_ data: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
            ?? json?["detail"] as? String
            ?? "call refused"
        return String(message.prefix(200))
    }

    // MARK: - Sideband

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isActive, self.sideband === socket else { return }
                    switch result {
                    case let .success(.string(text)):
                        self.handle(GPTLiveProtocol.parse(text))
                        self.receive(on: socket)
                    case .success:
                        self.receive(on: socket)
                    case let .failure(error):
                        self.fail(error)
                    }
                }
            }
        }
    }

    private func handle(_ event: GPTLiveProtocol.Event) {
        switch event {
        case .sessionStarted:
            NotchCallTimer.setMode(.listening)
        case .speaking(role: "assistant"):
            NotchCallTimer.setMode(.responding)
        case .speaking:
            NotchCallTimer.setMode(.listening)
        case .audioCleared:
            NotchCallTimer.setMode(.listening)
        case let .turnDone(role, text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                transcript.append(["role": role, "content": trimmed])
                appendLine(Session.Message(role: role, text: trimmed))
            }
            if role == "assistant" { NotchCallTimer.setMode(.listening) }
        case let .delegation(id, prompt):
            runDelegation(id: id, prompt: prompt)
        case let .error(message, fatal):
            logger.error("GPT-Live error: \(message, privacy: .public)")
            if fatal { fail(RealtimeCallError.rejected(status: 401, message: message)) }
        case let .closed(reason):
            logger.info("GPT-Live session closed: \(reason, privacy: .public)")
            NotchCallButton.endCall()
        case .ignored:
            break
        }
    }

    // MARK: - Images

    /// GPT‑Live cannot see, but the agent it delegates to can: the pictures
    /// join the history every delegation carries, and GPT‑Live is told to
    /// delegate questions about them (see `GPTLiveProtocol.instructions`).
    func share(images: [ImageAttachment]) -> Bool {
        guard isActive, !images.isEmpty else { return false }
        let turn = Self.sharedImagesTurn(images, vision: ModelRegistry.shared.selectedModel.supportsVision)
        transcript.append(turn.api)
        appendLine(turn.line)
        logger.info("Sharing \(images.count) image(s) with the GPT-Live agent")
        return true
    }

    /// The shared pictures as a user turn: API blocks for the agent (images when
    /// its model can see, otherwise the text read from them) and a panel line.
    static func sharedImagesTurn(_ images: [ImageAttachment], vision: Bool)
        -> (api: [String: Any], line: Session.Message) {
        let note = images.count == 1 ? "I've shared this image with you." : "I've shared these images with you."
        let line = Session.Message(role: "user", text: note, attachments: images)
        return (["role": "user", "content": ChatState.contentBlocks(for: line, vision: vision)], line)
    }

    private func appendLine(_ line: Session.Message) {
        lines.append(line)
        LiveVoiceState.shared.transcript = lines
    }

    // MARK: - Delegation

    private func stopImageProgress(id: String? = nil) {
        guard let activeImageID, id == nil || id == activeImageID else { return }
        LiveVoiceState.shared.imageGenerationFinished(id: activeImageID)
        self.activeImageID = nil
    }

    private func runDelegation(id: String, prompt: String?) {
        // The fallback is the last thing the user *said*: a shared picture's
        // turn holds blocks, not a string, and is already in the history.
        let request = (prompt?.isEmpty == false ? prompt : nil)
            ?? transcript.last(where: { $0["role"] as? String == "user" && $0["content"] is String })?["content"] as? String
        guard let request, !request.isEmpty else {
            send(GPTLiveProtocol.contextAppends(
                text: "Ask the user to repeat their request; nothing was heard.", delegationId: id
            ))
            return
        }
        logger.info("Delegation \(id, privacy: .public)")
        // A newer request supersedes one still running.
        delegationTask?.cancel()
        stopImageProgress()
        NotchActivityIndicator.addProcess(id: "call-agent", label: "Working")

        let history = transcript + [["role": "user", "content": request]]
        delegationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var answer = ""
            var hangUp = false
            var delegationImageID: String?
            defer {
                if let delegationImageID { self.stopImageProgress(id: delegationImageID) }
            }
            do {
                _ = try await agentLoop.run(
                    messages: history,
                    systemPrompt: buildCallSystemPrompt(),
                    useBasePrompt: false,
                    maxTokens: 600,
                    onEvent: { event in
                        guard self.isActive, !Task.isCancelled else { return }
                        switch event {
                        case let .textDelta(delta):
                            answer += delta
                        case let .toolStart(name, toolID) where name == "generate_image":
                            // Include the delegation so a cancelled, older run
                            // cannot clear a newer run with a reused tool ID.
                            let progressID = "\(id):\(toolID)"
                            delegationImageID = progressID
                            self.activeImageID = progressID
                            LiveVoiceState.shared.imageGenerationStarted(id: progressID)
                            NotchActivityIndicator.updateDetail(id: "call-agent", text: "Nebulising...")
                        case let .toolResult(name, _) where name == "generate_image":
                            if let delegationImageID { self.stopImageProgress(id: delegationImageID) }
                            delegationImageID = nil
                            NotchActivityIndicator.updateDetail(id: "call-agent", text: "Working")
                        default:
                            break
                        }
                    }
                )
            } catch is AgentEndCallError {
                hangUp = true
            } catch is CancellationError {
                return
            } catch {
                logger.error("Delegation failed: \(error.localizedDescription, privacy: .public)")
                answer = "That didn't work: \(error.localizedDescription). Tell the user briefly."
            }
            guard isActive, !Task.isCancelled else { return }
            NotchActivityIndicator.removeProcess(id: "call-agent")

            if hangUp {
                send(GPTLiveProtocol.contextAppends(text: "Say a brief goodbye; the call is ending.", delegationId: id))
                try? await Task.sleep(for: .seconds(4))
                if isActive { NotchCallButton.endCall() }
                return
            }
            let result = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            send(GPTLiveProtocol.contextAppends(
                text: GPTLiveProtocol.boundResult(result.isEmpty ? "Done." : result), delegationId: id
            ))
        }
    }

    private func send(_ events: [[String: Any]]) {
        guard let sideband else { return }
        for event in events {
            guard let data = try? JSONSerialization.data(withJSONObject: event),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            sideband.send(.string(text)) { error in
                if let error { logger.error("sideband send failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Failure & persistence

    private func fail(_ error: Error) {
        guard isActive else { return }
        logger.error("GPT-Live call failed: \(error.localizedDescription, privacy: .public)")
        NotchNotificationPresenter.showAgentReply(message: RealtimeCallError.userMessage(for: error))
        NotchCallButton.endCall()
    }

    /// Saved straight to Chats so shared pictures stay with the conversation.
    private func saveSession() {
        guard let chatSession, !lines.isEmpty else { return }
        var saved = Session(id: chatSession.id, title: chatSession.title, messages: lines)
        saved.createdAt = chatSession.createdAt
        saved.updatedAt = Date()
        SessionStore.shared.save(saved)
    }
}
