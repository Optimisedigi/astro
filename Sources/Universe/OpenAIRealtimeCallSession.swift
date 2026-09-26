import Foundation
import os

private let logger = Logger(subsystem: "com.universe.app", category: "realtime.call")

/// A notch voice call powered by OpenAI's speech-to-speech Realtime model,
/// billed to the user's ChatGPT plan through the OpenAI sign-in.
///
/// Flow:
/// 1. Mint a short-lived client secret at `/v1/realtime/client_secrets` using the
///    ChatGPT OAuth token. The full session (instructions, voice, tools) is fixed
///    here, so the long-lived token never touches the audio socket.
/// 2. Open `wss://api.openai.com/v1/realtime` with that secret and stream
///    24 kHz PCM16 both ways. Server-side voice activity detection decides turns
///    and cancels the reply when the user talks over it.
/// 3. Function calls run through Universe's own `ToolRegistry`, so the live
///    voice can use the same tools as chat (memory, reminders, web, files…).
@MainActor
final class OpenAIRealtimeCallSession: VoiceCallSession {
    private static let clientSecretsURL = URL(string: "https://api.openai.com/v1/realtime/client_secrets")!
    private static let socketBase = "wss://api.openai.com/v1/realtime"
    private static let endCallTool = "end_call"

    private let model: String
    private let voice: String
    private let urlSession: URLSession
    /// Shared and kept ready between calls, so the mic opens in about 0.1 s.
    private let audio = RealtimeAudioIO.shared
    /// Mic audio recorded while the connection is still being set up.
    private let micRelay = MicChunkRelay()
    /// Finishes when the microphone is live; started before the network work.
    private var audioReady: Task<Void, Error>?
    /// Words for the "Ask anything" box while the user is still talking.
    private let dictation = LiveDictation()
    private let registry = ToolRegistry.callRegistry()
    private let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    private var socket: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Never>?
    private var isActive = false
    private var isHangingUp = false
    private var chatSession: ChatSession?
    private var transcript = RealtimeTranscript()
    private var runningTools = 0
    private var turns = RealtimeTurnTracker()
    /// The assistant audio item currently playing, for truncation on barge-in.
    private var playingItemId: String?
    private var playingItemReceivedMs = 0
    private var playingItemStartedAt: CFAbsoluteTime?
    private var suspendedChatVoiceMode = false
    /// The socket is up and the mic is live, so conversation items can go out.
    private var isConnected = false
    /// Pictures shared while still connecting; sent as soon as the call is up,
    /// or handed back to the panel if it never connects.
    private var queuedImages: [ImageAttachment] = []

    /// Notch calls open with a spoken greeting, like a phone call. Calls
    /// started by opening the panel skip it: the user is about to talk.
    private let greets: Bool
    var greetsOnConnect: Bool { greets }

    init(model: String, voice: String, greets: Bool = true, urlSession: URLSession = .shared) {
        self.model = model
        self.voice = voice
        self.greets = greets
        self.urlSession = urlSession
    }

    // MARK: - VoiceCallSession

    func start() {
        guard !isActive else { return }
        isActive = true
        logger.info("━━━ REALTIME CALL START (\(self.model, privacy: .public), \(self.voice, privacy: .public)) ━━━")

        // Saved when the call ends, and only if something was said, so each
        // ⌥Space open does not leave an empty "Voice Call" in Chats.
        chatSession = ChatSession(
            id: UUID(), title: "Voice Call", messages: [],
            createdAt: Date(), updatedAt: Date(), sessionType: .chat
        )

        NotchCallTimer.setMode(.responding)
        NotchCallTimer.setAudioLevel(0)

        // Chat mic mode runs its own voice-processing engine; two at once fight
        // over the mic and echo canceller, so borrow the mic like the diary does.
        PanelController.shared.chatState.suspendVoiceMode()
        suspendedChatVoiceMode = true

        // The mic starts now, alongside the sign-in and connection rather than
        // after them; what the user says meanwhile waits in `micRelay`.
        let ready = startAudio()
        audioReady = ready
        // A mic that cannot start ends the call now, not after the network.
        Task { [weak self] in
            do { try await ready.value } catch { self?.fail(error) }
        }

        connectTask = Task { [weak self] in
            await self?.connect()
        }
    }

