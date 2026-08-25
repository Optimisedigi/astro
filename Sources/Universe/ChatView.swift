import SwiftUI

@MainActor
final class ChatState: ObservableObject {
    @Published var session = Session(title: "New conversation")
    @Published var input = ""
    @Published var isStreaming = false
    @Published var toolRuns: [ToolRun] = []
    @Published var errorMessage: String?

    let store = SessionStore()
    /// Smooths lumpy token bursts into steady typing.
    private let queue = CharacterQueue()
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
        let dir = base.appendingPathComponent("Universe/Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Tool rows survive the turn so the transcript still shows what ran.
    private func apply(_ activity: ToolActivity) {
        switch activity {
        case .started(let id, let name, let detail):
            toolRuns.append(ToolRun(id: id, name: name, detail: detail))
        case .finished(let id, let failed):
            guard let index = toolRuns.firstIndex(where: { $0.id == id }) else { return }
            toolRuns[index].status = failed ? .failed : .done
        }
    }

    func retryLastMessage() {
        guard !isStreaming, let last = session.messages.last(where: { $0.role == "user" })?.text else { return }
        // Drop the empty assistant placeholder left by the failed turn.
        if session.messages.last?.role == "assistant", session.messages.last?.text.isEmpty == true {
            session.messages.removeLast()
        }
        if session.messages.last?.role == "user" { session.messages.removeLast() }
        input = last
        send()
    }

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
        toolRuns.removeAll()
        session.updatedAt = Date()
        isStreaming = true

        let apiMessages: [[String: Any]] = session.messages.dropLast().map {
            ["role": $0.role, "content": [["type": "text", "text": $0.text]]]
        }

        Task {
            defer {
                queue.finish()
                isStreaming = false
                session.updatedAt = Date()
                store.save(session)
            }
            do {
                let loop = AgentLoop(workspace: workspace)
                if voiceMode { voice.stopListening() }
                queue.reset()
                queue.onVisible = { [weak self] text in
                    guard let self, let last = self.session.messages.indices.last else { return }
                    self.session.messages[last].text = text
                }
                try await loop.run(apiMessages: apiMessages, streamProvider: ClaudeService.shared.streamEvents) { [weak self] delta in
                    self?.queue.append(delta)
                } onToolActivity: { [weak self] activity in
                    self?.apply(activity)
                }
                queue.finish() // flush before anything reads the final text
                if voiceMode {
                    speech.speak(session.messages[session.messages.count - 1].text)
                    resumeListeningAfterReply()
                }
            } catch {
                errorMessage = error.localizedDescription
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
        ScrollViewReader { proxy in
            ScrollView {
                if state.session.messages.isEmpty {
                    EmptyChatView().padding(.top, 60)
                } else {
                    MessageListView(
                        messages: state.session.messages,
                        toolRuns: state.toolRuns,
                        isStreaming: state.isStreaming,
                        errorMessage: state.errorMessage,
                        retry: state.retryLastMessage
                    )
                }
            }
            .onChange(of: state.session.messages.last?.text) { _, _ in
                if let last = state.session.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
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

/// First thing you see in a new conversation.
struct EmptyChatView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ask anything")
                .font(.headline)
            Text("Universe can read files, run commands and remind you later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Empty conversation. Ask anything.")
    }
}

/// The conversation itself, without the scroll container — so `--render-states`
/// can rasterise it offscreen (ImageRenderer does not draw ScrollView contents).
struct MessageListView: View {
    let messages: [Session.Message]
    var toolRuns: [ToolRun] = []
    var isStreaming = false
    var errorMessage: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(messages) { message in
                // An assistant turn that has not produced text yet shows a skeleton or
                // tool rows instead of an empty bubble.
                if !(message.role == "assistant" && message.text.isEmpty) {
                    MessageBubble(message: message, isStreaming: isStreaming && message.id == messages.last?.id)
                        .id(message.id)
                }
            }
            if !toolRuns.isEmpty {
                ToolIndicatorView(runs: toolRuns)
            }
            if isStreaming, messages.last?.text.isEmpty == true, toolRuns.isEmpty {
                SkeletonView()
            }
            if let errorMessage {
                ErrorTextBlock(message: errorMessage, retry: retry)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageBubble: View {
    let message: Session.Message
    var isStreaming = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == "user" { Spacer(minLength: 40) }
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == "user" ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.role == "user" {
            Text(message.text).textSelection(.enabled)
        } else {
            ResponseTextView(text: message.text, isStreaming: isStreaming)
        }
    }
}
