import SwiftUI

@MainActor
final class ChatState: ObservableObject {
    @Published var session = Session(title: "New conversation")
    @Published var input = ""
    @Published var isStreaming = false
    @Published var toolActivity: String?
    @Published var errorMessage: String?

    let store = SessionStore()
    let voice = VoiceService()
    let speech = SpeechService()
    @Published var voiceMode = false

    func enableVoiceMode() {
        voiceMode = true
        voice.onUtterance = { [weak self] text in
            self?.input = text
            self?.send()
        }
        Task {
            guard await voice.requestPermissions() else {
                errorMessage = VoiceService.VoiceError.notAuthorized.localizedDescription
                voiceMode = false
                return
            }
            try? voice.startListening()
        }
    }

    func disableVoiceMode() {
        voiceMode = false
        voice.stopListening()
        speech.stop()
    }

    /// Listen again after the spoken reply finishes — keeps the call loop alive.
    private func resumeListeningAfterReply() {
        Task {
            while speech.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
            if voiceMode { try? voice.startListening() }
        }
    }

    var workspace: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TamaClone/Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        errorMessage = nil

        session.messages.append(.init(role: "user", text: text))
        if session.messages.count == 1 {
            session.title = String(text.prefix(40))
        }
        session.messages.append(.init(role: "assistant", text: ""))
        session.updatedAt = Date()
        isStreaming = true

        let apiMessages: [[String: Any]] = session.messages.dropLast().map {
            ["role": $0.role, "content": [["type": "text", "text": $0.text]]]
        }

        Task {
            defer {
                isStreaming = false
                toolActivity = nil
                session.updatedAt = Date()
                store.save(session)
            }
            do {
                let loop = AgentLoop(workspace: workspace)
                if voiceMode { voice.stopListening() }
                try await loop.run(apiMessages: apiMessages, streamProvider: ClaudeService.shared.streamEvents) { [weak self] delta in
                    guard let self, let last = self.session.messages.indices.last else { return }
                    self.session.messages[last].text += delta
                } onToolActivity: { [weak self] activity in
                    self?.toolActivity = activity.hasSuffix("done") ? nil : "⚙️ \(activity)"
                }
                if voiceMode {
                    speech.speak(session.messages[session.messages.count - 1].text)
                    resumeListeningAfterReply()
                }
            } catch {
                errorMessage = error.localizedDescription
                session.messages[session.messages.count - 1].text = "⚠️ \(error.localizedDescription)"
                if voiceMode { try? voice.startListening() }
            }
        }
    }
}

struct ChatView: View {
    @ObservedObject var state: ChatState

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.session.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: state.session.messages.last?.text) { _, _ in
                    if let last = state.session.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let activity = state.toolActivity {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            HStack(spacing: 8) {
                Button(action: { state.voiceMode ? state.disableVoiceMode() : state.enableVoiceMode() }) {
                    Image(systemName: state.voiceMode ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(state.voiceMode ? Color.red : Color.primary)
                }
                .buttonStyle(.plain)
                .help("Toggle voice mode")
                TextField(state.voiceMode ? "Listening…" : "Type anything…", text: $state.input)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { state.send() }
                Button(action: { state.send() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(state.input.trimmingCharacters(in: .whitespaces).isEmpty || state.isStreaming)
            }
            .padding()
        }
        .frame(width: 420, height: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct MessageBubble: View {
    let message: Session.Message

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == "user" ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }
}
