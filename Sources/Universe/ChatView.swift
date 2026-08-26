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
    let voice = VoiceService.shared
    let speech = SpeechService.shared
    let permissions = PermissionsChecker()
    let login = LoginModel()
    /// Set by the menubar menu to open one of the settings sheets.
    @Published var requestedSheet: SettingsSheetKind?

    /// Persisted so the talk-and-listen choice survives a relaunch (Tama keeps
    /// the same flag on KokoroManager; we mirror it there so speech output and
    /// microphone capture stay in step).
    @Published var voiceMode: Bool = KokoroManager.shared.voiceEnabled {
        didSet { KokoroManager.shared.voiceEnabled = voiceMode }
    }

    /// No Claude session and no API key: the user cannot ask anything yet.
    var needsSignIn: Bool {
        !AnthropicOAuth.isSignedIn && (KeychainHelper.get(account: "anthropic")?.isEmpty ?? true)
    }

    /// Voice mode only comes back if the user left it on AND the microphone is
    /// already authorised — launching must never raise a permission prompt.
    static func shouldRestoreVoiceMode(saved: Bool, micAuthorized: Bool) -> Bool {
        saved && micAuthorized
    }

    init() {
        guard voiceMode else { return }
        guard Self.shouldRestoreVoiceMode(saved: true, micAuthorized: VoiceService.isAlreadyAuthorized) else {
            // `didSet` never runs for assignments inside `init`, so persist by hand
            // or the saved flag and the live one drift apart.
            voiceMode = false
            KokoroManager.shared.voiceEnabled = false
            return
        }
        // A restored voice mode still needs its utterance handler wired, or the
        // first thing the user says after a relaunch goes nowhere. The panel
        // starts the microphone itself when it opens.
        wireUtteranceHandler()
    }

    /// Whether the panel is on screen. The microphone may only be open while
    /// this is true, so the mic indicator tracks the window exactly.
    private(set) var panelVisible = false

    /// The panel became visible. Tama opens the microphone whenever its window
    /// is up, so the user can just start talking.
    func panelDidOpen() {
        panelVisible = true
        guard voiceMode, VoiceService.isAlreadyAuthorized else { return }
        wireUtteranceHandler()
        try? voice.startListening()
    }

    /// The panel was dismissed (⌥Space or the menubar). Release the microphone
    /// immediately — a hidden window must never hold the input device open.
    func panelDidClose() {
        panelVisible = false
        voice.stopListening()
        // `shutdown()`, not `stop()`: stop() leaves the playback engine running,
        // holding an audio device open behind a dismissed window.
        speech.shutdown()
    }

    private func wireUtteranceHandler() {
        // Live dictation: show words in the input field as they are recognised,
        // so the user can see what is being heard before it sends.
        voice.onPartialTranscript = { [weak self] partial in
            self?.input = partial
        }

        voice.onCaptureComplete = { [weak self] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Nothing recognised — clear the partial so a stale phrase is
                // never left sitting in the field.
                self?.input = ""
                return
            }
            self?.input = trimmed
            self?.send()
        }

        // Without this the chat path fails silently: `try? startListening()`
        // discards the throw, so a mic that never opens looked identical to one
        // that is simply hearing nothing.
        voice.onError = { [weak self] message in
            self?.errorMessage = message
            self?.voiceMode = false
        }
    }

    func enableVoiceMode() {
        voiceMode = true
        wireUtteranceHandler()
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
        voice.onPartialTranscript = nil
        voice.onCaptureComplete = nil
        voice.onError = nil
        voice.stopListening()
        speech.stop()
    }

    /// Listen again after the spoken reply finishes — keeps the call loop alive.
    /// Checks `panelVisible` *after* the wait, not before: closing the panel
    /// mid-reply used to reopen the microphone behind a hidden window, leaving
    /// the system mic indicator lit until the app quit.
    private func resumeListeningAfterReply() {
        Task {
            while speech.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
            if voiceMode, panelVisible { try? voice.startListening() }
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

    /// Open a past conversation in the transcript view.
    func loadSession(_ session: Session) {
        guard !isStreaming else { return }
        self.session = session
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
        MenuBarMood.shared.setActivity(.thinking)
        MascotController.shared.setState(.waiting)

        let apiMessages: [[String: Any]] = session.messages.dropLast().map {
            ["role": $0.role, "content": [["type": "text", "text": $0.text]]]
        }

        Task {
            defer {
                queue.finish()
                isStreaming = false
                session.updatedAt = Date()
                store.save(session)
                // Speaking keeps its own mood; otherwise back to time-of-day.
                if !speech.isSpeaking { MenuBarMood.shared.setActivity(nil) }
            }
            do {
                let loop = AgentLoop(workspace: workspace)
                if voiceMode { voice.stopListening() }
                queue.reset()
                queue.onVisible = { [weak self] text in
                    guard let self, let last = self.session.messages.indices.last else { return }
                    self.session.messages[last].text = text
                }
                var firstToken = true
                try await loop.run(apiMessages: apiMessages, streamProvider: ClaudeService.shared.streamEvents) { [weak self] delta in
                    if firstToken {
                        firstToken = false
                        MenuBarMood.shared.setActivity(.responding)
                        MascotController.shared.setState(.responding)
                    }
                    self?.queue.append(delta)
                } onToolActivity: { [weak self] activity in
                    self?.apply(activity)
                }
                queue.finish() // flush before anything reads the final text
                // Panel dismissed mid-turn: surface the reply as a notch toast (Tama behavior).
                if !PanelController.shared.isVisible {
                    let reply = session.messages.last?.text ?? ""
                    NotchNotificationPresenter.showAgentReply(message: String(reply.prefix(300))) {
                        PanelController.shared.show()
                    }
                }
                // Brief happy beat, then settle back to idle (matches tama-agent).
                MascotController.shared.setState(.happy)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if MascotController.shared.currentState == .happy {
                        MascotController.shared.setState(.idle)
                    }
                }
                if voiceMode {
                    speech.speak(session.messages[session.messages.count - 1].text)
                    resumeListeningAfterReply()
                }
            } catch {
                errorMessage = error.localizedDescription
                MenuBarMood.shared.setActivity(.error)
                MascotController.shared.setState(.thinking)
                // Show the error face briefly, then return to time-of-day.
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if MenuBarMood.shared.mood == .error { MenuBarMood.shared.setActivity(nil) }
                }
                if voiceMode { try? voice.startListening() }
            }
        }
    }
}

