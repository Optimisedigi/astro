import AVFoundation
import os
import Speech

private let logger = Logger(
    subsystem: "com.universe.app",
    category: "voice"
)

extension AVAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: "not determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}

extension SFSpeechRecognizerAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown (\(rawValue))"
        }
    }
}

/// Mic capture with Apple Voice Processing (AEC), optional system mute, and
/// dual-idle silence detection — same path as tama-agent's VoiceService.
@MainActor
final class VoiceService: ObservableObject {
    static let shared = VoiceService()

    /// Private so a second engine can never open the mic in parallel with the
    /// shared one — two AVAudioEngines on the same input fight and gate audio.
    private init() {}

    enum State: Sendable {
        case idle
        /// Engine + VP running, tap installed, but no recognition task attached
        /// yet. Used to warm up Apple's Voice Processing IO so the AEC has time
        /// to adapt before the user starts speaking.
        case prewarming
        case followUp
    }

    enum VoiceError: LocalizedError {
        case notAuthorized, recognizerUnavailable, noMic

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Microphone/Speech permission not granted. Enable in System Settings > Privacy & Security."
            case .recognizerUnavailable:
                "Speech recognizer unavailable."
            case .noMic:
                "Could not access microphone."
            }
        }
    }

    private(set) var state: State = .idle
    @Published var isListening = false
    @Published var transcript = ""

    /// Fires once per utterance after silence, with the final transcript
    /// (possibly empty). Single slot on purpose: chat and call share this one
    /// service, so two live handlers would send the same utterance twice.
    var onCaptureComplete: ((String) -> Void)?
    var onAudioLevelChanged: ((Double) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFirstSpeech: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var generation: Int = 0
    private var capturedTranscript = ""

    private let minSpeechRMS: Double = 5e-4
    private let speechBoostFactor: Double = 3.0
    private var noiseFloorRMS: Double = 1e-4
    private var didMuteThisSession = false
    private let defaultSilenceWindow: TimeInterval = 1.0
    private var silenceWindow: TimeInterval = 1.0
    private var hasSpoken = false
    private var firstSpeechFired = false
    private var lastHeard: Date?
    private var lastTranscriptUpdate: Date?
    private var silenceTimer: Timer?
    private var prewarmedVoiceProcessing: Bool = false

    /// True when speech recognition and the microphone are both already granted,
    /// so listening can resume silently on launch without raising a prompt.
    static var isAlreadyAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Chat-panel listen: AEC on, no system mute (TTS may still be wrapping up),
    /// default 1.0s dual-idle silence so dictation isn't clipped.
    func startListening() throws {
        guard Self.isAlreadyAuthorized else { throw VoiceError.notAuthorized }
        startFollowUpCapture(muteAudio: false, voiceProcessing: true, silenceDuration: 1.0)
        if state != .followUp { throw VoiceError.noMic }
    }

    func stopListening() {
        stopFollowUpCapture()
    }

    /// Starts capturing speech for hold-to-talk or follow-up prompts.
    /// - Parameters:
    ///   - muteAudio: When `true`, mutes system audio so music/dings aren't heard as speech.
    ///   - voiceProcessing: When `true`, enables Apple AEC on the input node.
    ///   - silenceDuration: Override the silence window. `nil` uses 1.0s.
    func startFollowUpCapture(
        muteAudio: Bool = true,
        voiceProcessing: Bool = false,
        silenceDuration: TimeInterval? = nil
    ) {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            logger.warning("Cannot start speech capture — microphone permission: \(micStatus.description)")
            onError?(VoiceError.notAuthorized.localizedDescription)
            return
        }
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        guard speechStatus == .authorized else {
            logger.warning("Cannot start speech capture — speech permission: \(speechStatus.description)")
            onError?(VoiceError.notAuthorized.localizedDescription)
            return
        }

        logger.info("Starting speech capture")

        let canReusePrewarm = state == .prewarming && prewarmedVoiceProcessing == voiceProcessing && audioEngine != nil
        if !canReusePrewarm {
            generation += 1
            haltPipeline()
        }

        silenceWindow = silenceDuration ?? defaultSilenceWindow
        state = .followUp
        isListening = true
        MenuBarMood.shared.setActivity(.listening)
        capturedTranscript = ""
        transcript = ""
        hasSpoken = false
        firstSpeechFired = false
        lastHeard = Date()
        lastTranscriptUpdate = nil

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.defaultTaskHint = .dictation
        speechRecognizer = recognizer

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            logger.error("Speech recognizer not available")
            haltPipeline()
            state = .idle
            isListening = false
            onError?(VoiceError.recognizerUnavailable.localizedDescription)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        request.addsPunctuation = false
        recognitionRequest = request

        if muteAudio {
            SystemAudioMuter.muteSystemOutput()
            didMuteThisSession = true
        } else {
            didMuteThisSession = false
        }

        if !canReusePrewarm {
            guard setupCaptureEngine(voiceProcessing: voiceProcessing) else {
                state = .idle
                isListening = false
                return
            }
        } else {
            logger.info("Reusing prewarmed capture engine (VP already adapted)")
        }

        let currentGeneration = generation

        recognitionTask = speechRecognizer.recognitionTask(
            with: request
        ) { [weak self] result, _ in
            let nextTranscript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                guard self.state == .followUp else { return }

                if let nextTranscript, !nextTranscript.isEmpty {
                    let changed = nextTranscript != self.capturedTranscript
                    self.capturedTranscript = nextTranscript
                    self.transcript = nextTranscript
                    self.hasSpoken = true
                    if changed {
                        self.lastTranscriptUpdate = Date()
                    }
                    self.onPartialTranscript?(nextTranscript)
                }

                if isFinal {
                    self.finalize()
                }
            }
        }

        startSilenceMonitor()
        logger.info("Speech capture started (generation: \(currentGeneration))")
    }

    /// Starts the audio engine with Voice Processing enabled but without
    /// attaching a speech recognizer so AEC can adapt during TTS playback.
    func prewarmCapture(voiceProcessing: Bool = true) {
        guard state != .followUp else { return }
        if state == .prewarming, prewarmedVoiceProcessing == voiceProcessing, audioEngine != nil {
            return
        }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            logger.info("Skipping prewarm — microphone permission: \(micStatus.description)")
            return
        }

        logger.info("Prewarming capture engine (VP=\(voiceProcessing))")
        generation += 1
        haltPipeline()

        guard setupCaptureEngine(voiceProcessing: voiceProcessing) else { return }
        state = .prewarming
        prewarmedVoiceProcessing = voiceProcessing
    }

    func stopFollowUpCapture() {
        guard state == .followUp || state == .prewarming else { return }
        logger.info("Stopping speech capture (was \(String(describing: self.state)))")
        generation += 1
        haltPipeline()
        state = .idle
        isListening = false
        if MenuBarMood.shared.mood == .listening { MenuBarMood.shared.setActivity(nil) }
    }

    private func setupCaptureEngine(voiceProcessing: Bool) -> Bool {
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode

        if voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                logger.info("Voice processing (AEC) enabled on input node")
            } catch {
                logger.error("Failed to enable voice processing: \(error.localizedDescription)")
            }
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Input node format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            logger.error("Invalid audio format")
            audioEngine = nil
            return false
        }

        let recordingFormat: AVAudioFormat = if voiceProcessing, hwFormat.channelCount > 1,
                                                let mono = AVAudioFormat(
                                                    standardFormatWithSampleRate: hwFormat.sampleRate,
                                                    channels: 1
                                                )
        {
            mono
        } else {
            hwFormat
        }

        if recordingFormat !== hwFormat {
            logger.info("Using mono tap format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount)ch")
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: recordingFormat
        ) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            guard let rms = Self.calculateRMS(buffer: buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .followUp else { return }
                self.noteAudioLevel(rms: rms)
                let threshold = max(self.minSpeechRMS, self.noiseFloorRMS * self.speechBoostFactor)
                self.onAudioLevelChanged?(min(1.0, max(0.0, rms / threshold)))
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
            onError?(VoiceError.noMic.localizedDescription)
            audioEngine = nil
            return false
        }
        return true
    }

    private func finalize() {
        guard state == .followUp else { return }
        let text = capturedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split { $0.isWhitespace }.count
        logger.info("Speech capture finalized — \(words) words, \(text.count) chars")

        haltPipeline()
        state = .idle
        isListening = false
        if MenuBarMood.shared.mood == .listening { MenuBarMood.shared.setActivity(nil) }
        capturedTranscript = ""
        hasSpoken = false
        firstSpeechFired = false
        lastTranscriptUpdate = nil

        onCaptureComplete?(text)
    }

    /// Auto-finalizes when both RMS and transcript updates have been idle
    /// for `silenceWindow`. Prevents cutting off natural pauses.
    private func startSilenceMonitor() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .followUp else {
                    self?.silenceTimer?.invalidate()
                    self?.silenceTimer = nil
                    return
                }
                guard self.hasSpoken, let lastAudio = self.lastHeard else { return }

                let now = Date()
                let audioSilent = now.timeIntervalSince(lastAudio) >= self.silenceWindow
                let transcriptIdle: Bool = if let lastUpdate = self.lastTranscriptUpdate {
                    now.timeIntervalSince(lastUpdate) >= self.silenceWindow
                } else {
                    false
                }

                if audioSilent, transcriptIdle {
                    self.finalize()
                }
            }
        }
    }

    private func haltPipeline() {
        silenceTimer?.invalidate()
        silenceTimer = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        prewarmedVoiceProcessing = false

        speechRecognizer = nil

        if didMuteThisSession {
            SystemAudioMuter.unmuteSystemOutput()
            didMuteThisSession = false
        }
    }

    private func noteAudioLevel(rms: Double) {
        let alpha: Double = rms < noiseFloorRMS ? 0.08 : 0.01
        noiseFloorRMS = max(1e-7, noiseFloorRMS + (rms - noiseFloorRMS) * alpha)

        let threshold = max(minSpeechRMS, noiseFloorRMS * speechBoostFactor)
        if rms >= threshold {
            lastHeard = Date()
            if !firstSpeechFired {
                firstSpeechFired = true
                onFirstSpeech?()
            }
        }
    }

    private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Double? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        var sum: Float = 0
        for i in 0 ..< frameLength {
            let sample = channelDataValue[i]
            sum += sample * sample
        }
        return Double(sqrt(sum / Float(frameLength)))
    }
}
