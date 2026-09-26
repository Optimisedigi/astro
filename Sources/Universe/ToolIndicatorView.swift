import SwiftUI
import ThinkingOrbsKit

/// One tool call as the UI sees it.
struct ToolRun: Identifiable, Equatable {
    enum Status: Equatable { case running, done, failed }

    let id: String
    let name: String
    let detail: String?
    var status: Status = .running

    /// SF Symbol per tool — one icon family, no emoji (DESIGN.md).
    var symbol: String {
        switch name {
        case "read": return "doc.text"
        case "write": return "square.and.pencil"
        case "edit": return "pencil.line"
        case "bash": return "terminal"
        case "ls", "find": return "folder"
        case "grep": return "text.magnifyingglass"
        case "web_fetch": return "globe"
        case "generate_image": return "photo"
        case "knowledge_search": return "books.vertical"
        case let n where n.contains("reminder") || n.contains("schedule"): return "alarm"
        default: return "wrench.and.screwdriver"
        }
    }

    /// Human-readable chip text. Raw tool names are fine for developer tools,
    /// but the library search has to be unmistakable in the transcript —
    /// it is how the user knows an answer came from their own saved sources.
    var label: String {
        switch name {
        case "knowledge_search": return "Knowledge Library"
        case "generate_image":
            switch status {
            case .running: return "Creating image"
            case .done: return "Image created"
            case .failed: return "Image failed"
            }
        default: return name
        }
    }

    var showsImageOrb: Bool { name == "generate_image" && status == .running }
    var progressLabel: String { "Nebulising..." }
}

/// The stack of tool rows for the current turn.
struct ToolIndicatorView: View {
    let runs: [ToolRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(runs) { run in
                ToolRowView(run: run)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolRowView: View {
    let run: ToolRun

    var body: some View {
        Group {
            if run.showsImageOrb {
                ImageGenerationWorkingView(label: run.progressLabel)
            } else {
                toolRow
            }
        }
    }

    private var toolRow: some View {
        HStack(spacing: 8) {
            Image(systemName: run.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(run.label)
                .font(.caption.weight(.medium))
            if let detail = run.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            status
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.label) \(run.detail ?? "") \(statusLabel)")
    }

    @ViewBuilder
    private var status: some View {
        switch run.status {
        case .running:
            // A pulsing symbol rather than ProgressView: same signal, and it rasterises
            // in `--render-states` so the running row is actually gated.
            PulsingDot()
        case .done:
            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
        }
    }

    private var statusLabel: String {
        switch run.status {
        case .running: return "running"
        case .done: return "finished"
        case .failed: return "failed"
        }
    }
}

/// Native SwiftUI port of the same Libraries.dev working orb already used in
/// Astro's composer. It appears only while the image tool is actually running.
private struct ImageGenerationWorkingView: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            ThinkingOrb(state: .working, size: .px64, displaySize: 52)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                Text(label).hidden() // Reserve space so the capsule doesn't resize on each dot.
                if reduceMotion {
                    Text(label)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.45)) { context in
                        let count = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 4
                        Text(String(label.dropLast(3)) + String(repeating: ".", count: count))
                    }
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nebulising image")
        .accessibilityValue("In progress")
    }
}

private struct PulsingDot: View {
    @State private var faded = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .opacity(faded ? 0.3 : 1)
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { faded = true }
            }
            .accessibilityHidden(true)
    }
}
