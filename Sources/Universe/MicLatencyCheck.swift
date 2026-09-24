import AVFoundation
import CoreAudio

/// `Universe --mic-latency-check`: times how long the live-call microphone
/// takes to open, cold and then kept ready, and checks that it is released
/// between calls. Needs microphone permission; records about a second of audio
/// that goes nowhere.
@MainActor
enum MicLatencyCheck {
    static func run() async -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("SKIP: microphone permission not granted to this binary")
            return true
        }
        let audio = RealtimeAudioIO.shared
        let chunks = ChunkCounter()
        audio.onMicrophoneChunk = { _ in chunks.increment() }
        var ok = true

        for (index, label) in ["cold start (sets up echo cancellation)", "second call (kept ready)",
                               "third call (kept ready)"].enumerated() {
            let started = CFAbsoluteTimeGetCurrent()
            do {
                try await audio.start().value
            } catch {
                print("FAIL: \(label): \(error.localizedDescription)")
                return false
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            try? await Task.sleep(for: .milliseconds(400))
            let heard = chunks.take()
            let inUse = appIsUsingMicrophone()
            audio.stop()
            try? await Task.sleep(for: .milliseconds(600))
            let released = !appIsUsingMicrophone()
            print("\(label): mic live in \(ms) ms, \(heard) chunks, mic in use \(inUse), released after \(released)")
            if heard == 0 || !released { ok = false }
            if index > 0, ms > 400 { print("FAIL: kept-ready start took \(ms) ms"); ok = false }
        }
        audio.onMicrophoneChunk = nil

        // The diary and chat dictation path (VoiceService), same measurement.
        let voice = VoiceService.shared
        for (index, label) in ["dictation cold start", "dictation second start (kept ready)"].enumerated() {
            let started = CFAbsoluteTimeGetCurrent()
            voice.prewarmCapture(voiceProcessing: true)
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            try? await Task.sleep(for: .milliseconds(400))
            let inUse = appIsUsingMicrophone()
            voice.stopFollowUpCapture()
            try? await Task.sleep(for: .milliseconds(600))
            let released = !appIsUsingMicrophone()
            print("\(label): mic live in \(ms) ms, mic in use \(inUse), released after \(released)")
            if !inUse || !released { ok = false }
            if index > 0, ms > 400 { print("FAIL: kept-ready dictation start took \(ms) ms"); ok = false }
        }

        print(ok ? "PASS" : "FAIL")
        return ok
    }

    /// Whether this process is recording, as behind the orange mic indicator.
    private static func appIsUsingMicrophone() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var process = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr,
              process != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioProcessPropertyIsRunningInput
        AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running)
        return running != 0
    }
}

private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func take() -> Int { lock.lock(); defer { count = 0; lock.unlock() }; return count }
}
