import SwiftUI

/// The Sessions tab: chat history grouped by date, matching tama-agent's SessionListView.
struct SessionListView: View {
    @ObservedObject var store: SessionStore
    var onSelectSession: (Session) -> Void
    var onDeleteSession: (Session) -> Void

    @State private var query = ""

    private var filtered: [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.sessions }
        return store.sessions.filter { $0.title.lowercased().contains(q) }
    }

    private var grouped: [(label: String, sessions: [Session])] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let week = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? today
        let month = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? today

        var buckets: [(String, [Session])] = []
        let t = filtered.filter { $0.updatedAt >= today }
        let w = filtered.filter { $0.updatedAt >= week && $0.updatedAt < today }
        let m = filtered.filter { $0.updatedAt >= month && $0.updatedAt < week }
        let o = filtered.filter { $0.updatedAt < month }
        if !t.isEmpty { buckets.append(("Today", t)) }
        if !w.isEmpty { buckets.append(("This Week", w)) }
        if !m.isEmpty { buckets.append(("This Month", m)) }
        if !o.isEmpty { buckets.append(("Older", o)) }
        return buckets
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(grouped, id: \.label) { group in
                            SectionHeader(title: group.label)
                            ForEach(group.sessions) { session in
                                SessionRow(session: session) {
                                    onSelectSession(session)
                                } onDelete: {
                                    onDeleteSession(session)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No sessions yet" : "No matching sessions")
                .font(.headline)
            Text(query.isEmpty
                 ? "Start a conversation to create your first session."
                 : "Try a different search term.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct SessionRow: View {
    let session: Session
    var onSelect: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(session.messages.count) messages")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isHovered {
                    Button(action: onDelete) {
                        Text("Delete")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(relativeTime(session.updatedAt))
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func relativeTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 {
            let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f.string(from: date)
        }
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: date)
    }
}
