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

/// Voice output. AVSpeechSynthesizer now; Kokoro-82M (MLX) drops in here later (SPEC.md §6).
@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
