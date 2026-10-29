import SwiftUI

struct OMPNativePluginsSection: View {
    @Environment(AppModel.self) private var model
    @State private var native = OMPNativePlugins()
    @State private var projectID: UUID?
    @State private var installTarget = ""
    @State private var installing = false
    @State private var removing: OMPNativePlugin?

    private var directory: URL? {
        model.projects.first { $0.id == projectID }.map { URL(fileURLWithPath: $0.path) }
    }

    var body: some View {
        ChromeSection(title: "Native plugins") {
            ChromeCard {
                ChromeRow(title: "Plugin scope", detail: "The native plugin registry is separate from the chat command catalog.") {
                    OMPPluginScopePicker(projects: model.projects, selection: $projectID)
                }
                ChromeRowDivider()
                ChromeRow(title: "Installed plugins", detail: directory?.path ?? model.omp.agentDirectory.path) {
                    Button("Reload") { Task { await native.refresh(registry: model.providers, directory: directory) } }.buttonStyle(.glass)
                    Button("Run diagnostics") { Task { await native.diagnose(registry: model.providers, directory: directory) } }.buttonStyle(.glass)
                    Button("Install") { installing = true }.buttonStyle(.glass)
                }
                if native.hasLoaded && native.plugins.isEmpty {
                    ChromeRowDivider()
                    ChromeRow(title: "No native plugins installed") { EmptyView() }
                }
                ForEach(native.plugins) { plugin in
                    ChromeRowDivider()
                    ChromeRow(title: plugin.name, detail: [plugin.version, plugin.scope, plugin.detail].compactMap { $0 }.joined(separator: " · ")) {
                        if let enabled = plugin.enabled { Text(verbatim: Chrome.localized(enabled ? "Enabled" : "Disabled")).font(.ui(.caption)) }
                        Button("Uninstall") { removing = plugin }.buttonStyle(.glass)
                    }
                }
                ForEach(native.diagnostics) { diagnostic in
                    ChromeRowDivider()
                    ChromeRow(title: diagnostic.status, detail: diagnostic.message) { EmptyView() }
                }
            }
            .disabled(native.isBusy)
            if native.isBusy { ProgressView().controlSize(.small) }
            if let error = native.error { Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger) }
        }
        .task(id: projectID) { await native.refresh(registry: model.providers, directory: directory) }
        .sheet(isPresented: $installing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Install native plugin").font(.ui(.title2, weight: .semibold))
                Text("Enter an npm package, local path, or native marketplace identifier.").font(.ui(.subheadline))
                Text("Project scope applies to marketplace plugins. OMP stores npm packages and local links in its user plugin directory.")
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                TextField("Plugin package or path", text: $installTarget).textFieldStyle(.chromeGlass)
                Text(verbatim: directory?.path ?? model.omp.agentDirectory.path).font(.ui(.caption, design: .monospaced))
                if let error = native.error { Text(verbatim: error).foregroundStyle(Chrome.danger) }
                HStack {
                    Spacer()
                    Button("Cancel") { installing = false }.buttonStyle(.glass).disabled(native.isBusy)
                    Button("Install") {
                        Task {
                            if await native.change("install", target: installTarget.trimmed, scope: projectID == nil ? "user" : "project", registry: model.providers, directory: directory) {
                                installing = false
                                installTarget = ""
                                await native.refresh(registry: model.providers, directory: directory)
                            }
                        }
                    }.buttonStyle(.glass).disabled(native.isBusy || installTarget.trimmed.isEmpty)
                }
            }.padding(24).frame(width: 540)
            .interactiveDismissDisabled(native.isBusy)
            .presentedChrome()
        }
        .confirmationDialog("Uninstall native plugin?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { plugin in
            Button("Uninstall", role: .destructive) {
                Task {
                    if await native.change("uninstall", target: plugin.name, scope: plugin.scope == "project" ? "project" : "user", registry: model.providers, directory: directory) {
                        await native.refresh(registry: model.providers, directory: directory)
                    }
                }
            }
        } message: { plugin in Text(verbatim: plugin.name) }
    }
}

/// Keep scope choices on the shared popover path: a nested native Menu/Picker
/// hangs while opening here. Opening this button only changes presentation state.
struct OMPPluginScopePicker: View {
    let projects: [Project]
    @Binding var selection: UUID?
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var isPresented = false

    var body: some View {
        Group {
            if performanceMode {
                button.buttonStyle(.bordered)
            } else {
                button.buttonStyle(.glass)
            }
        }
        .accessibilityLabel(Text("Plugin scope"))
        .chromePopover(isPresented: $isPresented, arrowEdge: .bottom) { choices }
        .frame(maxWidth: 220, alignment: .trailing)
    }

    private var button: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: projects.first { $0.id == selection }?.name ?? Chrome.localized("Active profile"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(Chrome.chevronFont)
            }
        }
    }

    var choices: some View {
        PopoverMenu {
            PopoverItem("Active profile", isChecked: selection == nil) { selection = nil }
            ForEach(projects) { project in
                PopoverItem(project.name, text: Text(verbatim: project.name), isChecked: selection == project.id) {
                    selection = project.id
                }
                .accessibilityLabel(Text(verbatim: project.name))
            }
        }
    }
}