    func end() {
        guard isActive else { return }
        isActive = false
        isConnected = false
        if !queuedImages.isEmpty {
            // The voice never saw them: back to the panel, ready to type about.
            PanelController.shared.chatState.restoreStagedImages(queuedImages)
            queuedImages = []
        }
        logger.info("━━━ REALTIME CALL END ━━━")
        connectTask?.cancel()
        connectTask = nil
        audioReady = nil
        micRelay.detach()
        audio.onMicrophoneChunk = nil
        audio.onMicrophoneBuffer = nil
        audio.onMicrophoneLevel = nil
        audio.onPlaybackDrained = nil
        audio.stop()
        dictation.stop()
        dictation.onText = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
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
            let secret = try await mintClientSecret(credentials)
            guard isActive else { return }

            var components = URLComponents(string: Self.socketBase)!
            components.queryItems = [URLQueryItem(name: "model", value: model)]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            let task = urlSession.webSocketTask(with: request)
            task.maximumMessageSize = 16 * 1024 * 1024
            socket = task
            task.resume()
            receive(on: task)
            // Sends the audio held so far, in order, then streams live.
            micRelay.attach { [weak task] base64 in
                guard let task else { return }
                let event = #"{"type":"input_audio_buffer.append","audio":""# + base64 + #""}"#
                task.send(.string(event)) { _ in }
            }

            try await audioReady?.value
            guard isActive else { return }
            isConnected = true
            let queued = queuedImages
            queuedImages = []
            if !queued.isEmpty, deliver(queued) {
                // Pictures shared while connecting open the call instead of a
                // greeting: the user started it to talk about them.
                acknowledgeImages()
            } else if greets {
                // The model speaks first so the call opens like a real phone call.
                turns.responseRequested()
                send(["type": "response.create", "response": [
                    "instructions": "Greet the user in one short, casual sentence and ask what they need.",
                ]])
            } else {
                NotchCallTimer.setMode(.listening)
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            logger.info("Connected in \(ms) ms")
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    /// Exchange the ChatGPT OAuth token for a one-minute client secret bound to
    /// this exact session configuration.
    private func mintClientSecret(_ credentials: (accessToken: String, accountId: String)) async throws -> String {
        var request = URLRequest(url: Self.clientSecretsURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = Self.sessionConfig(
            model: model, voice: voice,
            instructions: buildRealtimeInstructions(),
            tools: Self.functionTools(from: registry)
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: ["session": session])

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            logger.error("client_secrets failed: HTTP \(status)")
            throw RealtimeCallError.rejected(status: status, message: String(message.prefix(200)))
        }
        let secret = (json["value"] as? String) ?? ((json["client_secret"] as? [String: Any])?["value"] as? String)
        guard let secret, !secret.isEmpty else { throw RealtimeCallError.rejected(status: status, message: "no client secret") }
        return secret
    }

    private func startAudio() -> Task<Void, Error> {
        audio.onMicrophoneChunk = { [micRelay] base64 in micRelay.append(base64) }
        audio.onMicrophoneBuffer = { [dictation] buffer in dictation.append(pcm16: buffer) }
        dictation.onText = { [weak self] itemId, text in
            guard let self, isActive else { return }
            LiveVoiceState.shared.setDraft(itemId: itemId, text: text)
        }
        audio.onMicrophoneLevel = { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    // While the assistant talks, the mic mostly hears its echo:
                    // show silence rather than freezing on the last level.
                    let shown = self.audio.isPlaying ? 0 : level
                    NotchCallTimer.setAudioLevel(shown)
                    LiveVoiceState.shared.inputLevel = shown
                }
            }
        }
        audio.onPlaybackDrained = { [weak self] in
            guard let self, isActive else { return }
            if isHangingUp {
                NotchCallButton.endCall()
            } else {
                NotchCallTimer.setMode(.listening)
            }
        }
        return audio.start()
    }

