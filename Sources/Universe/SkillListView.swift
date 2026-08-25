import SwiftUI

/// The Skills tab: filterable list of reusable prompt templates.
/// Matches tama-agent's SkillListView styling.
struct SkillListView: View {
    @ObservedObject var store: SkillStore
    @State private var query = ""
    @State private var selectedSkill: Skill?

    private var filtered: [Skill] { store.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            if let skill = selectedSkill {
                SkillDetailView(skill: skill, store: store, onBack: { selectedSkill = nil })
            } else {
                listIndex
            }
        }
    }

    private var listIndex: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Skills")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search skills", text: $query)
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
                        ForEach(filtered) { skill in
                            SkillRow(skill: skill) {
                                selectedSkill = skill
                            } onDelete: {
                                store.delete(id: skill.id)
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
            Image(systemName: "wand.and.stars")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No skills yet" : "No matching skills")
                .font(.headline)
            Text(query.isEmpty
                 ? "Skills are reusable prompt templates stored as Markdown files."
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

struct SkillRow: View {
    let skill: Skill
    var onSelect: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct SkillDetailView: View {
    let skill: Skill
    @ObservedObject var store: SkillStore
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text(skill.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(skill.content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
