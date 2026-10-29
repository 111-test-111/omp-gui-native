import AppKit
import SwiftUI

/// The existing settings chrome around OMP's public configuration and auth surfaces.
struct OMPSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var binary = ""
    @State private var editingRoles: OMPConfigurationFormSnapshot?
    @State private var loginProvider: OMPLoginProvider?
    @State private var loginFlow: OMPNativeLogin?
    @State private var editingAPIKeys = false
    @State private var editingConfiguredProvider: String?
    @State private var credentialsRevision = 0
    @State private var usageConsumer = UUID()
    @Environment(\.scenePhase) private var scenePhase

    private struct UsageReadIdentity: Equatable {
        let context: OMPDiscoveryContext?
        let revision: UInt64
        let credentialsRevision: Int
    }

    private var usage: OMPProviderUsageStore { model.providers.subscriptionUsage }
    private var usageContext: OMPDiscoveryContext? {
        guard let executable = model.providers.executable(for: .omp) else { return nil }
        return OMPDiscoveryContext(executable: executable, environment: model.providers.environment(for: .omp))
    }

    private var authenticationBusy: Bool {
        loginFlow?.isRunning == true || model.omp.signingOutProviderID != nil
    }

    var body: some View {
        let native = model.omp
        ChromeSection(title: "OMP runtime") {
            ChromeCard {
                ChromeRow(title: "Oh My Pi", detail: model.providers.status(.omp).summary) {
                    Link("Install OMP", destination: ProviderKind.omp.installURL).buttonStyle(.glass)
                }
                ChromeRowDivider()
                ChromeRow(title: "Binary path", detail: "Leave blank to find omp on your login PATH.") {
                    TextField("Automatic", text: $binary)
                        .textFieldStyle(.chromeGlass)
                        .font(.ui(.subheadline, design: .monospaced))
                        .frame(width: 220)
                        .onSubmit {
                            model.settings.setBinaryPath(binary, for: .omp)
                            Task { await model.providers.refreshEverything(); await native.refresh(force: true) }
                        }
                }
                ChromeRowDivider()
                ChromeRow(title: "OMP configuration", detail: native.agentDirectory.path) {
                    Button("Open folder") { NSWorkspace.shared.open(native.agentDirectory) }.buttonStyle(.glass)
                }
            }
        }
        ChromeSection(title: "Configured providers") {
            configuredProviders
            if let error = native.signOutError {
                Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger)
            } else if let source = native.remainingAuthenticationSource {
                Text(verbatim: String(format: Chrome.localized("Stored credentials removed. OMP still has credentials from %@."), source))
                    .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            }
        }
        ChromeSection(title: "All providers") {
            ChromeCard {
                ChromeRow(title: "Provider and custom model configuration", detail: "OMP reads models.yml, OAuth accounts and API keys from its own configuration.") {
                    Button("Edit model configuration") { editingAPIKeys = true }
                        .buttonStyle(.glass)
                        .disabled(authenticationBusy)
                        .chromePopover(isPresented: $editingAPIKeys, arrowEdge: .bottom) {
                            OMPModelConfigurationPopover(registry: model.providers, completed: refreshCredentials).presentedChrome()
                        }
                }
                if native.browserLoginProviders.isEmpty, !native.isLoading {
                    ChromeRowDivider()
                    ChromeRow(title: "Continue in OMP terminal", detail: "Browser sign-in is unavailable. Manage API keys here, or use OMP's terminal for other authentication methods.") {
                        Button("Continue in OMP terminal") { openTerminalLogin() }.buttonStyle(.glass)
                    }
                }
                ForEach(native.browserLoginProviders.filter { !$0.authenticated }) { provider in
                    ChromeRowDivider()
                    let name = NativeProviderPresentation.displayName(for: provider.id, nativeName: provider.name)
                    ChromeRow(title: name, detail: "Not signed in", leading: AnyView(NativeProviderIcon(providerID: provider.id, name: name))) {
                        loginButton(provider, title: "Login")
                    }
                }
                if let provider = loginProvider, let flow = loginFlow, !flow.completed {
                    ChromeRowDivider()
                    OMPLoginControls(provider: provider, flow: flow,
                        useTerminal: { cancelLogin(); openTerminalLogin(provider.id) }, cancel: cancelLogin)
                        .id(ObjectIdentifier(flow))
                }
            }
        }
        OMPImageSettingsSection(refreshID: credentialsRevision,
                                loginInProgress: authenticationBusy,
                                login: openLogin, credentialsChanged: refreshCredentials)
        ChromeSection(title: "Native model roles") {
            ChromeCard {
                ChromeRow(title: "Default, smol, slow, plan and tiny", detail: "Role assignments are saved by OMP in config.yml and shared with its CLI.") {
                    Button("Edit roles") { editingRoles = OMPConfigurationFormSnapshot(value: native.values["modelRoles"] ?? [:], directory: native.agentDirectory) }.buttonStyle(.glass)
                }
                ChromeRowDivider()
                ChromeRow(title: "Active profile", detail: native.agentDirectory.path) {
                    Button("Reload") { Task { await native.refresh(force: true) } }.buttonStyle(.glass)
                }
                ForEach(["default", "smol", "slow", "vision", "plan", "commit", "tiny", "memory", "task", "advisor"], id: \.self) { role in
                    if let value = native.values["modelRoles"]?[role]?.string {
                        ChromeRowDivider()
                        ChromeRow(title: role) { Text(verbatim: value).font(.ui(.subheadline, design: .monospaced)).textSelection(.enabled) }
                    }
                }
            }
        }
        OMPNativePluginsSection()
        OMPSystemPromptEditor(url: OMPSystemPrompt.fileURL(in: OMPCLI.appendPromptDirectory(environment: model.providers.environment(for: .omp))))
        if let error = native.error ?? model.providers.catalogErrors[.omp] {
            ChromeSection(title: "OMP configuration could not be loaded") {
                ChromeCard { ChromeRow(title: "OMP", detail: error) { Button("Retry") { Task { await native.refresh(force: true); await model.providers.refreshEverything() } }.buttonStyle(.glass) } }
            }
        }
        Text("OMP owns authentication, tools, extensions, skills and MCP connections.")
            .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
        .task { binary = model.settings.binaryPath(for: .omp); await native.refresh() }
        .task(id: UsageReadIdentity(context: usageContext, revision: model.providers.modelCatalogRevision,
                                   credentialsRevision: credentialsRevision)) { await usage.begin(usageConsumer) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await native.refresh(force: true); usage.invalidate(); credentialsRevision += 1 } }
        }
        .onDisappear { cancelLogin(); usage.end(usageConsumer) }
        .sheet(item: $editingRoles) { snapshot in
            OMPSelectorForm(title: "Native model roles",
                names: ["default", "smol", "slow", "vision", "plan", "commit", "tiny", "memory", "task", "advisor", "image", "web", "speech", "dictation", "judge"],
                original: snapshot.value, directory: snapshot.directory) { changes in
                    guard native.agentDirectory == snapshot.directory else { return Chrome.localized("The OMP configuration changed on disk. Reload before saving.") }
                    return await native.setSelectors("modelRoles", changes: changes, expected: snapshot.value)
                }
                .presentedChrome()
        }
    }

    private var configuredProviders: some View {
        TimelineView(.periodic(from: .now, by: 30)) { time in
            ChromeCard {
                let snapshot = usage.error == nil ? usage.snapshot : nil
                let reports = snapshot?.confirmedReports(now: time.date) ?? []
                let configured = ConfiguredProviderProjection.providers(logins: model.omp.loginProviders,
                    models: model.providers.models(for: .omp), reports: reports)
                if configured.isEmpty {
                    ChromeRow(title: "No providers configured yet", detail: "Sign in to a provider below. Manage API keys in Edit model configuration.") {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(configured.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 { ChromeRowDivider() }
                        ConfiguredProviderRow(provider: provider, reports: reports.filter { provider.nativeIDs.contains($0.provider) }) {
                            configuredActions(provider)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func configuredActions(_ provider: ConfiguredProviderProjection.Provider) -> some View {
        if let login = provider.login, login.supportsBrowserLogin {
            loginButton(login, title: login.authenticated ? "Sign in again" : "Login")
            if login.authenticated {
                Button("Sign out", role: .destructive) { signOut(login) }.buttonStyle(.glass)
                    .disabled(authenticationBusy || model.omp.isLoading || model.omp.isSaving)
            }
        } else {
            Button("Edit") { editingConfiguredProvider = provider.id }.buttonStyle(.glass)
                .help("Edit model configuration")
                .disabled(authenticationBusy || model.omp.isLoading || model.omp.isSaving)
                .chromePopover(isPresented: Binding(get: { editingConfiguredProvider == provider.id },
                                                   set: { if !$0 { editingConfiguredProvider = nil } }), arrowEdge: .bottom) {
                    OMPModelConfigurationPopover(registry: model.providers, initialProvider: provider.id,
                                                 completed: refreshCredentials).presentedChrome()
                }
        }
    }

    private func refreshCredentials() {
        Task {
            await model.omp.refresh(force: true)
            await model.providers.loadCatalog(.omp, force: true)
            credentialsRevision += 1
        }
    }

    private func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @ViewBuilder private func loginButton(_ provider: OMPLoginProvider, title: String) -> some View {
        if loginProvider?.id == provider.id, loginFlow?.isRunning == true {
            Button("Cancel", action: cancelLogin).buttonStyle(.glass)
        } else {
            Button(Chrome.localized(title)) { openLogin(provider) }.buttonStyle(.glass)
                .disabled(authenticationBusy)
        }
    }

    private func openLogin(_ provider: OMPLoginProvider) {
        guard provider.supportsBrowserLogin, !authenticationBusy else { return }
        let flow = OMPNativeLogin(openURL: { NSWorkspace.shared.open($0) })
        loginProvider = provider
        loginFlow = flow
        Task {
            guard loginFlow === flow else { return }
            await flow.start(provider: provider, registry: model.providers)
            if loginFlow === flow, flow.completed { refreshCredentials() }
        }
    }

    private func signOut(_ provider: OMPLoginProvider) {
        guard !authenticationBusy else { return }
        cancelLogin()
        Task {
            await model.omp.signOut(providerID: provider.id)
            credentialsRevision += 1
        }
    }

    private func cancelLogin() {
        loginFlow?.stop()
        loginFlow = nil
        loginProvider = nil
    }

    private func openTerminalLogin(_ provider: String? = nil) {
        guard let executable = model.providers.executable(for: .omp) else { return }
        let environment = model.providers.environment(for: .omp)
        let inherited = ["OMP_PROFILE", "PI_PROFILE", "PI_CONFIG_DIR", "PI_CODING_AGENT_DIR", "PI_CONFIG_FILES"].compactMap { key in
            environment[key].map { shellQuoted(key + "=" + $0) }
        }
        let command = (["env"] + inherited + [shellQuoted(executable.path), "login"] + (provider.map { [shellQuoted($0)] } ?? [])).joined(separator: " ")
        Workspace.openTerminal(running: command)
    }
}

private struct OMPSystemPromptEditor: View {
    let url: URL
    @State private var file: OMPSystemPrompt.File?
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        ChromeSection(title: "Custom prompt") {
            ChromeCard {
                ChromeRow(title: "OMP prompt file", detail: url.path) {
                    Button("Reload") { load() }.buttonStyle(.glass)
                    Button("Save") {
                        guard let file else { return }
                        do {
                            self.file = try OMPSystemPrompt.save(text, file: file)
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.glass)
                    .disabled(file == nil || file?.url != url || text == file?.text)
                }
                ChromeRowDivider()
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.ui(.body))
                        .scrollContentBackground(.hidden)
                        .disabled(file == nil)
                        .accessibilityLabel(Text("Custom prompt"))
                    if text.isEmpty {
                        Text("For example: reply in Simplified Chinese and explain verification results.")
                            .font(.ui(.body))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(8)
                .frame(height: 160)
                .chromeGlassInputSurface()
                .padding(12)
            }
            if let error {
                Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger)
            }
        }
        .task(id: url) { load() }
    }

    private func load() {
        do {
            let loaded = try OMPSystemPrompt.read(url)
            file = loaded
            text = loaded.text
            error = nil
        } catch {
            file = nil
            self.error = error.localizedDescription
        }
    }
}

struct OMPRecordEditor: View {
    let title: String
    let value: JSONValue
    let save: (JSONValue) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ChromeSection(title: title) {
                ChromeCard {
                    TextEditor(text: $text)
                        .font(.ui(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 240)
                        .chromeGlassInputSurface()
                        .padding(Chrome.rowHorizontalPadding)
                }
            }
            if let error { Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass)
                Button("Save") {
                    guard let value = JSONValue.parse(text), value.object != nil else {
                        error = Chrome.localized("Enter a valid JSON object."); return
                    }
                    saving = true
                    Task { error = await save(value); saving = false; if error == nil { dismiss() } }
                }.buttonStyle(.glass).disabled(saving)
            }
        }
        .padding(Chrome.contentHorizontalPadding)
        .frame(width: 580)
        .background { WindowBackdrop(opacity: AppSettings.defaultBackdropOpacity) }
        .onAppear { text = value.prettyString }
    }
}