    // MARK: - Socket

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isActive, self.socket === task else { return }
                    switch result {
                    case let .success(message):
                        if case let .string(text) = message { self.handle(text) }
                        self.receive(on: task)
                    case let .failure(error):
                        self.fail(error)
                    }
                }
            }
        }
    }

    private func send(_ event: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(text)) { error in
            if let error { logger.error("send failed: \(error.localizedDescription)") }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "response.output_audio.delta", "response.audio.delta":
            if let delta = event["delta"] as? String {
                NotchCallTimer.setMode(.responding)
                trackPlayback(itemId: event["item_id"] as? String, base64: delta)
                audio.play(base64PCM16: delta)
            }
        case "input_audio_buffer.speech_started":
            // Barge-in: the server cancels its reply; drop what is still queued
            // locally and tell the model how much of its reply was actually heard.
            truncateInterruptedAudio()
            audio.clearPlayback()
            NotchCallTimer.setMode(.listening)
            // Start writing this turn's words into the "Ask anything" box.
            if let itemId = event["item_id"] as? String {
                dictation.beginTurn(itemId: itemId)
                LiveVoiceState.shared.setDraft(itemId: itemId, text: "")
            }
        case "input_audio_buffer.speech_stopped":
            dictation.endTurn()
        case "input_audio_buffer.committed":
            // Reserve the user's slot now — the transcript often lands after the reply.
            if let itemId = event["item_id"] as? String { transcript.reserveUser(itemId: itemId) }
        case "conversation.item.input_audio_transcription.delta":
            if let itemId = event["item_id"] as? String {
                transcript.appendUserDelta(itemId: itemId, delta: event["delta"] as? String ?? "")
                // Without Apple dictation for this turn, OpenAI's words fill the box.
                if !dictation.isFollowing(itemId: itemId) {
                    LiveVoiceState.shared.setDraft(itemId: itemId, text: transcript.userText(itemId: itemId))
                }
            }
        case "conversation.item.input_audio_transcription.completed":
            if let itemId = event["item_id"] as? String {
                // The turn is done: its final text moves from the box to the conversation.
                transcript.fillUser(itemId: itemId, text: event["transcript"] as? String ?? "")
                dictation.discard(itemId: itemId)
                LiveVoiceState.shared.clearDraft(itemId: itemId)
                publishTranscript()
            }
        case "conversation.item.input_audio_transcription.failed":
            if let itemId = event["item_id"] as? String {
                // Keep what the box showed rather than losing the turn.
                let shown = LiveVoiceState.shared.draft(for: itemId)
                if !shown.isEmpty { transcript.fillUser(itemId: itemId, text: shown) }
                dictation.discard(itemId: itemId)
                LiveVoiceState.shared.clearDraft(itemId: itemId)
                publishTranscript()
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            transcript.appendAssistantDelta(event["delta"] as? String ?? "")
            publishTranscript()
        case "response.created":
            turns.responseStarted()
        case "response.done":
            transcript.finishAssistant()
            publishTranscript()
            if turns.responseFinished() { requestReply() }
        case "response.function_call_arguments.done":
            guard let callId = event["call_id"] as? String, let name = event["name"] as? String else { return }
            runTool(callId: callId, name: name, arguments: event["arguments"] as? String ?? "{}")
        case "error":
            let error = event["error"] as? [String: Any]
            let code = error?["code"] as? String ?? ""
            let message = error?["message"] as? String ?? "unknown error"
            // Cancelling a reply that already finished is harmless noise.
            if code == "response_cancel_not_active" { return }
            logger.error("Realtime error \(code, privacy: .public): \(message, privacy: .public)")
        default:
            break
        }
    }

    // MARK: - Images

    func share(images: [ImageAttachment]) -> Bool {
        guard isActive, !images.isEmpty else { return false }
        guard isConnected else {
            queuedImages += images
            return true
        }
        guard deliver(images) else { return false }
        acknowledgeImages()
        return true
    }

    /// Send the pictures to the voice, then show them in the call's
    /// conversation (which saves them with it). False if none could be read.
    private func deliver(_ images: [ImageAttachment]) -> Bool {
        guard let item = Self.imageItem(images) else {
            logger.error("Shared image(s) could not be read")
            return false
        }
        send(item)
        transcript.appendSharedImages(images)
        publishTranscript()
        logger.info("Shared \(images.count) image(s) with the call")
        return true
    }

    /// The voice says what it sees, so the user knows the picture arrived.
    /// Skipped while it is mid-reply or running a tool: only one response may
    /// run at a time, and the picture is in the conversation for its next turn.
    private func acknowledgeImages() {
        guard !turns.responseActive, turns.pendingTools == 0 else { return }
        turns.responseRequested()
        send(["type": "response.create", "response": ["instructions": Self.imageAcknowledgement]])
    }

    /// Replaces the session instructions for this one reply, so it restates
    /// the few rules that matter.
    nonisolated static let imageAcknowledgement = """
        You are Astro, speaking out loud on a live call. The user just shared an image with you. \
        In one or two short sentences, say what it shows, then ask what they'd like to know about it. \
        Summarise any text in it rather than reading it all out.
        """

    /// The pictures as one user message. Nil when none of their files can be read.
    nonisolated static func imageItem(_ images: [ImageAttachment]) -> [String: Any]? {
        let parts: [[String: Any]] = images.compactMap { image in
            guard let base64 = image.base64() else { return nil }
            return ["type": "input_image", "image_url": "data:\(image.mediaType);base64,\(base64)"]
        }
        guard !parts.isEmpty else { return nil }
        let note = parts.count == 1 ? "I've shared this image with you." : "I've shared these images with you."
        return ["type": "conversation.item.create", "item": [
            "type": "message", "role": "user",
            "content": parts + [["type": "input_text", "text": note]],
        ] as [String: Any]]
    }

    // MARK: - Tools

    private func runTool(callId: String, name: String, arguments: String) {
        logger.info("Tool call: \(name, privacy: .public)")

        if name == Self.endCallTool {
            isHangingUp = true
            sendToolOutput(callId: callId, output: "Call ending.", continueResponse: false)
            // Let the goodbye finish playing; hang up now if nothing is queued.
            if !audio.isPlaying {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let self, isActive, !audio.isPlaying else { return }
                    NotchCallButton.endCall()
                }
            }
            return
        }

        let input = (arguments.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        turns.toolStarted()
        runningTools += 1
        if name == "generate_image" { LiveVoiceState.shared.imageGenerationStarted(id: callId) }
        NotchActivityIndicator.addProcess(id: "call-agent",
                                          label: name == "generate_image" ? "Nebulising..." : ToolIndicatorView.displayName(for: name))

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await registry.run(name: name, input: input, workingDirectory: workspace)
            LiveVoiceState.shared.imageGenerationFinished(id: callId)
            runningTools -= 1
            guard isActive else { return }
            if runningTools == 0 { NotchActivityIndicator.removeProcess(id: "call-agent") }
            sendToolOutput(callId: callId, output: Self.truncate(result), continueResponse: true)
        }
    }

    private func sendToolOutput(callId: String, output: String, continueResponse: Bool) {
        send(["type": "conversation.item.create", "item": [
            "type": "function_call_output", "call_id": callId, "output": output,
        ]])
        // Only one response may run at a time: reply once every tool from the
        // turn has reported and the model's current response has finished.
        if continueResponse, turns.toolFinished() { requestReply() }
    }

    private func requestReply() {
        turns.responseRequested()
        send(["type": "response.create"])
    }

    /// Show the conversation so far in the panel while the call runs.
    private func publishTranscript() {
        LiveVoiceState.shared.transcript = transcript.displayLines
    }

    private func trackPlayback(itemId: String?, base64: String) {
        guard let itemId else { return }
        if itemId != playingItemId {
            playingItemId = itemId
            playingItemReceivedMs = 0
            playingItemStartedAt = CFAbsoluteTimeGetCurrent()
        }
        // PCM16 mono 24 kHz: 48 bytes per millisecond (base64 is 4 chars per 3 bytes).
        playingItemReceivedMs += (base64.count * 3 / 4) / 48
    }

    private func truncateInterruptedAudio() {
        defer { playingItemId = nil; playingItemStartedAt = nil }
        guard audio.isPlaying, let itemId = playingItemId, let started = playingItemStartedAt else { return }
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        let heardMs = max(0, min(playingItemReceivedMs, elapsedMs))
        send(["type": "conversation.item.truncate", "item_id": itemId, "content_index": 0, "audio_end_ms": heardMs])
    }

    /// Voice replies should summarise, not read out whole files.
    private static func truncate(_ text: String, limit: Int = 12_000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n[…truncated]" : text
    }

    // MARK: - Failure & persistence

    private func fail(_ error: Error) {
        guard isActive else { return }
        logger.error("Realtime call failed: \(error.localizedDescription, privacy: .public)")
        NotchNotificationPresenter.showAgentReply(message: RealtimeCallError.userMessage(for: error))
        NotchCallButton.endCall()
    }

    /// Saved straight to Chats so shared pictures stay with the conversation.
    private func saveSession() {
        guard let chatSession else { return }
        let messages = transcript.savedMessages
        guard !messages.isEmpty else { return }
        var saved = Session(id: chatSession.id, title: chatSession.title, messages: messages)
        saved.createdAt = chatSession.createdAt
        saved.updatedAt = Date()
        SessionStore.shared.save(saved)
    }

    // MARK: - Pure builders (unit-testable)

    /// Realtime session config sent when minting the client secret.
    nonisolated static func sessionConfig(
        model: String, voice: String, instructions: String, tools: [[String: Any]]
    ) -> [String: Any] {
        let pcm: [String: Any] = ["type": "audio/pcm", "rate": 24_000]
        var session: [String: Any] = [
            "type": "realtime",
            "model": model,
            "instructions": instructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": pcm,
                    // A Mac's built-in mic sits an arm's length away: far field.
                    "noise_reduction": ["type": "far_field"],
                    "transcription": ["model": "gpt-4o-mini-transcribe"],
                    "turn_detection": [
                        "type": "semantic_vad",
                        "eagerness": "medium",
                        "create_response": true,
                        "interrupt_response": true,
                    ],
                ],
                "output": ["format": pcm, "voice": voice],
            ],
        ]
        if !tools.isEmpty {
            session["tools"] = tools
            session["tool_choice"] = "auto"
        }
        return session
    }

    /// Universe tools in Realtime function-tool shape, plus `end_call`.
    nonisolated static func functionTools(from registry: ToolRegistry) -> [[String: Any]] {
        var tools = registry.tools.map { tool -> [String: Any] in
            ["type": "function", "name": tool.name, "description": tool.description, "parameters": tool.inputSchema]
        }
        let endCall = EndCallTool()
        tools.append([
            "type": "function", "name": endCall.name,
            "description": endCall.description, "parameters": endCall.inputSchema,
        ])
        return tools
    }
}

