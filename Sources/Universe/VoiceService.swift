import AVFoundation
import Speech

/// Voice input: SFSpeechRecognizer + AVAudioEngine with RMS adaptive silence detection
/// (SPEC.md §6 — noiseFloorRMS / silenceWindow / speechBoostFactor mirror Tama's VoiceService).
@MainActor
final class VoiceService: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var transcript = ""

    /// Fires once when the user finishes speaking (silence detected) with the final transcript.
    var onUtterance: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Silence detection state
    private var noiseFloorRMS: Float = 0.0005
    private let speechBoostFactor: Float = 3.0
    private let silenceWindow: TimeInterval = 1.2
    private var hasSpoken = false
    private var lastSpeechAt = Date.distantPast

    enum VoiceError: LocalizedError {
        case notAuthorized, recognizerUnavailable, noMic

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Microphone/Speech permission not granted. Enable in System Settings > Privacy & Security."
            case .recognizerUnavailable: return "Speech recognizer unavailable."
            case .noMic: return "Could not access microphone."
            }
        }
    }

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startListening() throws {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else { throw VoiceError.recognizerUnavailable }
        MenuBarMood.shared.setActivity(.listening)

        transcript = ""
        hasSpoken = false
        lastSpeechAt = .distantPast

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.finishUtterance()
                }
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.measure(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw VoiceError.noMic
        }
        isListening = true
        watchForSilence()
    }

    func stopListening() {
        isListening = false
        if MenuBarMood.shared.mood == .listening { MenuBarMood.shared.setActivity(nil) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    /// RMS measurement — speech detected when level exceeds noiseFloor * speechBoostFactor.
    nonisolated private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var rms: Float = 0
        for i in 0..<count { rms += samples[i] * samples[i] }
        rms = sqrt(rms / Float(count))

        Task { @MainActor in
            if !self.hasSpoken {
                // Calibrate noise floor from the first buffers, then listen for speech
                self.noiseFloorRMS = max(self.noiseFloorRMS * 0.95 + rms * 0.05, 0.0005)
                if rms > self.noiseFloorRMS * self.speechBoostFactor {
                    self.hasSpoken = true
                    self.lastSpeechAt = Date()
                }
            } else if rms > self.noiseFloorRMS * self.speechBoostFactor {
                self.lastSpeechAt = Date()
            }
        }
    }

    private func watchForSilence() {
        Task {
            while isListening {
                try? await Task.sleep(for: .milliseconds(100))
                guard isListening else { return }
                if hasSpoken, Date().timeIntervalSince(lastSpeechAt) > silenceWindow {
                    finishUtterance()
                    return
                }
            }
        }
    }

    private func finishUtterance() {
        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        if !final.isEmpty { onUtterance?(final) }
    }
}

/// Voice output. AVSpeechSynthesizer with the system's installed voices.
/// Kokoro-82M (MLX) would drop in behind this same interface (SPEC.md §6); the
/// voice list and speed slider are already shaped for it.
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false

    /// Persisted so the chosen voice and speed survive a relaunch.
    @Published var voiceIdentifier: String? {
        didSet { UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceKey) }
    }

    /// 0.5x–2x, shown to the user as a multiplier of normal speed.
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: Self.speedKey) }
    }

    private static let voiceKey = "universe.voiceIdentifier"
    private static let speedKey = "universe.speechSpeed"
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        let stored = UserDefaults.standard.double(forKey: Self.speedKey)
        speed = (0.5...2.0).contains(stored) ? stored : 1.0
        voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceKey)
        super.init()
        synthesizer.delegate = self
    }

    /// English voices only — the assistant speaks English, and the full macOS list
    /// runs to hundreds of entries.
    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    var currentVoice: AVSpeechSynthesisVoice? {
        voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func speak(_ text: String) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = currentVoice
        utterance.rate = Self.rate(for: speed)
        synthesizer.speak(utterance)
        isSpeaking = true
        MenuBarMood.shared.setActivity(.speaking)
    }

    /// Speaks one line in a given voice, for the preview button in Voice Settings.
    func preview(voiceIdentifier: String) {
        stop()
        let utterance = AVSpeechUtterance(string: "Hey, this is how I sound.")
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        utterance.rate = Self.rate(for: speed)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    /// Maps a 0.5x–2x multiplier onto AVSpeechUtterance's own rate scale, which is
    /// not linear around its default.
    static func rate(for speed: Double) -> Float {
        let clamped = min(max(speed, 0.5), 2.0)
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let value = clamped >= 1
            ? base + (Double(AVSpeechUtteranceMaximumSpeechRate) - base) * (clamped - 1)
            : Double(AVSpeechUtteranceMinimumSpeechRate) + (base - Double(AVSpeechUtteranceMinimumSpeechRate)) * ((clamped - 0.5) / 0.5)
        return Float(min(max(value, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        if MenuBarMood.shared.mood == .speaking { MenuBarMood.shared.setActivity(nil) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            if MenuBarMood.shared.mood == .speaking { MenuBarMood.shared.setActivity(nil) }
        }
    }
}
