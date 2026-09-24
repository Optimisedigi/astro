@preconcurrency import AVFoundation
import Foundation
import os
import Speech

private let logger = Logger(subsystem: "com.universe.app", category: "realtime.dictation")

/// Word-by-word text for the "Ask anything" box while the user talks on a live
/// OpenAI call.
///
/// OpenAI only starts transcribing a turn after the user pauses, so its text
/// cannot follow along as they speak. Apple's recogniser can: it is fed the
/// call's own microphone audio (no second mic engine, which is what broke
/// calls before), has no per-use fee and gives partial results within a few
/// hundred milliseconds. It runs on-device when the Mac supports that, so the
/// audio then stays local; otherwise Apple's servers recognise it, as with
/// macOS dictation. OpenAI's more accurate text still becomes the chat
/// history; this only drives the box.
final class LiveDictation: @unchecked Sendable {
    /// Called on the main actor with the turn's OpenAI item id and the words so far.
    var onText: (@MainActor (_ itemId: String, _ text: String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var itemId: String?
    /// Bumped on every new turn or discard, so late results from an old turn are ignored.
    private var generation = 0
    /// The last second of call audio. OpenAI reports speech has started only
    /// after hearing some of it (plus network delay), so a new turn is primed
    /// with this, or its first word would never reach the box.
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    static let prerollSeconds: Double = 1.0

    init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
        recognizer?.defaultTaskHint = .dictation
    }

    /// True when Apple speech recognition may run. Starting a call asks for it
    /// (with the microphone) whenever either permission is missing.
    static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// True while this turn's words come from Apple (so OpenAI's words are not
    /// also written into the box).
    func isFollowing(itemId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.itemId == itemId && task != nil
    }

    /// The user started a new turn: start following it.
    func beginTurn(itemId: String) {
        guard Self.isAuthorized, let recognizer, recognizer.isAvailable else { return }
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        newRequest.addsPunctuation = true
        // Keep the audio on the Mac when it can recognise speech locally.
        newRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        lock.lock()
        request?.endAudio()
        task?.cancel()
        generation += 1
        let turn = generation
        request = newRequest
        self.itemId = itemId
        // The words said just before OpenAI noticed the turn started. Added while
        // holding the lock, so live audio can only follow them, never jump ahead.
        for buffer in preroll { newRequest.append(buffer) }
        lock.unlock()

        let newTask = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            if let error {
                logger.debug("Dictation segment ended: \(error.localizedDescription, privacy: .public)")
                // Stop claiming this turn, so OpenAI's words fill the box instead.
                self?.releaseFailed(turn)
            }
            guard let text = result?.bestTranscription.formattedString, !text.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isCurrent(turn) else { return }
                    self.onText?(itemId, text)
                }
            }
        }
        lock.lock()
        if generation == turn { task = newTask } else { newTask.cancel() }
        lock.unlock()
    }

    /// The user paused: no more audio for this turn, but keep its last words showing.
    func endTurn() {
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
    }

    /// OpenAI's final text for this turn arrived: stop following it.
    func discard(itemId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard self.itemId == itemId else { return }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        self.itemId = nil
        generation += 1
    }

    func stop() {
        lock.lock()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        itemId = nil
        generation += 1
        preroll = []
        prerollFrames = 0
        lock.unlock()
    }

    /// Audio thread: the call's microphone audio (24 kHz mono PCM16, the same
    /// audio OpenAI receives).
    func append(pcm16 buffer: AVAudioPCMBuffer) {
        guard let float = Self.floatBuffer(from: buffer) else { return }
        lock.lock()
        let current = request
        preroll.append(float)
        prerollFrames += float.frameLength
        let keep = AVAudioFrameCount(float.format.sampleRate * Self.prerollSeconds)
        while prerollFrames > keep, let oldest = preroll.first, preroll.count > 1 {
            preroll.removeFirst()
            prerollFrames -= oldest.frameLength
        }
        lock.unlock()
        current?.append(float)
    }

    private func isCurrent(_ turn: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == turn
    }

    /// The recogniser gave up on this turn (error, no speech, not available).
    private func releaseFailed(_ turn: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == turn else { return }
        task = nil
        request = nil
    }

    /// For the self-test: how much call audio is held for priming a new turn.
    var prerollDurationForTesting: Double {
        lock.lock(); defer { lock.unlock() }
        guard let rate = preroll.first?.format.sampleRate else { return 0 }
        return Double(prerollFrames) / rate
    }

    /// Apple's recogniser is fed float samples; the call's audio is PCM16.
    static func floatBuffer(from pcm16: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let samples = pcm16.int16ChannelData?[0],
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm16.format.sampleRate,
                                         channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: pcm16.frameLength),
              let dest = out.floatChannelData?[0]
        else { return nil }
        out.frameLength = pcm16.frameLength
        for i in 0..<Int(pcm16.frameLength) { dest[i] = Float(samples[i]) / 32_768 }
        return out
    }
}

// MARK: - Offline check

extension LiveDictation {
    /// `--dictation-check <audio file> <output file>`: runs the live-box dictation
    /// on a recording, fed exactly like the call's microphone (24 kHz PCM16 in
    /// small chunks), and writes every partial result it produced. Run inside the
    /// app so it uses Astro's speech-recognition permission.
    @MainActor
    static func runCheck(audioPath: String, outputPath: String) -> Bool {
        var lines: [String] = []
        func finish(_ ok: Bool) -> Bool {
            lines.append(ok ? "DICTATION-CHECK PASSED" : "DICTATION-CHECK FAILED")
            try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
            return ok
        }
        guard isAuthorized else {
            lines.append("speech recognition not authorized for this app")
            return finish(false)
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: audioPath)),
              let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: wire),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil
        else {
            lines.append("could not read \(audioPath)")
            return finish(false)
        }

        let dictation = LiveDictation()
        var partials: [String] = []
        dictation.onText = { _, text in partials.append(text) }
        dictation.beginTurn(itemId: "check")

        // Convert the whole recording, then feed it in 100 ms chunks like the mic tap.
        let total = AVAudioFrameCount(Double(source.frameLength) * 24_000 / file.processingFormat.sampleRate) + 1_024
        guard let pcm = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: total) else { return finish(false) }
        var fed = false
        converter.convert(to: pcm, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        let chunk = 2_400
        var offset = 0
        while offset < Int(pcm.frameLength) {
            let count = min(chunk, Int(pcm.frameLength) - offset)
            guard let piece = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: AVAudioFrameCount(count)),
                  let from = pcm.int16ChannelData?[0], let to = piece.int16ChannelData?[0] else { break }
            piece.frameLength = AVAudioFrameCount(count)
            to.update(from: from + offset, count: count)
            dictation.append(pcm16: piece)
            offset += count
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        dictation.endTurn()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        dictation.stop()

        lines.append("partial results: \(partials.count)")
        lines.append(contentsOf: partials.map { "  \($0)" })
        return finish(partials.count >= 2)
    }
}