/// Enforces the Realtime rule that only one response runs at a time. Tool
/// outputs wait until every tool from the turn has finished and the model's
/// current response is done, then exactly one follow-up reply is requested.
struct RealtimeTurnTracker {
    private(set) var responseActive = false
    private(set) var pendingTools = 0
    private var outputsAwaitingReply = false

    mutating func responseRequested() { responseActive = true; outputsAwaitingReply = false }
    mutating func responseStarted() { responseActive = true }
    mutating func toolStarted() { pendingTools += 1 }

    /// Returns true when the caller should send `response.create` now.
    mutating func toolFinished() -> Bool {
        pendingTools = max(0, pendingTools - 1)
        outputsAwaitingReply = true
        return pendingTools == 0 && !responseActive
    }

    /// Returns true when the caller should send `response.create` now.
    mutating func responseFinished() -> Bool {
        responseActive = false
        return pendingTools == 0 && outputsAwaitingReply
    }
}

/// The call's transcript in true conversation order. A user turn's slot is
/// reserved when its audio is committed, because its transcription usually
/// arrives after the assistant has already replied.
struct RealtimeTranscript {
    private struct Entry {
        let id = UUID()
        let itemId: String?
        let role: String
        var text: String
        /// A user turn is shown in the conversation only once its final text is
        /// in; until then its words live in the "Ask anything" box.
        var isFinal = false
        /// Pictures the user shared during the call.
        var attachments: [ImageAttachment] = []

