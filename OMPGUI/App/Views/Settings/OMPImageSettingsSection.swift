import SwiftUI

/// Image preference belongs to OMP's native `image` role, including its fallback policy.
struct OMPImageSettingsSection: View {
    let refreshID: Int
    let loginInProgress: Bool
    let login: (OMPLoginProvider) -> Void
    let credentialsChanged: () -> Void
    @Environment(AppModel.self) private var model
    @State private var snapshot: OMPImageConfiguration?
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var error: String?
    @State private var editingKey = false

    private enum BackendChoice: Hashable { case automatic, unresolved, provider(String) }
    private struct ReadIdentity: Equatable {
        var context: OMPDiscoveryContext?
        var roles: JSONValue?
        var refreshID: Int
    }

    private var context: OMPDiscoveryContext? {
        guard let executable = model.providers.executable(for: .omp) else { return nil }
        return OMPDiscoveryContext(executable: executable,
                                   environment: OMPCLI.profileConfigurationEnvironment(model.providers.environment(for: .omp)))
    }
    private var current: OMPImageConfiguration? { snapshot?.context == context ? snapshot : nil }
    private var busy: Bool { loading || model.omp.isLoading || model.omp.isSaving }

    var body: some View {
        ChromeSection(title: "Image generation and editing") {
            ChromeCard {
                if model.omp.values["generate_image.enabled"]?.bool != nil {
                    ChromeRow(title: "Enable image generation and editing") {
                        SettingsSwitch(isOn: Binding(get: {
                            model.omp.values["generate_image.enabled"]?.bool ?? false
                        }, set: setEnabled))
                        .accessibilityLabel(Text("Enable image generation and editing"))
                        .disabled(busy)
                    }
                    ChromeRowDivider()
                }
                ChromeRow(title: "Preferred backend") {
                    if loading { ProgressView().controlSize(.small) }
                    Picker("Preferred backend", selection: Binding(get: {
                        if let backend = current?.backend { return BackendChoice.provider(backend.id) }
                        return current?.selector.isEmpty != false ? .automatic : .unresolved
                    }, set: { choice in
                        switch choice {
                        case .automatic: save("")
                        case .provider(let id):
                            if let backend = current?.backends.first(where: { $0.id == id }) { save(backend.preferredModel) }
                        case .unresolved: break
                        }
                    })) {
                        Text("Automatic").tag(BackendChoice.automatic)
                        if let current, !current.selector.isEmpty, current.selected == nil {
                            Text(verbatim: current.selector).tag(BackendChoice.unresolved)
                        }
                        ForEach(current?.backends ?? []) { backend in
                            Text(verbatim: NativeProviderPresentation.displayName(for: backend.id, nativeName: backend.name))
                                .tag(BackendChoice.provider(backend.id))
                        }
                    }.labelsHidden().frame(width: 240, alignment: .trailing).disabled(busy || current == nil)
                }
                if let current, let selected = current.selected, let backend = current.backend {
                    ChromeRowDivider()
                    ChromeRow(title: "Image model") {
                        Picker("Image model", selection: Binding(get: { selected.id }, set: save)) {
                            ForEach(current.models.filter { $0.provider == backend.id }) { image in
                                Text(verbatim: image.name).tag(image.id)
                            }
                        }.labelsHidden().frame(width: 280, alignment: .trailing).disabled(busy)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Credentials", detail: selected.hasCredentials || !selected.requiresCredentials ? nil : instructions(backend)) {
                        if selected.hasCredentials || !selected.requiresCredentials {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Chrome.success)
                                .help(Text(verbatim: Chrome.localized(selected.requiresCredentials ? "Credentials configured" : "No credentials required")))
                                .accessibilityLabel(Text(verbatim: Chrome.localized(selected.requiresCredentials ? "Credentials configured" : "No credentials required")))
                        } else {
                            if let provider = loginProvider(backend) {
                                Button("Login") { login(provider) }
                                    .buttonStyle(.glass).disabled(busy || loginInProgress)
                            }
                            if let provider = backend.keyProvider {
                                Button("Edit model configuration") { editingKey = true }.buttonStyle(.glass)
                                    .disabled(busy || loginInProgress)
                                    .chromePopover(isPresented: $editingKey, arrowEdge: .bottom) {
                                        OMPModelConfigurationPopover(registry: model.providers, initialProvider: provider,
                                                                     completed: credentialsChanged).presentedChrome()
                                    }
                            }
                        }
                    }
                } else if let current {
                    ChromeRowDivider()
                    ChromeRow(title: current.selector.isEmpty ? "Automatic image selection" : "Configured image model unavailable",
                              detail: current.selector.isEmpty
                                ? "OMP chooses an image model for each conversation. Select a backend to check its credentials."
                                : "The saved image selector is not in the installed image catalogue. Select a backend or use Automatic.") { EmptyView() }
                }
            }
            if let error { Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger).textSelection(.enabled) }
        }
        .task(id: ReadIdentity(context: context, roles: model.omp.values["modelRoles"], refreshID: refreshID)) { await load() }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !busy, let expected = model.omp.values["generate_image.enabled"], expected.bool != nil else { return }
        let originalContext = context
        let directory = model.omp.agentDirectory
        Task {
            guard originalContext == context, directory == model.omp.agentDirectory else {
                error = Chrome.localized("The OMP configuration changed on disk. Reload before saving.")
                return
            }
            await model.omp.set("generate_image.enabled", .bool(enabled), expected: expected)
            error = model.omp.error
        }
    }

    private func loginProvider(_ backend: OMPImageBackend) -> OMPLoginProvider? {
        model.omp.browserLoginProviders.first { $0.id == backend.loginProvider }
    }

    private func instructions(_ backend: OMPImageBackend) -> String {
        if loginProvider(backend) != nil, backend.keyProvider != nil {
            return Chrome.localized("Sign in to this provider or add its API key in Edit model configuration.")
        }
        if loginProvider(backend) != nil { return Chrome.localized("Sign in to this provider using its existing OMP login.") }
        if backend.keyProvider != nil { return Chrome.localized("Add this provider's API key in Edit model configuration.") }
        if !backend.environmentKeys.isEmpty {
            return String(format: Chrome.localized("Configure %@ in OMP's environment, then reload."), backend.environmentKeys.joined(separator: ", "))
        }
        return Chrome.localized("Configure this provider's credentials in OMP, then reload.")
    }

    @MainActor private func load() async {
        let request = UUID()
        requestID = request
        loading = true
        defer { if requestID == request { loading = false } }
        guard let context else { error = ProviderError.notInstalled(.omp).localizedDescription; snapshot = nil; return }
        do {
            let loaded = try await OMPImageConfiguration.read(context: context)
            try Task.checkCancellation()
            guard self.context == context, requestID == request else { return }
            snapshot = loaded
            error = nil
        } catch {
            guard !Task.isCancelled, self.context == context, requestID == request else { return }
            snapshot = nil
            self.error = error.localizedDescription
        }
    }

    private func save(_ selector: String) {
        guard !busy, let current, current.context == context,
              selector.isEmpty || current.models.contains(where: { $0.id == selector }) else { return }
        let expected = model.omp.values["modelRoles"] ?? [:]
        guard current.directory == model.omp.agentDirectory, (expected["image"]?.string ?? "") == current.selector else {
            error = Chrome.localized("The OMP configuration changed on disk. Reload before saving.")
            return
        }
        Task {
            guard current.context == context, current.directory == model.omp.agentDirectory else {
                error = Chrome.localized("The OMP configuration changed on disk. Reload before saving.")
                return
            }
            error = await model.omp.setSelectors("modelRoles", changes: ["image": selector], expected: expected)
        }
    }
}
