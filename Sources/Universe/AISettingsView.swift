import SwiftUI

/// The AI Settings sheet: which model answers, and which accounts are connected.
struct AISettingsView: View {
    @ObservedObject var registry: ModelRegistry
    @ObservedObject var login: LoginModel
    var onDone: () -> Void = {}

    var body: some View {
        SettingsSheet(title: "AI Settings") {
            AISettingsBody(registry: registry, login: login)
        } footer: {
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct AISettingsBody: View {
    @ObservedObject var registry: ModelRegistry
    @ObservedObject var login: LoginModel

    var body: some View {
        SettingsSheetBody {
            VStack(spacing: 4) {
                Text("Active Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Active Model", selection: $registry.selectedModelID) {
                    ForEach(ModelRegistry.selectableModels) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Active model")
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)

            ForEach(AIProvider.allCases) { provider in
                ProviderCard(provider: provider, registry: registry, login: login)
            }
        }
    }
}

struct ProviderCard: View {
    let provider: AIProvider
    @ObservedObject var registry: ModelRegistry
    @ObservedObject var login: LoginModel

    private var connected: Bool { registry.isConnected(provider) }

    var body: some View {
        SettingsCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).fontWeight(.semibold)
                    Text(provider.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if connected { StatusPill(text: "Connected", tone: .good) }
            }

            if provider.isImplemented {
                anthropicControls
            } else {
                // Say plainly that it is not built yet rather than showing a dead button.
                Text("Sign-in for \(provider.displayName) isn't built yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var anthropicControls: some View {
        switch login.phase {
        case .signedIn:
            HStack {
                Text("Signed in").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Sign Out", action: login.signOut)
            }
        case .awaitingCode, .exchanging, .failed:
            LoginCodeEntry(model: login)
        case .idle:
            Button("Sign in with Claude", action: login.startLogin)
        }
    }
}
