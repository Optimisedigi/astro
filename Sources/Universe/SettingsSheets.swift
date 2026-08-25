import SwiftUI

/// Shared chrome for the three settings sheets: title, scrollable body, Done bar.
struct SettingsSheet<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

            Divider()

            ScrollView { SettingsSheetBody { content() } }

            Divider()

            HStack { footer() }
                .padding(12)
        }
        .frame(width: 420, height: 560)
        .background(.regularMaterial)
    }
}

/// The sheet's rows without the scroll container, so `--render-states` can gate them.
struct SettingsSheetBody<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A pill that states a status in words, not just colour (colour alone fails WCAG 1.4.1).
struct StatusPill: View {
    enum Tone { case good, bad, neutral }

    let text: String
    var tone: Tone = .neutral

    private var colour: Color {
        switch tone {
        case .good: return .green
        case .bad: return .orange
        case .neutral: return .secondary
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(colour.opacity(0.15), in: Capsule())
    }
}

/// A bordered card, the repeating unit in AI Settings.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
    }
}

/// The three sheets the top bar can open.
enum SettingsSheetKind: String, Identifiable {
    case ai, voice, permissions, onboarding
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .ai: return "sparkles"
        case .voice: return "waveform"
        case .permissions: return "lock.shield"
        case .onboarding: return "hand.raised"
        }
    }

    var label: String {
        switch self {
        case .ai: return "AI settings"
        case .voice: return "Voice settings"
        case .permissions: return "Permissions"
        case .onboarding: return "Onboarding"
        }
    }
}
