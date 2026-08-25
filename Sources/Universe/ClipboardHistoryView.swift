import AppKit
import SwiftUI

/// Searchable clipboard history — click a row to copy it back, hover for Delete.
/// Mirrors tama-agent's ClipboardHistoryView interactions ("Copied" overlay included).
struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardStore
    var onBack: () -> Void

    @State private var query = ""

    private var filtered: [ClipboardEntry] { store.search(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text("Clipboard History")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search clipboard...", text: $query)
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
                        ForEach(filtered) { entry in
                            ClipboardRow(entry: entry) {
                                copyEntry(entry)
                            } onDelete: {
                                store.delete(entry)
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
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.headline)
            Text(query.isEmpty
                 ? "Anything you copy will show up here."
                 : "Try a different search term.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func copyEntry(_ entry: ClipboardEntry) {
        // Don't re-capture our own paste-back.
        ClipboardMonitor.shared.skipNextChange = true
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry.contentType {
        case .text, .fileURL:
            if let text = entry.copyableText { pb.setString(text, forType: .string) }
        case .image:
            if let data = entry.imageData, let image = NSImage(data: data) {
                pb.writeObjects([image])
            }
        }
        ButtonSound.shared.play()
    }
}

struct ClipboardRow: View {
    let entry: ClipboardEntry
    var onCopy: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        Button(action: {
            onCopy()
            // "Copied" overlay feedback, then fade back (matches tama-agent).
            withAnimation(.easeIn(duration: 0.1)) { showCopied = true }
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                withAnimation(.easeOut(duration: 0.2)) { showCopied = false }
            }
        }) {
            HStack(spacing: 10) {
                Group {
                    if entry.contentType == .image, let data = entry.imageData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.preview)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let app = entry.sourceAppName {
                            Text(app)
                        }
                        Text(entry.timestamp, style: .relative)
                    }
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
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if showCopied {
                    Text("Copied")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var symbol: String {
        switch entry.contentType {
        case .text: return "doc.text"
        case .image: return "photo"
        case .fileURL: return "doc"
        }
    }
}
