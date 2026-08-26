import SwiftUI

/// The Diary tab: dated pages of entries, newest day first.
///
/// Entirely local. Writing here never calls the agent and nothing in the diary
/// is put into a prompt, so entries are not sent to a model.
struct DiaryListView: View {
    @ObservedObject var store: DiaryStore

    /// Set by the notch pencil button: start dictating as soon as the tab shows,
    /// so pressing it once is enough to start talking.
    var autoStartDictation: Binding<Bool>?

    /// Voice capture writes here live, exactly like the chat input.
    @State private var draft = ""
    @State private var isDictating = false
    @State private var editingEntry: UUID?
    @State private var editDraft = ""
    @State private var errorMessage: String?
    @State private var isFormatting = false

    private let voice = VoiceService.shared

    var body: some View {
        VStack(spacing: 0) {
            composer
            // While writing, the composer takes the whole pane so a long entry
            // stays visible instead of scrolling out of a few lines.
            if !isComposing {
                Divider()
                if store.days.isEmpty {
                    emptyState
                } else {
                    pages
                }
            }
        }
        .onAppear(perform: consumeAutoStart)
        .onChange(of: autoStartDictation?.wrappedValue ?? false) { _, _ in consumeAutoStart() }
        .onDisappear(perform: stopDictation)
    }

    /// Honours a pending auto-start request exactly once.
    private func consumeAutoStart() {
        guard autoStartDictation?.wrappedValue == true else { return }
        autoStartDictation?.wrappedValue = false
        guard !isDictating else { return }
        startDictation()
    }

    // MARK: - Composer

    /// True once there is something being written or dictated.
    private var isComposing: Bool {
        isDictating || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                // A ScrollView keeps the newest words in view once the entry is
                // longer than the pane; a plain growing field would push them off
                // the bottom.
                ScrollViewReader { proxy in
                    ScrollView {
                        TextField("What happened today?", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .onSubmit(commitDraft)
                            .id(Self.draftAnchor)
                    }
                    .onChange(of: draft) { _, _ in
                        guard isDictating else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(Self.draftAnchor, anchor: .bottom)
                        }
                    }
                }

                VStack(spacing: 8) {
                    Button(action: toggleDictation) {
                        Image(systemName: isDictating ? "mic.fill" : "mic")
                            .font(.system(size: 14))
                            .foregroundStyle(isDictating ? Color.red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isDictating ? "Stop dictating" : "Dictate an entry")

                    if isFormatting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Format", action: formatDraft)
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(hasDraft ? .secondary : .tertiary)
                            .disabled(!hasDraft)
                            .help("Send this entry to the AI model to tidy it up")
                    }

                    Button("Save", action: commitDraft)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hasDraft ? .secondary : .tertiary)
                        .disabled(!hasDraft)
                }
                .frame(width: 52)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: isComposing ? .infinity : 120)
    }

    private static let draftAnchor = "diary-draft"

    private var pages: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.days) { day in
                    SectionHeader(title: Self.heading(for: day.date))
                    ForEach(day.entries) { entry in
                        DiaryEntryRow(
                            entry: entry,
                            isEditing: editingEntry == entry.id,
                            editDraft: $editDraft,
                            onEdit: {
                                editDraft = entry.text
                                editingEntry = entry.id
                            },
                            onSave: {
                                store.updateEntry(dayKey: day.date, entryID: entry.id, text: editDraft)
                                editingEntry = nil
                            },
                            onCancel: { editingEntry = nil },
                            onDelete: { store.deleteEntry(dayKey: day.date, entryID: entry.id) }
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No diary entries yet")
                .font(.headline)
            Text("Write or dictate an entry. Entries are stored only on this Mac — nothing is sent to a model unless you press Format.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func commitDraft() {
        // Stop first: finishing the capture delivers the last words into the
        // draft, so saving mid-sentence keeps them instead of dropping them — and
        // clearing the draft afterwards is not undone by a late transcript.
        stopDictation()
        guard store.addEntry(draft) else { return }
        draft = ""
    }

    private func toggleDictation() {
        isDictating ? stopDictation() : startDictation()
    }

    /// Sends the draft to the model to be tidied up. The only path by which
    /// diary text leaves this Mac, and it never runs on its own.
    private func formatDraft() {
        // Stop dictating first, exactly as saving does. Formatting is something
        // you reach for when you have finished talking, and leaving the mic open
        // would let a late transcript overwrite the formatted text.
        stopDictation()

        let original = draft
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        isFormatting = true
        Task {
            do {
                let formatted = try await DiaryFormatter.format(original)
                // Only replace if the user has not carried on writing meanwhile.
                if draft == original { draft = formatted }
            } catch {
                errorMessage = "Could not format: \(error.localizedDescription)"
            }
            isFormatting = false
        }
    }

    private func startDictation() {
        errorMessage = nil

        // VoiceService is one shared instance with one set of callbacks, so
        // taking the microphone here would otherwise hijack chat's handlers and
        // leave them nil on stop — silently breaking the chat mic. Turn chat
        // voice mode off first; it unhooks itself cleanly and the user re-arms
        // it with its own mic button.
        PanelController.shared.chatState.disableVoiceMode()

        // Dictation only — the transcript goes straight into the draft and is
        // never handed to the agent.
        voice.onPartialTranscript = { partial in draft = partial }
        voice.onCaptureComplete = { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { draft = trimmed }
        }
        voice.onError = { message in
            errorMessage = message
            stopDictation()
        }

        guard VoiceService.isAlreadyAuthorized else {
            Task {
                guard await voice.requestPermissions() else {
                    errorMessage = VoiceService.VoiceError.notAuthorized.localizedDescription
                    return
                }
                beginCapture()
            }
            return
        }
        beginCapture()
    }

    private func beginCapture() {
        // Continuous: a diary entry is written in pauses, so silence must not end
        // the take. It runs until the user presses the mic again.
        voice.startFollowUpCapture(muteAudio: false, voiceProcessing: true, continuous: true)
        guard voice.isListening else {
            errorMessage = VoiceService.VoiceError.noMic.localizedDescription
            return
        }
        isDictating = true
    }

    private func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        // finishCapture delivers what was heard; stopListening would discard it.
        voice.finishCapture()
        voice.onPartialTranscript = nil
        voice.onCaptureComplete = nil
        voice.onError = nil
    }

    /// "Today" / "Yesterday" / "Tuesday, 26 August 2026".
    static func heading(for key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let display = DateFormatter()
        display.dateFormat = "EEEE, d MMMM yyyy"
        return display.string(from: date)
    }
}

struct DiaryEntryRow: View {
    let entry: DiaryEntry
    let isEditing: Bool
    @Binding var editDraft: String
    var onEdit: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.createdAt, style: .time)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)

            if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("", text: $editDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .lineLimit(1 ... 8)
                        .onSubmit(onSave)
                    HStack(spacing: 8) {
                        Button("Save", action: onSave)
                        Button("Cancel", action: onCancel)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(entry.text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 1 : 0.25)
                .accessibilityLabel("Edit entry")

                Button(action: onDelete) {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 1 : 0.25)
                .accessibilityLabel("Delete entry")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .onHover { isHovered = $0 }
    }
}
