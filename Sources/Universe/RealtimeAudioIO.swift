@preconcurrency import AVFoundation
import os

private let logger = Logger(subsystem: "com.universe.app", category: "realtime.audio")

/// Full-duplex audio for a live voice call: microphone → 24 kHz PCM16 chunks,
/// and 24 kHz PCM16 chunks → speakers.
///
/// One `AVAudioEngine` owns both directions with Apple Voice Processing on, so
/// echo cancellation hears exactly what we play. That is what lets the user talk
/// over the assistant without the assistant hearing itself.
final class RealtimeAudioIO: @unchecked Sendable {
    static let sampleRate: Double = 24_000

    /// Called on the audio thread with base64 PCM16 mono 24 kHz audio.
    var onMicrophoneChunk: (@Sendable (String) -> Void)?
    /// Called on the audio thread with the same audio as `onMicrophoneChunk`,
    /// as a buffer (24 kHz mono PCM16), for the live words in the input box.
    var onMicrophoneBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Called on the audio thread with the chunk's loudness, 0…1.
    var onMicrophoneLevel: (@Sendable (Double) -> Void)?
    /// Called on the main thread when queued speech finishes playing.
    var onPlaybackDrained: (@MainActor () -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!
    private let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
    )!
    private var converter: AVAudioConverter?

    private let lock = NSLock()
    private var queuedBuffers = 0
    /// Bumped by `clearPlayback` so completions from flushed buffers are ignored.
    private var playbackGeneration = 0

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return queuedBuffers > 0
    }

    func start() throws {
        // The output side must exist before Voice Processing is switched on.
        // Enabling it first and then wiring the player into the mixer makes
        // `engine.start()` fail with -10875 (reproduced on a MacBook Pro).
        _ = engine.outputNode
        _ = engine.mainMixerNode

        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Without AEC the call still works, it just needs headphones for barge-in.
            logger.warning("Voice processing unavailable: \(error.localizedDescription)")
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RealtimeAudioError.noMicrophone
        }
        guard let converter = Self.makeMicrophoneConverter(from: inputFormat) else {
            throw RealtimeAudioError.noMicrophone
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicrophone(buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()
        logger.info("Audio started — mic \(inputFormat.sampleRate) Hz × \(inputFormat.channelCount)")
    }

    /// With Voice Processing on, a Mac mic array reports several channels (9 on
    /// a MacBook Pro) and the cleaned-up voice is channel 0. Downmixing them
    /// all produced pure silence, so the model heard nothing: take channel 0.
    static func makeMicrophoneConverter(from inputFormat: AVAudioFormat) -> AVAudioConverter? {
        let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let converter = AVAudioConverter(from: inputFormat, to: wire)
        converter?.channelMap = [0]
        return converter
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        // Release the voice-processing unit so the mic (and its indicator) turn off.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        lock.lock(); queuedBuffers = 0; playbackGeneration += 1; lock.unlock()
    }

    /// Queue base64 PCM16 mono 24 kHz audio from the model.
    func play(base64PCM16: String) {
        guard let data = Data(base64Encoded: base64PCM16), data.count >= 2 else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frames),
              let out = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frames) { out[i] = Float(Int16(littleEndian: samples[i])) / 32_768 }
        }

        lock.lock()
        queuedBuffers += 1
        let generation = playbackGeneration
        lock.unlock()

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.bufferFinished(generation: generation)
        }
        if !player.isPlaying { player.play() }
    }

    /// Drop everything queued — used when the user interrupts.
    func clearPlayback() {
        lock.lock(); queuedBuffers = 0; playbackGeneration += 1; lock.unlock()
        player.stop()
        player.play()
    }

    private func bufferFinished(generation: Int) {
        lock.lock()
        guard generation == playbackGeneration else { lock.unlock(); return }
        queuedBuffers = max(0, queuedBuffers - 1)
        let drained = queuedBuffers == 0
        lock.unlock()
        guard drained else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onPlaybackDrained?() }
        }
    }

    private func handleMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = wireFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }

        let count = Int(converted.frameLength)
        var sumSquares: Double = 0
        for i in 0..<count {
            let s = Double(samples[i]) / 32_768
            sumSquares += s * s
        }
        let rms = (sumSquares / Double(count)).squareRoot()
        onMicrophoneLevel?(min(1, rms * 8))

        let data = Data(bytes: samples, count: count * 2)
        onMicrophoneChunk?(data.base64EncodedString())
        onMicrophoneBuffer?(converted)
    }
}

enum RealtimeAudioError: LocalizedError {
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone input is available."
        }
    }
}
