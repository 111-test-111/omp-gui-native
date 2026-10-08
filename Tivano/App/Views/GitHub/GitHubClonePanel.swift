import AppKit
import SwiftUI

@MainActor
final class GitHubClonePanel: FloatingGuidePanel {
    static let shared = GitHubClonePanel()

    private init() { super.init(width: 460) }

    func present(model: AppModel, onCloned: (@MainActor (Project) -> Void)? = nil) {
        let content = GitHubClonePanelView(onClose: { [weak self] in self?.close() }, onCloned: onCloned)
            .presentedChrome()
            .environment(model)
        present(content)
        // Typing goes straight into the search field.
        panel?.makeKey()
    }

    static func chooseCloneDirectory() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = Chrome.localized("Choose")
        picker.directoryURL = GitHubConnection.shared.cloneDirectory
        guard picker.runModal() == .OK, let url = picker.url else { return }
        GitHubConnection.shared.cloneDirectory = url
    }
}

struct GitHubClonePanelView: View {
    @Environment(AppModel.self) private var model
    let onClose: @MainActor () -> Void
    let onCloned: (@MainActor (Project) -> Void)?
    private var connection: GitHubConnection { .shared }
    @State private var search = ""
    @State private var selectedFullName: String?
    @State private var cloneError: String?
    @FocusState private var searchFocused: Bool

    private var repositories: [GitHubRepository] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return connection.repositories.filter {
            query.isEmpty || $0.fullName.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var pastedFullName: String? {
        guard let name = GitHubRepoReference.fullName(from: search),
              !connection.isConnected || !connection.repositories.contains(where: { $0.fullName.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                Image("mcp-github").resizable().scaledToFit().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clone from GitHub").font(.system(size: 14, weight: .semibold))
                    Text("Pick a repository. It is cloned into your folder and opens as a project.")
                        .font(.subheadline).foregroundStyle(Chrome.secondaryText)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").foregroundStyle(Chrome.secondaryText)
                }
                .buttonStyle(.plain)
            }
            TextField("Search your repositories or paste a URL", text: $search)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .padding(8)
                .background(Chrome.overlay(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($searchFocused)
            // The panel sizes itself once when it opens, so this region keeps one height
            // whether it shows the list, the sign-in steps or an error.
            VStack(alignment: .leading, spacing: 8) {
                if connection.isConnected {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if let name = pastedFullName { repositoryRow(fullName: name, title: String(format: Chrome.localized("Clone %@"), name)) }
                            if connection.isLoadingRepositories {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading your repositories…").foregroundStyle(Chrome.secondaryText)
                                }
                                .padding(8)
                            }
                            ForEach(repositories) { repo in
                                repositoryRow(fullName: repo.fullName, title: repo.fullName, repository: repo)
                            }
                            if repositories.isEmpty && pastedFullName == nil && !connection.isLoadingRepositories {
                                Text("No repositories match.").foregroundStyle(Chrome.secondaryText).padding(8)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    GitHubConnectView()
                    Text("You can also paste a public repository URL above.")
                        .font(.subheadline).foregroundStyle(Chrome.secondaryText)
                    if let name = pastedFullName { repositoryRow(fullName: name, title: String(format: Chrome.localized("Clone %@"), name)) }
                    Spacer(minLength: 0)
                }
                if let cloneError {
                    Text(verbatim: cloneError).font(.caption).foregroundStyle(Chrome.danger).lineLimit(3)
                }
            }
            .frame(height: 320, alignment: .topLeading)
            footer
        }
        .font(.callout)
        .padding(18)
        .frame(width: 460)
        .background { WindowDragArea() }
        .background { WindowBackdrop(opacity: 0.5) }
        .clipShape(RoundedRectangle(cornerRadius: Chrome.windowCornerRadius, style: .continuous))
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onClose)
        .task { await connection.loadRepositories() }
        .onChange(of: connection.isConnected) { _, connected in
            if connected { Task { await connection.loadRepositories() } }
        }
        // Return clones the pasted repository, or the top match of a search.
        .onChange(of: search) { _, new in
            selectedFullName = pastedFullName ?? (new.trimmed.isEmpty ? nil : repositories.first?.fullName)
        }
    }

    private func repositoryRow(fullName: String, title: String, repository: GitHubRepository? = nil) -> some View {
        HStack(spacing: 8) {
            if repository?.isPrivate == true {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(Chrome.secondaryText)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).lineLimit(1)
                if let description = repository?.description, !description.isEmpty {
                    Text(verbatim: description).font(.subheadline).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let date = repository?.pushedAt {
                Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.caption).foregroundStyle(Chrome.secondaryText)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedFullName == fullName ? Chrome.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selectedFullName = fullName; clone(fullName) }
        .onTapGesture { selectedFullName = fullName }
        .accessibilityAddTraits(selectedFullName == fullName ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectedFullName = fullName }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clone into").font(.subheadline)
                Text(verbatim: (connection.cloneDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(Chrome.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Button("Change…") { GitHubClonePanel.chooseCloneDirectory() }.buttonStyle(.glass)
            Spacer(minLength: 0)
            Button {
                if let selectedFullName { clone(selectedFullName) }
            } label: {
                HStack(spacing: 6) {
                    if connection.cloningFullName != nil { ProgressView().controlSize(.small) }
                    Text(verbatim: Chrome.localized(connection.cloningFullName == nil ? "Clone" : "Cloning…"))
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedFullName == nil || connection.cloningFullName != nil)
        }
    }

    private func clone(_ fullName: String) {
        guard connection.cloningFullName == nil else { return }
        cloneError = nil
        Task {
            do {
                let project = try await connection.clone(fullName, model: model)
                onClose()
                if let onCloned { onCloned(project) } else { model.newThread(in: project) }
            } catch {
                cloneError = error.localizedDescription
            }
        }
    }
}
