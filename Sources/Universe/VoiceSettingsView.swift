import AVFoundation
import SwiftUI

/// The Voice Settings sheet: talk-and-listen toggle, voice choice, speaking speed.
struct VoiceSettingsView: View {
    @ObservedObject var state: ChatState
    var onDone: () -> Void = {}

    var body: some View {
        SettingsSheet(title: "Voice Settings") {
            VoiceSettingsBody(state: state)
        } footer: {
            Text("Active: \(state.speech.currentVoice?.name ?? "System default")")
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

    private var voices: [AVSpeechSynthesisVoice] { SpeechService.availableVoices }

    var body: some View {
        SettingsSheetBody {
            voiceModeRow
            Divider()

            Text("Voice")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(voices, id: \.identifier) { voice in
                VoiceRow(
                    voice: voice,
                    isSelected: state.speech.currentVoice?.identifier == voice.identifier,
                    preview: { state.speech.preview(voiceIdentifier: voice.identifier) },
                    select: { state.speech.voiceIdentifier = voice.identifier }
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
                Text("Voice Mode").fontWeight(.semibold)
                Text(state.voiceMode ? "Listening and speaking enabled" : "Type instead of talking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Voice Mode", isOn: Binding(
                get: { state.voiceMode },
                set: { $0 ? state.enableVoiceMode() : state.disableVoiceMode() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .accessibilityElement(children: .combine)
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Speech Speed").fontWeight(.semibold)
                Spacer()
                Text(String(format: "%.2f×", state.speech.speed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $state.speech.speed, in: 0.5...2.0, step: 0.05) {
                Text("Speech speed")
            } minimumValueLabel: {
                Text("Slower").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Faster").font(.caption2).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .accessibilityValue(String(format: "%.2f times normal speed", state.speech.speed))
        }
    }
}

struct VoiceRow: View {
    let voice: AVSpeechSynthesisVoice
    let isSelected: Bool
    let preview: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: preview) {
                Image(systemName: "play.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Preview \(voice.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(voice.name).fontWeight(.medium)
                    if voice.quality != .default {
                        StatusPill(text: voice.quality == .premium ? "Premium" : "Enhanced")
                    }
                }
                Text(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Selected")
            } else {
                Button("Select", action: select)
            }
        }
        .padding(.vertical, 3)
    }
}
