import SwiftUI

/// The Tools tab: user-facing panel tools, matching tama-agent's ToolListView.
/// Toggle tools (Keep Awake, Night Shift) flip inline with a pill switch;
/// Clipboard History drills into its own view.
struct ToolListView: View {
    @State private var query = ""
    @State private var showingClipboard = false
    /// Bumped by tool onStateChanged callbacks to re-render toggle states.
    @State private var toggleTick = 0

    private var filtered: [PanelTool] { PanelToolRegistry.shared.search(query: query) }

    var body: some View {
        if showingClipboard {
            ClipboardHistoryView(store: ClipboardStore.shared) {
                showingClipboard = false
            }
        } else {
            listIndex
        }
    }

    private var listIndex: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tools")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search tools", text: $query)
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
                        ForEach(filtered, id: \.id) { tool in
                            PanelToolRow(tool: tool, tick: toggleTick) {
                                handleTap(tool)
                            } onToggled: {
                                toggleTick += 1
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleTap(_ tool: PanelTool) {
        ButtonSound.shared.play()
        if let toggle = tool as? any TogglePanelTool {
            toggle.toggle()
            toggleTick += 1
        } else if tool is ClipboardHistoryTool {
            showingClipboard = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No tools found.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// One row: icon, name, description; a pill toggle for toggle tools,
/// a chevron for drilldown tools (matches tama-agent's ToolRowView).
struct PanelToolRow: View {
    let tool: PanelTool
    let tick: Int
    var onTap: () -> Void
    var onToggled: () -> Void

    @State private var isHovered = false

    private var toggleTool: (any TogglePanelTool)? { tool as? any TogglePanelTool }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: tool.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(tool.toolDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let toggle = toggleTool {
                    // tick forces re-evaluation after external state changes
                    let _ = tick
                    Toggle("", isOn: Binding(
                        get: { toggle.isEnabled },
                        set: { _ in
                            ButtonSound.shared.play()
                            toggle.toggle()
                            onToggled()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                } else if let hint = tool.shortcutHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: 52)
            .background(isHovered ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(tool.name). \(tool.toolDescription)")
    }
}