struct ChatView: View {
    @ObservedObject var state: ChatState
    @ObservedObject private var schedules = ScheduleStore.shared
    @ObservedObject private var registry = ModelRegistry.shared
    @State private var sheet: SettingsSheetKind?
    @State private var selectedTab = 0
    /// True while a conversation is on screen instead of the Chats list.
    @State private var showingTranscript = false
    @ObservedObject private var taskStore = TaskStore.shared
    @ObservedObject private var skillStore = SkillStore.shared

    /// Tama's exact tab set, in its order.
    private let tabLabels = ["Chats", "Reminders", "Routines", "Tasks", "Skills", "Tools"]

    var body: some View {
        VStack(spacing: 0) {
            // Tama's layout: input row on top, tabs below it, lists under that.
            inputRow

            Divider().padding(.horizontal, 20)

            HStack {
                AnimatedTabBar(labels: tabLabels, selectedIndex: $selectedTab)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Tab content
            switch selectedTab {
            case 0:
                if showingTranscript {
                    transcript
                } else {
                    SessionListView(store: state.store) { session in
                        state.loadSession(session)
                        showingTranscript = true
                    } onDeleteSession: { session in
                        state.store.deleteSession(session.id)
                    }
                }
            case 1:
                RoutineListView(store: schedules, kind: .reminder)
            case 2:
                RoutineListView(store: schedules, kind: .routine)
            case 3:
                TaskListView(store: taskStore)
            case 4:
                SkillListView(store: skillStore)
            case 5:
                ToolListView()
            default:
                EmptyView()
            }
        }
        .frame(width: 680, height: 560)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .onChange(of: state.isStreaming) { _, streaming in
            // Sending a prompt swaps the list for the live conversation (Tama behavior).
            if streaming { selectedTab = 0; showingTranscript = true }
        }
        .onChange(of: state.requestedSheet) { _, requested in
            guard let requested else { return }
            sheet = requested
            state.requestedSheet = nil
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .ai:
                AISettingsView(registry: registry, login: state.login) { sheet = nil }
            case .voice:
                VoiceSettingsView(state: state) { sheet = nil }
            case .memory:
                MemorySettingsView { sheet = nil }
            case .permissions:
                PermissionsView(checker: state.permissions) { sheet = nil }
            case .onboarding:
                OnboardingView(model: OnboardingModel()) { sheet = nil }
            }
        }
    }

    private var chatBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if state.session.messages.isEmpty {
                    EmptyChatView(needsSignIn: state.needsSignIn) { SettingsWindowController.shared.show() }
                        .padding(.top, 60)
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

    private var inputRow: some View {
        HStack(spacing: 10) {
            MascotBadge()

            TextField("Ask anything…", text: $state.input)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .light))
                .lineLimit(1)
                .onSubmit { state.send() }
                .onChange(of: state.input) { _, _ in MascotController.shared.notifyKeystroke() }

            Button(action: { state.voiceMode ? state.disableVoiceMode() : state.enableVoiceMode() }) {
                Image(systemName: state.voiceMode ? "mic.fill" : "mic")
                    .font(.system(size: 16))
                    .foregroundStyle(state.voiceMode ? Color.red : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle voice mode")
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 24))
        .frame(height: 58)
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingTranscript = false
                } label: {
                    Label("Chats", systemImage: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Text(registry.selectedModel.name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            chatBody
        }
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
    /// Without a credential there is nothing to ask, so the empty state becomes the door in.
    var needsSignIn = false
    var signIn: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: needsSignIn ? "person.crop.circle" : "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(needsSignIn ? "Sign in to Claude" : "Ask anything")
                .font(.headline)
            Text(needsSignIn
                 ? "Universe uses your Claude subscription. No API key needed."
                 : "Universe can read files, run commands and remind you later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if needsSignIn, let signIn {
                Button("Sign in with Claude", action: signIn)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
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
