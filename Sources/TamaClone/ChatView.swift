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
    @ObservedObject private var schedules = ScheduleStore.shared
    @State private var showSchedules = false

    var body: some View {
        VStack(spacing: 0) {
            if showSchedules {
                ScheduleListView(store: schedules)
            } else {
                chatBody
            }
            inputBar
        }
        .frame(width: 420, height: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var chatBody: some View {
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
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button(action: { state.voiceMode ? state.disableVoiceMode() : state.enableVoiceMode() }) {
                Image(systemName: state.voiceMode ? "mic.fill" : "mic")
                    .font(.title2)
                    .foregroundStyle(state.voiceMode ? Color.red : Color.primary)
            }
            .buttonStyle(.plain)
            .help("Toggle voice mode")

            Button(action: { showSchedules.toggle() }) {
                Image(systemName: showSchedules ? "bell.fill" : "bell")
                    .font(.title2)
                    .foregroundStyle(showSchedules ? Color.accentColor : Color.primary)
                    .overlay(alignment: .topTrailing) {
                        if !schedules.jobs.isEmpty && !showSchedules {
                            Circle().fill(Color.red).frame(width: 6, height: 6).offset(x: 2, y: -1)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Reminders & routines")

            TextField(state.voiceMode ? "Listening…" : "Type anything…", text: $state.input)
                .textFieldStyle(.plain)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { showSchedules = false; state.send() }
            Button(action: { showSchedules = false; state.send() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(state.input.trimmingCharacters(in: .whitespaces).isEmpty || state.isStreaming)
        }
        .padding()
    }
}

/// Reminders + routines pane.
struct ScheduleListView: View {
    @ObservedObject var store: ScheduleStore

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            if store.jobs.isEmpty {
                Text("No reminders yet. Ask Tama to set one for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.jobs) { job in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: job.kind == .reminder ? "alarm" : "arrow.triangle.2.circlepath")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.name).fontWeight(.medium)
                                Text(job.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text("\(job.schedule) · next \(Self.formatter.string(from: job.nextRun))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button {
                                _ = store.delete(name: job.name)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding()
            }
        }
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
