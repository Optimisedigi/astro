import AVFoundation
import SwiftUI

/// The Voice Settings sheet: talk-and-listen toggle, Kokoro voice choice, speaking speed.
/// Mirrors tama-agent's voice panel — the same Kokoro-82M model and voice pack, so
/// Universe and Tama sound identical.
struct VoiceSettingsView: View {
    @ObservedObject var state: ChatState
    var onDone: () -> Void = {}

    @ObservedObject private var kokoro = KokoroManager.shared

    var body: some View {
        SettingsSheet(title: "Voice Settings") {
            VoiceSettingsBody(state: state)
        } footer: {
            Text("Active: \(VoiceSettingsBody.voiceName(kokoro.selectedVoice))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct VoiceSettingsBody: View {
    @ObservedObject var state: ChatState
    @ObservedObject private var kokoro = KokoroManager.shared
    @ObservedObject private var realtime = RealtimeVoiceSettings.shared
    @State private var previewingVoice: String?

    init(state: ChatState) { self.state = state }

    static func voiceName(_ id: String) -> String {
        KokoroManager.availableVoices.first { $0.id == id }?.name ?? id
    }

    var body: some View {
        SettingsSheetBody {
            voiceModeRow
            Divider()
            spokenRepliesRow
            Divider()
            liveVoiceSection
            Divider()

            modelRow
            Divider()

            Text("Voice")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(KokoroManager.availableVoices) { voice in
                VoiceRow(
                    voice: voice,
                    isSelected: kokoro.selectedVoice == voice.id,
                    isDownloaded: kokoro.downloadedVoices.contains(voice.id),
                    isDownloading: kokoro.voiceDownloading[voice.id] == true,
                    downloadProgress: kokoro.voiceDownloadProgress[voice.id] ?? 0,
                    modelReady: kokoro.modelDownloaded,
                    isPreviewing: previewingVoice == voice.id,
                    preview: { preview(voice.id) },
                    download: { kokoro.downloadVoice(voice.id) },
                    select: { kokoro.selectedVoice = voice.id }
                )
            }

            Divider()
            speedRow
        }
    }

    private var voiceModeRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.voiceMode ? "mic.fill" : "mic")
                .foregroundStyle(state.voiceMode ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone").fontWeight(.semibold)
                Text(state.voiceMode ? "Ask by talking" : "Type to ask")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Microphone", isOn: Binding(
                get: { state.voiceMode },
                set: { $0 ? state.enableVoiceMode() : state.disableVoiceMode() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
    }

    private var spokenRepliesRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kokoro.speechEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                .foregroundStyle(kokoro.speechEnabled ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Spoken replies").fontWeight(.semibold)
                Text(kokoro.speechEnabled ? "Answers are read out loud" : "Answers stay as text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Spoken replies", isOn: $kokoro.speechEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
    }

    /// Calls from the notch can run on OpenAI's live speech-to-speech model,
    /// paid for by the user's ChatGPT plan instead of the built-in pipeline.
    private var liveVoiceSection: some View {
        let isOn = realtime.engine == .openAIRealtime
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "waveform.circle.fill" : "waveform.circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenAI live voice for calls").fontWeight(.semibold)
                    Text(isOn
                        ? "Calls talk to OpenAI's live voice on your ChatGPT plan — you can interrupt anytime"
                        : "Calls use the built-in voice below")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("OpenAI live voice for calls", isOn: Binding(
                    get: { isOn },
                    set: {
                        realtime.engine = $0 ? .openAIRealtime : .builtIn
                        // Get the live-call audio ready now, so the first call is fast.
                        VoiceService.shared.prepareVoiceProcessing()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .accessibilityElement(children: .combine)

            if isOn {
                if !OpenAIOAuth.isSignedIn {
                    Label("Sign in with ChatGPT in AI Settings to use this.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("Model", selection: $realtime.model) {
                    ForEach(RealtimeVoiceSettings.models) { option in
                        Text("\(option.name) — \(option.detail)").tag(option.id)
                    }
                }
                .onChange(of: realtime.model) { VoiceService.shared.prepareVoiceProcessing() }
                Picker("Voice", selection: $realtime.voice) {
                    ForEach(RealtimeVoiceSettings.voices(for: realtime.model)) { option in
                        Text(option.detail.isEmpty ? option.name : "\(option.name) — \(option.detail)").tag(option.id)
                    }
                }
            }
        }
    }

    /// Kokoro ships as a downloadable model; nothing can speak until it lands.
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kokoro.modelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(kokoro.modelDownloaded ? Color.green : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kokoro TTS Model").fontWeight(.semibold)
                    Text(kokoro.modelDownloaded ? "Ready" : "~350 MB download required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !kokoro.modelDownloaded {
                    if kokoro.modelDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Download") { kokoro.downloadModel() }
                    }
                }
            }
            if kokoro.modelDownloading {
                ProgressView(value: kokoro.modelDownloadProgress)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speech Speed").fontWeight(.semibold)
                Spacer()
                Text(String(format: "%.2f×", kokoro.voiceSpeed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $kokoro.voiceSpeed,
                in: KokoroManager.minSpeed...KokoroManager.maxSpeed,
                step: 0.05
            ) {
                Text("Speech speed")
            } minimumValueLabel: {
                Text("Slower").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Faster").font(.caption2).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .accessibilityValue(String(format: "%.2f times normal speed", Double(kokoro.voiceSpeed)))
        }
    }

    /// Previews a voice without permanently switching the selection. Synthesis
    /// runs off the main actor — Kokoro takes hundreds of milliseconds and would
    /// otherwise freeze the settings sheet.
    private func preview(_ voiceId: String) {
        AudioPreviewPlayer.stop()
        previewingVoice = voiceId

        let previous = kokoro.selectedVoice
        kokoro.selectedVoice = voiceId
        let context = kokoro.captureGenerationContext()
        kokoro.selectedVoice = previous

        guard let context else {
            previewingVoice = nil
            return
        }

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                KokoroManager.generateAudioBufferOffMain(
                    text: "Hey, this is how I sound.",
                    context: context
                )
            }.value

            guard previewingVoice == voiceId else { return }
            guard let buffer = result?.buffer else {
                previewingVoice = nil
                return
            }
            AudioPreviewPlayer.play(buffer) {
                Task { @MainActor in
                    if previewingVoice == voiceId { previewingVoice = nil }
                }
            }
        }
    }
}

struct VoiceRow: View {
    let voice: VoiceInfo
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let modelReady: Bool
    let isPreviewing: Bool
    let preview: () -> Void
    let download: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: preview) {
                Image(systemName: isPreviewing ? "waveform" : "play.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!isDownloaded || !modelReady)
            .accessibilityLabel("Preview \(voice.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(voice.name).fontWeight(.medium)
                    StatusPill(text: voice.grade)
                }
                Text("\(voice.gender == .female ? "Female" : "Male") · \(voice.accent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isDownloading {
                ProgressView(value: downloadProgress).frame(width: 60)
            } else if isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Selected")
                } else {
                    Button("Select", action: select)
                }
            } else if modelReady {
                Button("Download", action: download)
            } else {
                Text("Needs model").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Plays a one-off preview buffer on its own engine, so it never disturbs the
/// persistent playback engine SpeechService keeps running.
final class AudioPreviewPlayer: @unchecked Sendable {
    private static let instance = AudioPreviewPlayer()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var completion: (() -> Void)?

    static func play(_ buffer: AVAudioPCMBuffer, onComplete: @escaping () -> Void) {
        let inst = instance
        inst.stopInternal()
        inst.completion = onComplete

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        do {
            try engine.start()
        } catch {
            inst.completion = nil
            onComplete()
            return
        }

        node.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            let callback = inst.completion
            // Tear the one-shot engine down here, or it keeps the output device
            // open until the next preview.
            inst.stopInternal()
            callback?()
        }
        node.play()

        inst.engine = engine
        inst.player = node
    }

    static func stop() { instance.stopInternal() }

    private func stopInternal() {
        completion = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
    }
}
