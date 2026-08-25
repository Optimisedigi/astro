import SwiftUI

/// Smooths token-by-token streaming into an even character flow.
/// The model delivers text in lumpy bursts; this drains a queue at a steady rate so the
/// answer appears to type rather than jump. Reduce Motion skips the animation entirely.
@MainActor
final class CharacterQueue: ObservableObject {
    @Published private(set) var visible = "" { didSet { onVisible?(visible) } }

    /// Fires with the full visible text each time it grows, so a view model can mirror it.
    var onVisible: ((String) -> Void)?

    private var pending = ""
    private var timer: Timer?
    /// Characters per tick, scaled up when the model is far ahead so we never fall behind.
    private let tickInterval = 0.016

    var isDraining: Bool { !pending.isEmpty }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            visible += delta
            return
        }
        pending += delta
        startIfNeeded()
    }

    /// Show everything immediately — used when the turn ends or the view goes away.
    func finish() {
        visible += pending
        pending = ""
        stop()
    }

    func reset(to text: String = "") {
        stop()
        pending = ""
        visible = text
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
    }

    private func drain() {
        guard !pending.isEmpty else { return stop() }
        // Keep the backlog bounded: the further behind we are, the more we emit per tick.
        let batch = max(1, pending.count / 12)
        visible += pending.prefix(batch)
        pending.removeFirst(min(batch, pending.count))
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

/// Renders one assistant message as markdown blocks.
struct ResponseTextView: View {
    let text: String
    var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
            if isStreaming {
                CaretView()
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A blinking caret so a slow first token never looks like a hang.
struct CaretView: View {
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.secondary)
            .frame(width: 2, height: 14)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = false }
            }
            .accessibilityHidden(true)
    }
}

struct MarkdownBlockView: View {
    let block: Markdown.Block

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text)
        case .heading(let level, let text):
            Text(text).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
        case .bullet(let items):
            listRows(items.map { (marker: Text("•"), text: $0) })
        case .numbered(let items):
            listRows(items.enumerated().map { (marker: Text("\($0.offset + 1)."), text: $0.element) })
        case .checklist(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
                        Text(item.text)
                            .strikethrough(item.done, color: .secondary)
                            .foregroundStyle(item.done ? .secondary : .primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.done ? "Done" : "Not done"): \(String(item.text.characters))")
                }
            }
        case .quote(let text):
            Text(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 2)
                }
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)
        case .rule:
            Divider()
        }
    }

    private func listRows(_ rows: [(marker: Text, text: AttributedString)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    row.marker.foregroundStyle(.secondary).monospacedDigit()
                    Text(row.text)
                }
            }
        }
    }
}

struct MarkdownTableView: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(cell).font(.caption.bold())
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(.caption)
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
