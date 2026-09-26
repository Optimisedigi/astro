import SwiftUI

/// The words typed before a take are stable while speech recognition revises
/// its partial transcript. The request ID also invalidates delayed permission
/// callbacks when the view disappears or a new take begins.
struct JournalDictationSession {
    private var requestID: UUID?
    private var typedPrefix = ""

    mutating func begin(draft: String) -> UUID? {
        guard requestID == nil else { return nil }
        let id = UUID()
        requestID = id
        typedPrefix = draft
        return id
    }

    var hasRequest: Bool { requestID != nil }
    func isCurrent(_ id: UUID) -> Bool { requestID == id }

    func draft(for transcript: String, request id: UUID) -> String? {
        guard isCurrent(id) else { return nil }
        guard !typedPrefix.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return typedPrefix }
        return typedPrefix + (typedPrefix.last?.isWhitespace == true ? "" : " ") + transcript
    }

    mutating func end() {
        requestID = nil
        typedPrefix = ""
    }
}

/// The Journal tab (stored as the diary): full-width dated threads modelled
/// on Pile's visual journal (UdaraJay/Pile). Each day's entries join by a line.
///
/// Stored only on this Mac. Writing here never calls the agent and nothing in
/// the diary is put into a chat prompt. The one exception is tidying: an entry
/// is sent to the model when dictation stops or Format is pressed.
struct DiaryListView: View {
    @ObservedObject var store: DiaryStore

    /// Set by the notch pencil button: start dictating as soon as the tab shows,
    /// so pressing it once is enough to start talking.
    var autoStartDictation: Binding<Bool>?

    init(store: DiaryStore, draft: Binding<String>, autoStartDictation: Binding<Bool>? = nil) {
        self.store = store
        _draft = draft
        self.autoStartDictation = autoStartDictation
    }

    /// Voice capture writes here live, exactly like the chat input. Owned by
    /// the chat state, so an unsaved entry survives switching tabs.
    @Binding var draft: String
    @State private var isDictating = false
    @State private var dictation = JournalDictationSession()
    @State private var editingEntry: UUID?
    @State private var editDraft = ""
    @State private var errorMessage: String?
    @State private var isFormatting = false
    /// The saved entry currently being formatted, so only its row shows a spinner.
    @State private var formattingEntry: UUID?

