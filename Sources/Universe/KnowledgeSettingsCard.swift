import SwiftUI

/// Connects the `knowledge_search` tool to a running transcript library:
/// its base URL in UserDefaults, its bearer token in the Keychain.
struct KnowledgeSettingsCard: View {
    @State private var baseURL = UserDefaults.standard
        .string(forKey: KnowledgeSearchTool.baseURLDefaultsKey) ?? ""
    @State private var token = ""
    @State private var saved = false
    @State private var testing = false
    /// nil until tested — "saved" is not the same as "reachable".
    @State private var testResult: String?
    @State private var testPassed = false

    private var configured: Bool {
        KeychainHelper.get(account: KnowledgeSearchTool.tokenAccount) != nil && !baseURL.isEmpty
    }

    /// The token is a bearer credential: only ever send it to an http(s) origin.
    private var urlValid: Bool {
        guard let scheme = URL(string: baseURL)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        SettingsCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Knowledge Library").fontWeight(.semibold)
                    Text("Search your saved transcripts and documents when answering.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if testPassed {
                    StatusPill(text: "Connected", tone: .good)
                } else if configured {
                    StatusPill(text: "Saved", tone: .neutral)
                }
            }

            TextField("http://localhost:3000", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Library URL")
            HStack(spacing: 8) {
                SecureField("Search token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(token.isEmpty || !urlValid)
            }
            if !baseURL.isEmpty && !urlValid {
                ErrorTextBlock(message: "The library URL must start with http:// or https://.")
            } else if saved {
                Text("Saved — URL stored locally, token in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Matches LIBRARY_SEARCH_TOKEN in the library's environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if configured {
                HStack(spacing: 8) {
                    Button("Test Connection", action: test).disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Disconnect") {
                        KeychainHelper.remove(account: KnowledgeSearchTool.tokenAccount)
                        UserDefaults.standard.removeObject(forKey: KnowledgeSearchTool.baseURLDefaultsKey)
                        baseURL = ""
                        saved = false
                        testResult = nil
                        testPassed = false
                    }
                }
                if let testResult {
                    if testPassed {
                        Text(testResult).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ErrorTextBlock(message: testResult)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func save() {
        guard !token.isEmpty, urlValid else { return }
        UserDefaults.standard.set(
            baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: KnowledgeSearchTool.baseURLDefaultsKey
        )
        KeychainHelper.set(token, account: KnowledgeSearchTool.tokenAccount)
        token = ""
        saved = true
        testResult = nil
        testPassed = false
    }

    /// Runs the real tool rather than a parallel code path, so a passing test
    /// means the agent's own request would have worked too.
    private func test() {
        testing = true
        testResult = nil
        Task {
            let output: String
            do {
                output = try await KnowledgeSearchTool().run(
                    input: ["question": "test"],
                    workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                )
            } catch {
                output = "Error: \(error.localizedDescription)"
            }
            testPassed = !output.hasPrefix("Error:")
            testResult = testPassed ? "The library answered." : output
            testing = false
        }
    }
}
