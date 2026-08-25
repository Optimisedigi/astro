import SwiftUI

/// Placeholder shown between "sent" and the first token, so the panel is never dead.
struct SkeletonView: View {
    @State private var shift = false

    private let widths: [CGFloat] = [220, 260, 180]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                Capsule()
                    .fill(.quaternary)
                    .frame(width: width, height: 10)
                    .opacity(shift ? 0.45 : 1)
            }
        }
        .onAppear {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { shift = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Thinking")
    }
}

/// Errors are content, not alerts: they stay in the transcript with a way forward.
struct ErrorTextBlock: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}