    private let voice = VoiceService.shared

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                composer
                Divider()
                if store.days.isEmpty {
                    emptyState
                } else {
                    pages(compact: geometry.size.width < 520)
                }
            }
            .frame(maxWidth: .infinity)
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
                    .help(isDictating ? "Stop dictating and tidy the entry" : "Dictate an entry")

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
                        .disabled(!hasDraft || isFormatting)
                        .help(isDictating ? "Stop, tidy the entry and save it" : "Save this entry")
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
        .frame(height: isComposing ? 136 : (errorMessage == nil ? 82 : 100))
    }

    private static let draftAnchor = "diary-draft"

    private func pages(compact: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(store.days) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.heading(for: day.date))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        thread(for: day, compact: compact)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// One day's entries, joined by a line in the colour of its first entry.
    private func thread(for day: DiaryDay, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                DiaryEntryRow(
                    entry: entry,
                    isFirst: index == 0,
                    isLast: index == day.entries.count - 1,
                    threadColor: JournalBall.color(for: day.entries.first?.highlight),
                    compact: compact,
                    isEditing: editingEntry == entry.id,
                    isFormatting: formattingEntry == entry.id,
                    editDraft: $editDraft,
                    onEdit: {
                        editDraft = entry.text
                        editingEntry = entry.id
                    },
                    onSave: {
                        if store.updateEntry(dayKey: day.date, entryID: entry.id, text: editDraft) {
                            editingEntry = nil
                        } else {
                            errorMessage = "Could not save the entry. Try again."
                        }
                    },
                    onCancel: { editingEntry = nil },
                    onFormat: { formatEntry(entry, dayKey: day.date) },
                    onDelete: {
                        if !store.deleteEntry(dayKey: day.date, entryID: entry.id) {
                            errorMessage = "Could not delete the entry. Try again."
                        }
                    },
                    onHighlight: { highlight in
                        if !store.setHighlight(dayKey: day.date, entryID: entry.id, highlight: highlight) {
                            errorMessage = "Could not save the marker. Try again."
                        }
                    }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.heading(for: day.date))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No journal entries yet")
                .font(.headline)
            Text("Write or dictate an entry. Entries stay on this Mac. When you stop dictating or press Format, the entry is sent to the AI model to fix spelling and punctuation in your own words.")
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
        // Matches the disabled Save button: Return must not save mid-tidy.
        guard !isFormatting else { return }
        if dictation.hasRequest && !isDictating { stopDictation() }
        // Saving mid-dictation is "I'm done": tidy the entry, then save it, in
        // one press. Otherwise the rough transcript would be stored as heard.
        if isDictating {
            tidyThenSave()
            return
        }
        guard store.addEntry(draft) else { return }
        draft = ""
    }

    /// Stops dictating, tidies the entry and saves the result. If tidying
    /// fails, the words are saved as spoken so nothing is lost; Format on the
    /// saved entry can tidy it later.
    private func tidyThenSave() {
        // Stop first: finishing the capture delivers the last words into the
        // draft, so saving mid-sentence keeps them instead of dropping them.
        stopDictation()
        let original = draft
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        errorMessage = nil
        isFormatting = true
        Task {
            let tidied: Result<String, Error>
            do {
                tidied = .success(try await DiaryFormatter.format(original))
            } catch {
                tidied = .failure(error)
            }
            isFormatting = false
            guard let text = Self.textToSave(original: original, current: draft, tidied: tidied),
                  store.addEntry(text) else { return }
            draft = ""
            if case let .failure(error) = tidied {
                errorMessage = "Saved as spoken. Could not tidy: \(error.localizedDescription)"
            }
        }
    }

    /// What Save-while-dictating stores once tidying finishes: the tidied text,
    /// or the words as spoken if tidying failed. Nothing if the user edited
    /// the draft meanwhile: their edit stands and they save it themselves.
    static func textToSave(original: String, current: String, tidied: Result<String, Error>) -> String? {
        guard current == original else { return nil }
        switch tidied {
        case let .success(text): return text
        case .failure: return original
        }
    }

    /// Stopping means the user has finished talking, so the entry is tidied
    /// straight away and shown for them to check before they save it.
    private func toggleDictation() {
        if isDictating { formatDraft() }
        else if dictation.hasRequest { stopDictation() }
        else { startDictation() }
    }

    /// Tidies an entry that is already saved, writing the result back in place.
    private func formatEntry(_ entry: DiaryEntry, dayKey: String) {
        guard formattingEntry == nil else { return }
        errorMessage = nil
        formattingEntry = entry.id
        Task {
            do {
                let formatted = try await DiaryFormatter.format(entry.text)
                // The entry may have been edited or removed while the model ran.
                if !store.updateEntry(dayKey: dayKey, entryID: entry.id, text: formatted,
                                      ifUnchangedFrom: entry.text),
                   store.days.first(where: { $0.date == dayKey })?.entries.first(where: { $0.id == entry.id })?.text == entry.text {
                    errorMessage = "Could not save the formatted entry. Try again."
                }
            } catch {
                errorMessage = "Could not format: \(error.localizedDescription)"
            }
            formattingEntry = nil
        }
    }

    /// Sends the draft to the model to be tidied up. The only path by which
    /// diary text leaves this Mac: it runs when the user stops dictating or
    /// presses Format, never on a saved entry by itself.
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
        guard !isFormatting, let request = dictation.begin(draft: draft) else { return }
        errorMessage = nil

        // VoiceService is one shared instance with one set of callbacks, so
        // taking the microphone here would otherwise hijack chat's handlers and
        // leave them nil on stop. Suspend rather than disable: disabling persists
        // the preference, which switched chat's voice mode off for good.
        PanelController.shared.chatState.suspendVoiceMode()

        // Dictation only — the transcript goes straight into the draft and is
        // never handed to the agent.
        voice.onPartialTranscript = { partial in
            if let updated = dictation.draft(for: partial, request: request) { draft = updated }
        }
        voice.onCaptureComplete = { text in
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let updated = dictation.draft(for: text, request: request) { draft = updated }
        }
        voice.onError = { message in
            guard dictation.isCurrent(request) else { return }
            errorMessage = message
            // Startup can report an error before startFollowUpCapture returns;
            // defer cleanup so it cannot reenter an unfinished capture setup.
            Task { if dictation.isCurrent(request) { stopDictation() } }
        }

        guard VoiceService.isAlreadyAuthorized else {
            Task {
                let permitted = await voice.requestPermissions()
                guard dictation.isCurrent(request) else { return }
                guard permitted else {
                    errorMessage = VoiceService.VoiceError.notAuthorized.localizedDescription
                    stopDictation()
                    return
                }
                beginCapture(request: request)
            }
            return
        }
        beginCapture(request: request)
    }

    private func beginCapture(request: UUID) {
        guard dictation.isCurrent(request) else { return }
        // Continuous: a diary entry is written in pauses, so silence must not end
        // the take. It runs until the user presses the mic again.
        voice.startFollowUpCapture(muteAudio: false, voiceProcessing: true, continuous: true)
        guard voice.isListening else {
            errorMessage = VoiceService.VoiceError.noMic.localizedDescription
            stopDictation()
            return
        }
        isDictating = true
    }

    private func stopDictation() {
        // Also cancel permission requests that have not started capture yet.
        guard dictation.hasRequest else { return }
        if isDictating {
            isDictating = false
            // finishCapture delivers what was heard; stopListening discards it.
            voice.finishCapture()
        }
        dictation.end()
        voice.onPartialTranscript = nil
        voice.onCaptureComplete = nil
        voice.onError = nil
        // Give the microphone back to chat if it was listening before.
        PanelController.shared.chatState.resumeVoiceModeIfSuspended()
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

/// One entry in a day's thread: its dot and the thread line on the left, the
/// text in the middle, when it was written (and its actions) on the right.
struct DiaryEntryRow: View {
    let entry: DiaryEntry
    let isFirst: Bool
    let isLast: Bool
    let threadColor: Color
    let compact: Bool
    let isEditing: Bool
    let isFormatting: Bool
    @Binding var editDraft: String
    var onEdit: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void
    var onFormat: () -> Void
    var onDelete: () -> Void
    var onHighlight: (JournalHighlight?) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            JournalBall(highlight: entry.highlight, select: onHighlight)
                .padding(.top, 8)
            content
                .padding(.top, 5)
                .padding(.bottom, isLast ? 0 : 14)
        }
        // Draw the thread behind the marker across the *whole* row, not
        // inside an intrinsically sized VStack (which left gaps on long rows).
        .background {
            GeometryReader { geometry in
                Path { path in
                    let x: CGFloat = 14
                    let markerY: CGFloat = 22 // 8pt inset + half of 28pt target
                    if !isFirst {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: markerY))
                    }
                    if !isLast {
                        path.move(to: CGPoint(x: x, y: markerY))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    }
                }
                .stroke(threadColor, lineWidth: 2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    // No line cap: a dictated entry runs long, and scrolling a
                    // tall entry inside an eight-line box means never seeing the
                    // whole thing at once. The row grows and the tab's own
                    // scroll view handles the overflow.
                    TextField("", text: $editDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
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
            if compact {
                // At narrow widths, metadata moves below instead of
                // squeezing the text to a few characters per line.
                VStack(alignment: .leading, spacing: 6) {
                    entryText
                    HStack {
                        timeLabel
                        Spacer(minLength: 8)
                        actions
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    entryText
                    VStack(alignment: .trailing, spacing: 6) {
                        timeLabel
                        actions
                    }
                    .frame(minWidth: 86, alignment: .trailing)
                }
            }
        }
    }

    private var entryText: some View {
        Text(entry.text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var timeLabel: some View {
        Text(Self.dayLabel(entry.createdAt))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .help(entry.createdAt.formatted(date: .complete, time: .shortened))
    }

    /// Faint until the row is hovered, but always there for the keyboard.
    private var actions: some View {
        HStack(spacing: 10) {
                Button(action: onEdit) {
                    Image(systemName: "pencil").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 1 : 0.7)
                .accessibilityLabel("Edit entry")

                if isFormatting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: onFormat) {
                        Image(systemName: "wand.and.stars").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0.7)
                    .help("Send this entry to the AI model to tidy it up")
                    .accessibilityLabel("Format entry")
                }

                Button(action: onDelete) {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 1 : 0.7)
                .accessibilityLabel("Delete entry")
        }
    }

    /// Calendar date only; full time remains available in the tooltip.
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
        return formatter.string(from: date)
    }
}

/// An entry's dot, which is also its marker menu, as in Pile.
struct JournalBall: View {
    let highlight: JournalHighlight?
    let select: (JournalHighlight?) -> Void

    static func color(for highlight: JournalHighlight?) -> Color {
        guard let highlight else { return Color(.sRGB, red: 0.42, green: 0.42, blue: 0.42) }
        let rgb = highlight.rgb
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var body: some View {
        Menu {
            Button { select(nil) } label: { Label("None", systemImage: "circle") }
            ForEach(JournalHighlight.allCases) { option in
                Button { select(option) } label: {
                    Label(option.name, systemImage: highlight == option ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: {
            Circle()
                .fill(Self.color(for: highlight))
                .frame(width: 14, height: 14)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(highlight.map { "Marked \($0.name). Click to change" } ?? "Mark this entry")
        .accessibilityLabel("Marker: \(highlight?.name ?? "None")")
    }
}
