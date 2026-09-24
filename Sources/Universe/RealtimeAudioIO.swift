@preconcurrency import AVFoundation
import os

private let logger = Logger(subsystem: "com.universe.app", category: "realtime.audio")

/// Full-duplex audio for a live voice call: microphone → 24 kHz PCM16 chunks,
/// and 24 kHz PCM16 chunks → speakers.
///
/// One `AVAudioEngine` owns both directions with Apple Voice Processing on, so
/// echo cancellation hears exactly what we play. That is what lets the user talk
/// over the assistant without the assistant hearing itself.
///
/// Switching Voice Processing on takes over a second, so it is done once and
/// the engine is kept between calls: each call then only starts and stops it
/// (about 0.1 s). A stopped engine does not use the microphone, so the mic and
/// its indicator are still off between calls. All engine work runs on a
/// private queue, so it never freezes the window.
final class RealtimeAudioIO: @unchecked Sendable {
    static let shared = RealtimeAudioIO()
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

    private let queue = DispatchQueue(label: "com.universe.realtime-audio", qos: .userInitiated)
    /// Only touched on `queue`. Rebuilt when the default devices change.
    private var engine: AVAudioEngine?
    private var engineDevices: DefaultAudioDevices?
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
    /// True while the engine runs. Guards the player: playing on a stopped
    /// engine raises an exception.
    private var running = false

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return queuedBuffers > 0
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Builds the engine and switches Voice Processing on in the background,
    /// so the first call does not pay for it. Does not open the microphone.
    func prepare() {
        queue.async { [self] in
            guard !isRunning else { return }
            if engine == nil || engineDevices != DefaultAudioDevices.current() { rebuildEngine() }
        }
    }

    /// Opens the microphone and speakers. The work is queued at once, in call
    /// order, so a `stop()` made right after always lands after it; the
    /// returned task finishes when audio is flowing.
    func start() -> Task<Void, Error> {
        let result = StartResult()
        let requested = CFAbsoluteTimeGetCurrent()
        queue.async { [self] in
            result.finish(Result {
                try startOnQueue()
                let ms = Int((CFAbsoluteTimeGetCurrent() - requested) * 1000)
                logger.info("Microphone live in \(ms) ms")
            })
        }
        return Task { try await result.value() }
    }

    private func startOnQueue() throws {
        if engine == nil || engineDevices != DefaultAudioDevices.current() { rebuildEngine() }
        do {
            try beginCapture()
        } catch {
            // The kept engine can go stale in ways the device check misses;
            // one fresh build is still faster than failing the call.
            logger.warning("Kept audio engine failed to start, rebuilding: \(error.localizedDescription)")
            rebuildEngine()
            try beginCapture()
        }
    }

    /// Replaces the engine with a fresh one with Voice Processing on. The slow
    /// part (over a second): only ever called on `queue`, never on main.
    private func rebuildEngine() {
        if let old = engine {
            old.detach(player)
            try? old.inputNode.setVoiceProcessingEnabled(false)
        }
        let started = CFAbsoluteTimeGetCurrent()
        let engine = AVAudioEngine()
        // The output side must exist before Voice Processing is switched on.
        // Enabling it first and then wiring the player into the mixer makes
        // `engine.start()` fail with -10875 (reproduced on a MacBook Pro).
        _ = engine.outputNode
        _ = engine.mainMixerNode
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Without AEC the call still works, it just needs headphones for barge-in.
            logger.warning("Voice processing unavailable: \(error.localizedDescription)")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        self.engine = engine
        engineDevices = DefaultAudioDevices.current()
        let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        logger.info("Audio engine ready (voice processing on) in \(ms) ms")
    }

    private func beginCapture() throws {
        guard let engine else { throw RealtimeAudioError.noMicrophone }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RealtimeAudioError.noMicrophone
        }
        guard let converter = Self.makeMicrophoneConverter(from: inputFormat) else {
            throw RealtimeAudioError.noMicrophone
        }
        self.converter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_400, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicrophone(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        player.play()
        lock.lock(); running = true; lock.unlock()
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

    /// Closes the microphone and speakers. Voice Processing stays switched on
    /// so the next call starts fast; a stopped engine does not hold the mic, so
    /// its indicator turns off (checked on a MacBook Pro).
    func stop() {
        lock.lock(); running = false; queuedBuffers = 0; playbackGeneration += 1; lock.unlock()
        queue.async { [self] in
            guard let engine else { return }
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
        }
    }

    /// Queue base64 PCM16 mono 24 kHz audio from the model.
    func play(base64PCM16: String) {
        guard isRunning, let data = Data(base64Encoded: base64PCM16), data.count >= 2 else { return }
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
        guard isRunning else { return }
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

/// The outcome of one `RealtimeAudioIO.start()`, handed from the audio queue to
/// whoever awaits it, whichever of the two happens first.
private final class StartResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: result)
        } else {
            self.result = result
            lock.unlock()
        }
    }

    func value() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Holds microphone audio recorded before the call's connection is ready, then
/// sends it in order once it is, so the user can talk straight away without
/// losing their first words. Called from the audio thread.
final class MicChunkRelay: @unchecked Sendable {
    /// About 20 s of 50 ms chunks. A connection slower than that has failed;
    /// the oldest audio is dropped rather than growing without limit.
    static let maxPending = 400

    private let lock = NSLock()
    private var pending: [String] = []
    private var sink: ((String) -> Void)?

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        if let sink {
            sink(chunk)
            return
        }
        pending.append(chunk)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
    }

    /// Sends everything held so far, then every later chunk, to `sink`.
    func attach(_ sink: @escaping (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        for chunk in pending { sink(chunk) }
        pending = []
        self.sink = sink
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        sink = nil
        pending = []
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
