import Foundation

/// Which engine runs a notch voice call.
///
/// `builtIn` is the original pipeline: Apple speech recognition → the chat
/// model → Kokoro text-to-speech, one turn at a time.
/// `openAIRealtime` streams audio both ways to OpenAI's speech-to-speech model,
/// paid for by the user's ChatGPT plan through the OpenAI sign-in.
enum VoiceEngine: String, CaseIterable, Identifiable {
    case builtIn
    case openAIRealtime

    var id: String { rawValue }
}

/// A voice-call session the notch call button can start and stop.
@MainActor
protocol VoiceCallSession: AnyObject {
    func start()
    func end()
}

extension CallSession: VoiceCallSession {}

/// Whether an OpenAI live conversation is running, for the panel's mic button
/// and voice glow. Calls from the notch and from the panel mic share it.
@MainActor
final class LiveVoiceState: ObservableObject {
    static let shared = LiveVoiceState()

    @Published private(set) var isActive = false
    /// The conversation so far, in order, updated as words stream in. The panel
    /// shows it during the call; it is saved as a "Voice Call" chat at the end.
    @Published var transcript: [Session.Message] = []
    /// What the user is saying right now, shown in the "Ask anything" box as if
    /// typed. Moves to `transcript` when the turn's final text arrives.
    @Published private(set) var draft = ""
    private var draftItemId: String?
    /// Latest microphone loudness during a live call, 0–1. Polled per frame by
    /// the voice glow, so it is deliberately not `@Published`.
    var inputLevel: Double = 0

    private init() {}

    func setActive(_ active: Bool) {
        isActive = active
        if active { transcript = [] }
        if !active { inputLevel = 0 }
        draft = ""
        draftItemId = nil
    }

    /// The words of the user's current turn. A newer turn replaces an older one.
    func setDraft(itemId: String, text: String) {
        draftItemId = itemId
        draft = text
    }

    /// The box's words for this turn, or "" if the box has moved on to another.
    func draft(for itemId: String) -> String {
        draftItemId == itemId ? draft : ""
    }

    /// A turn finished: clear the box, unless the user has already started the next one.
    func clearDraft(itemId: String) {
        guard draftItemId == itemId else { return }
        draftItemId = nil
        draft = ""
    }

    /// `--render-states` only: a separate state showing a call with this
    /// transcript, without a microphone or network connection.
    static func forRendering(_ lines: [Session.Message], draft: String = "") -> LiveVoiceState {
        let state = LiveVoiceState()
        state.isActive = true
        state.transcript = lines
        state.draft = draft
        return state
    }

    /// A separate, idle state for the offline self-test (never touches `shared`).
    static func makeForTesting() -> LiveVoiceState { LiveVoiceState() }
}

/// Persisted choices for OpenAI live voice. Plain preferences only — tokens
/// live in the Keychain via `OpenAIOAuth`.
@MainActor
final class RealtimeVoiceSettings: ObservableObject {
    static let shared = RealtimeVoiceSettings()

    struct Option: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
    }

    static let models: [Option] = [
        Option(id: "gpt-realtime-2.1", name: "GPT Realtime 2.1", detail: "Smartest, best with tools"),
        Option(id: "gpt-realtime-2.1-mini", name: "GPT Realtime 2.1 mini", detail: "Faster, lighter"),
        Option(id: GPTLiveProtocol.model, name: "GPT‑Live 1", detail: "ChatGPT's own live voice"),
    ]

    /// GPT‑Live 1 has its own voice family; the 2.1 models share the GA voices.
    static func voices(for model: String) -> [Option] {
        guard model == GPTLiveProtocol.model else { return realtimeVoices }
        return GPTLiveProtocol.voices.map { Option(id: $0, name: $0.capitalized, detail: "") }
    }

    private static let realtimeVoices: [Option] = [
        Option(id: "marin", name: "Marin", detail: "Warm, natural"),
        Option(id: "cedar", name: "Cedar", detail: "Calm, grounded"),
        Option(id: "coral", name: "Coral", detail: "Bright, friendly"),
        Option(id: "sage", name: "Sage", detail: "Clear, even"),
        Option(id: "verse", name: "Verse", detail: "Expressive"),
        Option(id: "ash", name: "Ash", detail: "Low, relaxed"),
    ]

    private enum Key {
        static let engine = "voiceCall.engine"
        static let model = "voiceCall.openai.model"
        static let voice = "voiceCall.openai.voice"
    }

    private let defaults: UserDefaults

    @Published var engine: VoiceEngine {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }

    @Published var model: String {
        didSet {
            defaults.set(model, forKey: Key.model)
            let available = Self.voices(for: model)
            if !available.contains(where: { $0.id == voice }) { voice = available[0].id }
        }
    }

    @Published var voice: String {
        didSet { defaults.set(voice, forKey: Key.voice) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = defaults.string(forKey: Key.engine).flatMap(VoiceEngine.init(rawValue:)) ?? .builtIn
        let storedModel = defaults.string(forKey: Key.model) ?? ""
        let resolvedModel = Self.models.contains { $0.id == storedModel } ? storedModel : Self.models[0].id
        model = resolvedModel
        let storedVoice = defaults.string(forKey: Key.voice) ?? ""
        let available = Self.voices(for: resolvedModel)
        voice = available.contains { $0.id == storedVoice } ? storedVoice : available[0].id
    }

    /// The session to run for the next call. A missing OpenAI sign-in is
    /// reported by the live session itself rather than silently swapped.
    func makeCallSession(greets: Bool = true) -> any VoiceCallSession {
        if engine == .openAIRealtime {
            if model == GPTLiveProtocol.model { return GPTLiveCallSession(voice: voice) }
            return OpenAIRealtimeCallSession(model: model, voice: voice, greets: greets)
        }
        return CallSession()
    }
}