        var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
    }

    private var entries: [Entry] = []
    /// Index of the assistant reply still streaming in, if any.
    private var openAssistant: Int?

    mutating func reserveUser(itemId: String) {
        guard !entries.contains(where: { $0.itemId == itemId }) else { return }
        entries.append(Entry(itemId: itemId, role: "user", text: ""))
    }

    /// Streaming words of the user's turn, shown while they are still arriving.
    mutating func appendUserDelta(itemId: String, delta: String) {
        if let index = entries.firstIndex(where: { $0.itemId == itemId }) {
            entries[index].text += delta
        } else {
            entries.append(Entry(itemId: itemId, role: "user", text: delta))
        }
    }

    /// The final transcript of a user turn; replaces any streamed words.
    mutating func fillUser(itemId: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = entries.firstIndex(where: { $0.itemId == itemId }) {
            entries[index].text = trimmed
            entries[index].isFinal = true
        } else {
            entries.append(Entry(itemId: itemId, role: "user", text: trimmed, isFinal: true))
        }
    }

    /// The words streamed so far for a user turn that is not final yet.
    func userText(itemId: String) -> String {
        entries.first { $0.itemId == itemId }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Streaming words of the assistant's spoken reply.
    mutating func appendAssistantDelta(_ delta: String) {
        if let index = openAssistant {
            entries[index].text += delta
        } else {
            entries.append(Entry(itemId: nil, role: "assistant", text: delta))
            openAssistant = entries.count - 1
        }
    }

    /// The reply ended (or was interrupted): close it so the next one starts fresh.
    mutating func finishAssistant() {
        if let index = openAssistant {
            entries[index].text = entries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        openAssistant = nil
    }

    /// Pictures the user shared, as their own turn in the conversation.
    mutating func appendSharedImages(_ images: [ImageAttachment]) {
        entries.append(Entry(itemId: nil, role: "user", text: "", isFinal: true, attachments: images))
    }

    mutating func appendAssistant(_ text: String) {
        appendAssistantDelta(text)
        finishAssistant()
    }

    /// The spoken words only, in API shape.
    var messages: [[String: Any]] {
        entries.filter { !$0.text.isEmpty }.map { ["role": $0.role, "content": $0.text] }
    }

    /// The call as it is saved to Chats, pictures included.
    var savedMessages: [Session.Message] {
        entries.filter { !$0.isEmpty }.map { entry in
            Session.Message(role: entry.role, text: entry.text,
                            attachments: entry.attachments.isEmpty ? nil : entry.attachments)
        }
    }

    /// What the conversation area shows during the call, with ids stable
    /// across updates. Unfinished user turns are left out: they are in the box.
    var displayLines: [Session.Message] {
        entries.compactMap { entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !entry.attachments.isEmpty, entry.role != "user" || entry.isFinal else { return nil }
            return Session.Message(id: entry.id, role: entry.role, text: text,
                                   attachments: entry.attachments.isEmpty ? nil : entry.attachments)
        }
    }
}

/// Instructions for the live model — the regular call persona plus the rules
/// that matter when the model itself is speaking.
@MainActor
func buildRealtimeInstructions() -> String {
    buildCallSystemPrompt() + """


    # Live voice
    - You are speaking out loud in real time. Keep replies to one to three short sentences.
    - Before a tool that may take a moment, say a quick filler like "one sec" so there is no dead air.
    - Never read out code, file contents, URLs or long lists — summarise them.
    - When the user says goodbye, say a brief goodbye, then call end_call.
    """
}

enum RealtimeCallError: LocalizedError {
    case notSignedIn
    case rejected(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "OpenAI live voice needs you to sign in with ChatGPT in AI Settings."
        case let .rejected(status, message):
            return "OpenAI refused the live voice session (HTTP \(status)): \(message)"
        }
    }

    static func userMessage(for error: Error) -> String {
        switch error {
        case RealtimeCallError.notSignedIn:
            return RealtimeCallError.notSignedIn.errorDescription ?? ""
        case let RealtimeCallError.rejected(status, _) where status == 401 || status == 403:
            return "Your ChatGPT plan couldn't start live voice. Try signing in to OpenAI again, or switch back to the built-in voice."
        default:
            return "Live voice call dropped: \(error.localizedDescription)"
        }
    }
}
