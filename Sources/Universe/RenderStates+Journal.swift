import SwiftUI

/// The Journal tab asserted by `--render-states`. Scroll views don't rasterise
/// offscreen, so sample threads are laid out directly (never the user's journal).
@MainActor
extension RenderStates {
    static var journalStates: [State] {
        [State("journal-timeline", size: CGSize(width: 640, height: 470)) { JournalPreview() },
         State("journal-timeline-compact", size: CGSize(width: 420, height: 440)) { JournalPreview(compact: true) }]
    }
}

@MainActor
struct JournalPreview: View {
    var compact = false
    var contentHeight: CGFloat?
    private static let now = Date()

    private static func daysAgo(_ days: Int, hours: Int = 0) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let day = calendar.date(byAdding: .day, value: -days, to: today),
              let timestamp = calendar.date(byAdding: .hour, value: 12 - hours, to: day) else { return now }
        return timestamp
    }

    private static func day(_ ago: Int, _ entries: [DiaryEntry]) -> DiaryDay {
        DiaryDay(date: DiaryStore.key(for: daysAgo(ago)), entries: entries)
    }

    private static var sample: [DiaryDay] {
        [
            day(0, [DiaryEntry(text: "Conceptual integrity", createdAt: daysAgo(0, hours: 2), highlight: .highlight),
                    DiaryEntry(text: "Brooks: better to omit anomalous features than to have many good but uncoordinated ideas. Consistency beats a pile of impressive, disconnected parts.",
                               createdAt: daysAgo(0, hours: 1))]),
            day(2, [DiaryEntry(text: "Bits, bytes, and a whole lot of websites.", createdAt: daysAgo(2))]),
            day(3, [DiaryEntry(text: "A game where two teams go undercover in an NPC world and carry out a mission.",
                               createdAt: daysAgo(3), highlight: .newIdea),
                    DiaryEntry(text: "What if their actions changed the NPC world? Teams could invent secret codes to find each other.",
                               createdAt: daysAgo(3)),
                    DiaryEntry(text: "Try it with friends this weekend.", createdAt: daysAgo(3), highlight: .doLater)]),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text("What happened today?")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    Image(systemName: "mic").font(.system(size: 14))
                    Text("Format").font(.caption.weight(.semibold))
                    Text("Save").font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(width: 52)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: 82)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Self.sample) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(DiaryListView.heading(for: day.date))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                                DiaryEntryRow(entry: entry, isFirst: index == 0, isLast: index == day.entries.count - 1,
                                              threadColor: JournalBall.color(for: day.entries.first?.highlight),
                                              compact: compact, isEditing: false, isFormatting: false, editDraft: .constant(""),
                                              onEdit: {}, onSave: {}, onCancel: {}, onFormat: {}, onDelete: {},
                                              onHighlight: { _ in })
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: contentHeight ?? (compact ? 358 : 388), alignment: .top)
            .clipped()
        }
        .environment(\.colorScheme, .dark)
        .background(Color(white: 0.11))
    }
}
