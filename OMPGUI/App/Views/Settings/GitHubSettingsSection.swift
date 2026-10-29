import SwiftUI

struct GitHubSettingsSection: View {
    private var connection: GitHubConnection { .shared }
    @State private var isCloning = false

    var body: some View {
        ChromeSection(title: "GitHub") {
            ChromeCard {
                if connection.isConnected {
                    HStack(spacing: 10) {
                        AsyncImage(url: connection.user?.avatarURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image("mcp-github").resizable().scaledToFit()
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: connection.user.map { $0.name ?? $0.login } ?? "GitHub")
                                .foregroundStyle(Chrome.primaryText)
                            if let detail = accountDetail {
                                Text(verbatim: detail).font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                            }
                        }
                        Spacer(minLength: 12)
                        Button("Disconnect") { connection.disconnect() }.buttonStyle(.glass)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, Chrome.rowControlTrailingPadding)
                    .padding(.vertical, 11)
                    ChromeRowDivider()
                    ChromeRow(title: "Clone a repository", detail: "Clone one of your repositories and start a thread in it.") {
                        Button("Clone…") { isCloning = true }.buttonStyle(.glass)
                            .chromePopover(isPresented: $isCloning, arrowEdge: .trailing) {
                                GitHubClonePanelView(onClose: { isCloning = false }, onCloned: nil)
                                    .presentedChrome()
                            }
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Clone into", detail: (connection.cloneDirectory.path as NSString).abbreviatingWithTildeInPath) {
                        Button("Change…") { GitHubClonePanel.chooseCloneDirectory() }.buttonStyle(.glass)
                    }
                } else if case .checking = connection.phase {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking GitHub connection…").foregroundStyle(Chrome.secondaryText)
                    }
                    .padding(16)
                } else {
                    ChromeRow(title: "Connect GitHub", detail: "Clone your repositories and let agents push and open pull requests.") {
                        EmptyView()
                    }
                    GitHubConnectView().padding(.horizontal, 16).padding(.bottom, 11)
                }
            }
        }
    }

    private var accountDetail: String? {
        guard let user = connection.user else { return nil }
        switch connection.source {
        case .githubCLI: return String(format: Chrome.localized("@%@, using the GitHub CLI login"), user.login)
        case .tivano: return String(format: Chrome.localized("@%@, saved in your Keychain"), user.login)
        case nil: return "@\(user.login)"
        }
    }
}
