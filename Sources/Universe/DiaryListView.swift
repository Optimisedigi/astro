import SwiftUI

/// The Diary tab: dated pages of entries, newest day first.
///
/// Entirely local. Writing here never calls the agent and nothing in the diary
/// is put into a prompt, so entries are not sent to a model.
struct DiaryListView: View {
    @ObservedObject var store: DiaryStore

    /// Voice capture writes here live, exactly like the chat input.
    @State private var draft = ""
    @State private var isDictating = false
    @State private var editingEntry: UUID?
    @State private var editDraft = ""
    @State private var errorMessage: String?

    private let voice = VoiceService.shared

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider()
            if store.days.isEmpty {
                emptyState
            } else {
                pages
            }
        }
        .onDisappear(perform: stopDictation)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                TextField("What happened today?", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1 ... 6)
                    .onSubmit(commitDraft)

                Button(action: toggleDictation) {
                    Image(systemName: isDictating ? "mic.fill" : "mic")
                        .font(.system(size: 14))
                        .foregroundStyle(isDictating ? Color.red : .secondary)
                }
                .buttonStyle(.plain)
                .help(isDictating ? "Stop dictating" : "Dictate an entry")
                .frame(height: 22)

                Button("Save", action: commitDraft)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(draft.isEmpty ? .tertiary : .secondary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(height: 22)
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
    }

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
            Text("Write or dictate an entry. Diary entries stay on this Mac and are never sent to a model.")
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
        guard store.addEntry(draft) else { return }
        draft = ""
        stopDictation()
    }

    private func toggleDictation() {
        isDictating ? stopDictation() : startDictation()
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
        do {
            try voice.startListening()
            isDictating = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        voice.onPartialTranscript = nil
        voice.onCaptureComplete = nil
        voice.onError = nil
        voice.stopListening()
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
