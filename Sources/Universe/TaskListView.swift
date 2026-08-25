import SwiftUI

/// The Tasks tab: grouped task lists with checkboxes, matching tama-agent's layout.
struct TaskListView: View {
    @ObservedObject var store: TaskStore
    @State private var selectedList: TaskList?
    @State private var newListTitle = ""
    @State private var showNewList = false

    var body: some View {
        VStack(spacing: 0) {
            if let list = selectedList {
                TaskListDetailView(list: list, store: store, onBack: { selectedList = nil })
            } else {
                listIndex
            }
        }
    }

    private var listIndex: some View {
        VStack(spacing: 0) {
            // Header with add button
            HStack {
                Text("Tasks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showNewList = true }) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("New task list")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.taskLists.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.grouped(), id: \.label) { group in
                            SectionHeader(title: group.label)
                            ForEach(group.lists) { list in
                                TaskListRow(list: list) {
                                    selectedList = list
                                } onDelete: {
                                    store.delete(id: list.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert("New Task List", isPresented: $showNewList) {
            TextField("List title", text: $newListTitle)
            Button("Create") {
                guard !newListTitle.isEmpty else { return }
                selectedList = store.createList(title: newListTitle)
                newListTitle = ""
            }
            Button("Cancel", role: .cancel) { newListTitle = "" }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No task lists yet")
                .font(.headline)
            Text("Create a list to track what needs doing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct TaskListRow: View {
    let list: TaskList
    var onSelect: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(list.title)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(list.completedCount)/\(list.totalCount)")
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
                    Text(relativeTime(list.updatedAt))
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

struct TaskListDetailView: View {
    let list: TaskList
    @ObservedObject var store: TaskStore
    var onBack: () -> Void
    @State private var newItemTitle = ""

    private var currentList: TaskList {
        store.taskLists.first(where: { $0.id == list.id }) ?? list
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text(currentList.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(currentList.completedCount)/\(currentList.totalCount)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Items
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(currentList.items) { item in
                        TaskItemRow(item: item) {
                            store.toggleItem(listID: currentList.id, itemID: item.id)
                        } onDelete: {
                            store.deleteItem(listID: currentList.id, itemID: item.id)
                        }
                    }
                }
            }

            Divider()

            // Add item
            HStack(spacing: 8) {
                TextField("New item", text: $newItemTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !newItemTitle.isEmpty else { return }
                        store.addItem(to: currentList.id, title: newItemTitle)
                        newItemTitle = ""
                    }
                Button(action: {
                    guard !newItemTitle.isEmpty else { return }
                    store.addItem(to: currentList.id, title: newItemTitle)
                    newItemTitle = ""
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(newItemTitle.isEmpty)
            }
            .padding(10)
        }
    }
}

struct TaskItemRow: View {
    let item: TaskItem
    var onToggle: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Text(item.title)
                .font(.system(size: 14))
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                .strikethrough(item.isCompleted, color: .secondary)

            Spacer()

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovered ? Color.white.opacity(0.06) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}
