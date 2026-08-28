import AppKit
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

            KnowledgeSettingsCard()
        }
    }
}

struct ProviderCard: View {
    let provider: AIProvider
    @ObservedObject var registry: ModelRegistry
    @ObservedObject var login: LoginModel
    @State private var apiKey = ""
    @State private var apiKeySaved = false
    @State private var isConnecting = false
    @State private var connectError: String?

    private var connected: Bool { ProviderStore.isConnected(provider) }

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

            controls
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var controls: some View {
        if connected {
            HStack {
                Text("Connected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Disconnect") { ProviderStore.disconnect(provider) }
            }
        } else if provider == .anthropic {
            anthropicControls
        } else if provider == .kimi {
            kimiControls
        } else if provider == .openai || provider == .gemini {
            oauthControls
        } else {
            apiKeyControls
        }
    }

    @ViewBuilder
    private var anthropicControls: some View {
        switch login.phase {
        case .signedIn:
            EmptyView() // handled by the connected branch above
        case .awaitingCode, .exchanging, .failed:
            LoginCodeEntry(model: login)
        case .idle:
            Button("Sign in with Claude", action: login.startLogin)
        }
    }

    @ViewBuilder
    private var kimiControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isConnecting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(connectError ?? "Waiting for browser approval…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Sign in with Kimi") {
                    isConnecting = true
                    connectError = nil
                    Task {
                        do {
                            let auth = try await KimiOAuth.beginLogin()
                            connectError = "Code: \(auth.userCode)"
                            NSWorkspace.shared.open(auth.verificationURI)
                            try await KimiOAuth.completeLogin(auth)
                            connectError = nil
                        } catch {
                            connectError = error.localizedDescription
                        }
                        isConnecting = false
                    }
                }
            }
            if let connectError, !isConnecting {
                ErrorTextBlock(message: connectError)
            }
        }
    }

    @ViewBuilder
    private var oauthControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isConnecting {
                HStack(spacing: 6) {
                    Text("Waiting for browser sign-in…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Sign in with \(provider.displayName)") {
                    isConnecting = true
                    connectError = nil
                    Task {
                        do {
                            switch provider {
                            case .openai: try await OpenAIOAuth.authenticate()
                            case .gemini: try await GeminiOAuth.authenticate()
                            default: break
                            }
                        } catch {
                            connectError = error.localizedDescription
                        }
                        isConnecting = false
                    }
                }
            }
            if let connectError {
                ErrorTextBlock(message: connectError)
            }
        }
    }

    @ViewBuilder
    private var apiKeyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste your \(provider.displayName) API key:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField("\(provider.displayName) API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                Button("Save", action: saveKey)
                    .disabled(apiKey.isEmpty)
            }
            if apiKeySaved {
                Text("Saved to Keychain").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveKey() {
        guard !apiKey.isEmpty else { return }
        ProviderStore.APIKeyStore.set(apiKey, for: provider)
        apiKey = ""
        apiKeySaved = true
    }
}
