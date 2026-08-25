import AppKit
import SwiftUI

/// Drives the paste-code sign-in. The browser handles the authorization; the user
/// brings back a `code#state` string that we exchange for tokens.
@MainActor
final class LoginModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case awaitingCode
        case exchanging
        case signedIn
        case failed(String)
    }

    @Published private(set) var phase: Phase = AnthropicOAuth.isSignedIn ? .signedIn : .idle
    @Published var pastedCode = ""

    private var pending: AnthropicOAuth.PendingLogin?

    /// Lets `--render-states` gate every phase without a live sign-in.
    var previewPhase: Phase {
        get { phase }
        set { phase = newValue }
    }

    var authorizeURL: URL? { pending?.url }

    func startLogin() {
        let login = AnthropicOAuth.beginLogin()
        pending = login
        pastedCode = ""
        phase = .awaitingCode
        NSWorkspace.shared.open(login.url)
    }

    func openAuthorizePageAgain() {
        guard let url = pending?.url else { return }
        NSWorkspace.shared.open(url)
    }

    func submitCode() {
        guard let pending else {
            phase = .failed(AnthropicOAuth.OAuthError.noPendingLogin.localizedDescription)
            return
        }
        let code = pastedCode
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        phase = .exchanging

        Task {
            do {
                try await AnthropicOAuth.completeLogin(pastedCode: code, pending: pending)
                self.pending = nil
                pastedCode = "" // the code is single-use; don't leave it in the field
                phase = .signedIn
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func signOut() {
        AnthropicOAuth.signOut()
        pending = nil
        pastedCode = ""
        phase = .idle
    }
}

struct LoginView: View {
    @ObservedObject var model: LoginModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch model.phase {
            case .idle:
                Button("Sign in with Claude", action: model.startLogin)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("Opens claude.ai in your browser. Your Claude subscription is used — no API key needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .awaitingCode, .exchanging, .failed:
                codeEntry

            case .signedIn:
                signedInState
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase == .signedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.title2)
                .foregroundStyle(model.phase == .signedIn ? Color.accentColor : .secondary)
            Text(model.phase == .signedIn ? "Signed in to Claude" : "Sign in to Claude")
                .font(.headline)
        }
        .accessibilityElement(children: .combine)
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("After you authorize, Claude shows a code. Paste it here.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("code#state", text: $model.pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.submitCode)
                    .accessibilityLabel("Sign-in code")
                Button("Connect", action: model.submitCode)
                    .disabled(model.pastedCode.isEmpty || model.phase == .exchanging)
            }

            if model.phase == .exchanging {
                HStack(spacing: 6) {
                    Text("Exchanging code…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if case .failed(let message) = model.phase {
                ErrorTextBlock(message: message, retry: model.startLogin)
            }

            Button("Open the sign-in page again", action: model.openAuthorizePageAgain)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var signedInState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Universe is using your Claude subscription.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Sign out", action: model.signOut)
        }
    }
}
