import AppKit
import SwiftUI

struct GitHubConnectView: View {
    private var connection: GitHubConnection { .shared }
    @State private var showsToken = false
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch connection.phase {
            case .awaitingBrowser(let code):
                Text("Enter this code on GitHub")
                Text(verbatim: code.userCode)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Copy code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                    }
                    .buttonStyle(.glass)
                    Button("Open GitHub") { NSWorkspace.shared.open(code.verificationURI) }
                        .buttonStyle(.glass)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for GitHub…").foregroundStyle(Chrome.secondaryText)
                    Spacer()
                    Button("Cancel") { connection.cancelSignIn() }.buttonStyle(.glass)
                }
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                }
            default:
                if connection.canSignInWithBrowser {
                    Button("Sign in with GitHub") { connection.signInWithBrowser() }
                        .buttonStyle(.glassProminent)
                }
                if connection.cliIsSignedIn {
                    Button("Use GitHub CLI login") {
                        Task { await connection.useGitHubCLI() }
                    }
                    .buttonStyle(.glass)
                }
                Button("Use a token…") { showsToken.toggle() }.buttonStyle(.glass)
                if showsToken {
                    HStack(spacing: 8) {
                        SecureField("Personal access token", text: $token)
                            .textFieldStyle(.plain)
                            .focusEffectDisabled()
                            .padding(8)
                            .background(Chrome.overlay(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button("Connect") {
                            let value = token
                            Task {
                                await connection.connect(token: value)
                                token = ""
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button("Create a token on GitHub") {
                        if let url = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org,workflow&description=Tivano") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Chrome.accent)
                }
            }
            if let error = connection.errorMessage {
                Text(verbatim: error).font(.ui(.caption)).foregroundStyle(Chrome.danger)
            }
        }
        .font(.ui(.callout))
        .task { await connection.refreshCLIStatus() }
    }
}
