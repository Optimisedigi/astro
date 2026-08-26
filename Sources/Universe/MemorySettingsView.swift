import SwiftUI

/// The Memory sheet: everything the assistant has learned, and a way to delete it.
/// Memory is written by the agent through the `remember` / `soul_set` tools; this
/// pane is for reviewing and forgetting, which is why there is no add form.
struct MemorySettingsView: View {
    var onDone: () -> Void = {}
    @ObservedObject private var memory = MemoryStore.shared
    @State private var confirmingWipe = false

    var body: some View {
        SettingsSheet(title: "Memory") {
            MemorySettingsBody(memory: memory)
        } footer: {
            if confirmingWipe {
                Text("Delete everything?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { confirmingWipe = false }
                Button("Forget All", role: .destructive) {
                    memory.removeAll()
                    confirmingWipe = false
                }
            } else {
                Button("Forget All…") { confirmingWipe = true }
                    .disabled(memory.facts.isEmpty && memory.soul.isEmpty)
            }
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct MemorySettingsBody: View {
    @ObservedObject var memory: MemoryStore

    private var factsByCategory: [(String, [MemoryStore.Fact])] {
        Dictionary(grouping: memory.facts, by: \.category)
            .map { ($0.key, $0.value.sorted { $0.importance > $1.importance }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        SettingsSheetBody {
            if memory.facts.isEmpty && memory.soul.isEmpty {
                emptyState
            } else {
                if !memory.facts.isEmpty { factsSection }
                if !memory.soul.isEmpty {
                    if !memory.facts.isEmpty { Divider() }
                    soulSection
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing remembered yet").fontWeight(.semibold)
            Text("Tell the assistant about yourself — your name, what you're working on, how you like to be spoken to — and it saves what matters here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Facts").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(memory.factsStoreUsage.pct)% of store used")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(factsByCategory, id: \.0) { category, facts in
                Text(category)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                ForEach(facts) { fact in
                    MemoryRow(
                        title: fact.subject,
                        detail: fact.content,
                        badge: fact.sensitive ? "private" : nil,
                        delete: { memory.deleteFact(fact) }
                    )
                }
            }
        }
    }

    private var soulSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Soul").font(.caption).foregroundStyle(.secondary)
            Text("How the assistant has learned to work with you.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(memory.soul) { aspect in
                MemoryRow(
                    title: aspect.aspect,
                    detail: aspect.content,
                    badge: nil,
                    delete: { memory.deleteSoulAspect(aspect) }
                )
            }
        }
    }
}

struct MemoryRow: View {
    let title: String
    let detail: String
    let badge: String?
    let delete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if let badge { StatusPill(text: badge) }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: delete) {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.25)
            .accessibilityLabel("Forget \(title)")
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}
