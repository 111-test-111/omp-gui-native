import AppKit
import SwiftUI

private enum MCPEditingTarget: Equatable {
    case installation
    case server(String)
    case catalog(String)
}

private struct MCPEditingSession: Identifiable {
    let id = UUID()
    let snapshot: OMPMCPSnapshot
    let server: OMPMCPServer?
    var entry: MCPCatalogEntry? = nil

    var target: MCPEditingTarget {
        if let entry { return .catalog(entry.id) }
        return server.map { .server($0.id) } ?? .installation
    }
}

struct MCPSettingsPage: View {
    let query: String
    @Environment(AppModel.self) private var model
    private var configuration: MCPSettingsState { model.mcpSettings }
    @State private var editing: MCPEditingSession?
    @State private var removal: OMPMCPServer?
    @State private var login: MCPLoginSession?
    private var snapshot: OMPMCPSnapshot? { configuration.snapshot }
    private var document: JSONValue? { configuration.document }
    private var error: String? { configuration.error }
    private var busy: Bool { configuration.busy }

    private var context: OMPDiscoveryContext? { OMPMCPConfiguration.context(registry: model.providers) }
    private var servers: [OMPMCPServer] {
        OMPMCPDocument.servers(in: document ?? [:]).filter {
            query.trimmed.isEmpty || $0.id.localizedCaseInsensitiveContains(query.trimmed) ||
            $0.detail.localizedCaseInsensitiveContains(query.trimmed)
                || MCPCatalog.entry(matching: $0.id).map { OMPMCPQuickConnect.matches($0, query: query) } == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
        ChromeSection(title: "Active profile MCP servers") {
            HStack(spacing: 12) {
                if let url = configuration.fileURL {
                    Text(verbatim: url.path).font(.ui(.body)).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(Text(verbatim: url.path))
                }
                Spacer(minLength: 0)
                headerActions.fixedSize(horizontal: true, vertical: false)
            }
            ChromeCard(lazy: true) {
                if let error {
                    Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger)
                        .textSelection(.enabled).padding(16)
                }
                if document != nil {
                    if servers.isEmpty {
                        Text(verbatim: Chrome.localized(query.trimmed.isEmpty ? "No MCP servers are configured in this profile." : "No matching MCP servers."))
                            .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 180)
                            .padding(.horizontal, 16)
                    } else {
                        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { ChromeRowDivider() }
                            serverRow(server)
                        }
                    }
                } else if busy || error == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                }
            }
        }
        let configured = Set(OMPMCPDocument.servers(in: document ?? [:]).compactMap { MCPCatalog.entry(matching: $0.id)?.id })
        MCPQuickConnectCatalog(query: query, configured: configured, canEdit: configuration.hasEditableConfiguration, dismissDisabled: busy,
            select: { entry in
                guard !busy, let snapshot else { return }
                editing = MCPEditingSession(snapshot: snapshot, server: nil, entry: entry)
            }, presented: { presented(.catalog($0)) }, editor: { entry in AnyView(editor(for: .catalog(entry.id))) })
        }
        .task(id: context) {
            await LoginEnvironment.load()
            guard !Task.isCancelled else { return }
            configuration.start(context: context)
        }
        .onChange(of: context) { _, _ in editing = nil; removal = nil; login = nil }
        .onChange(of: configuration.fileURL) { _, _ in editing = nil; removal = nil; login = nil }
        .onDisappear { editing = nil; removal = nil; login = nil }
        .alert("Remove MCP server?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { server in
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Remove", role: .destructive) {
                guard let snapshot, let document else { return }
                self.removal = nil
                Task { _ = await save(OMPMCPDocument.removingServer(server.id, from: document), snapshot: snapshot) }
            }
        } message: { server in
            Text(verbatim: String(format: Chrome.localized("Remove %@ from the active profile?"), server.id))
        }
    }

    private var headerActions: AnyView {
        AnyView(HStack(spacing: 8) {
            Button("Install server") {
                guard !busy, let snapshot else { return }
                editing = MCPEditingSession(snapshot: snapshot, server: nil)
            }.buttonStyle(.glass).disabled(!configuration.hasEditableConfiguration)
                .chromePopover(isPresented: presented(.installation), arrowEdge: .top) {
                    editor(for: .installation)
                }
            Button("Open JSON file") {
                Task {
                    guard !busy else { return }
                    _ = await configuration.openFile(currentContext: { context })
                }
            }.buttonStyle(.glass).disabled(context == nil)
        })
    }

    private func serverRow(_ server: OMPMCPServer) -> some View {
        HStack(spacing: 12) {
            if let entry = MCPCatalog.entry(matching: server.id) { MCPGlyph(entry: entry, size: 24).accessibilityHidden(true) }
            else { Image(systemName: server.transport == .stdio ? "terminal" : "network")
                .font(.symbol(.title3)).foregroundStyle(Chrome.secondaryText).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: server.id).font(.ui(.body, weight: .medium)).lineLimit(1)
                Text(verbatim: server.detail).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if server.transport != .stdio, MCPCatalog.entry(matching: server.id)?.isOAuth == true
                || server.definition["auth"]?["type"]?.string == "oauth" || server.definition["oauth"] != nil {
                ChromeCircleButton(symbol: "key", help: "Sign in with OMP") {
                    guard !busy, let snapshot else { return }
                    login = MCPLoginSession(snapshot: snapshot, server: server)
                }
                .disabled(!server.enabled)
                .badgePopover(isPresented: Binding(get: { login?.server.id == server.id }, set: { if !$0 { login = nil } }), liveDetailWidth: 480, usesViewAnchor: true) {
                    if let login, login.server.id == server.id {
                        OMPMCPLoginPopover(session: login, context: { context }, save: { value in await save(value, snapshot: login.snapshot) })
                            .id(login.id).presentedChrome()
                    }
                }
            }
            ChromeCircleButton(symbol: "pencil", help: "Edit MCP server") {
                guard !busy, let snapshot else { return }
                editing = MCPEditingSession(snapshot: snapshot, server: server)
            }
            .chromePopover(isPresented: presented(.server(server.id)), arrowEdge: .trailing) {
                editor(for: .server(server.id))
            }
            ChromeCircleButton(
                symbol: server.enabled ? "eye" : "eye.slash",
                help: String(format: Chrome.localized(server.enabled ? "Disable MCP server %@" : "Enable MCP server %@"), server.id)
            ) {
                Task {
                    guard !busy, let document, let snapshot else { return }
                    do { _ = await save(try OMPMCPDocument.settingEnabled(!server.enabled, server: server.id, in: document), snapshot: snapshot) }
                    catch { configuration.error = error.localizedDescription }
                }
            }
            .accessibilityValue(Text(verbatim: Chrome.localized(server.enabled ? "Enabled" : "Disabled")))
            ChromeCircleButton(symbol: "trash", help: "Remove MCP server", foreground: Chrome.danger) {
                guard !busy else { return }
                removal = server
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).disabled(!configuration.hasEditableConfiguration)
    }

    private func presented(_ target: MCPEditingTarget) -> Binding<Bool> {
        Binding(get: { editing?.target == target }, set: { shown in
            if !shown, editing?.target == target { editing = nil }
        })
    }

    @ViewBuilder private func editor(for target: MCPEditingTarget) -> some View {
        if let session = editing, session.target == target {
            if let entry = session.entry {
                MCPQuickConnectEditor(entry: entry) { definition in
                    do {
                        let value = try OMPMCPDocument.replacingServer(in: session.snapshot.document(), oldName: nil,
                            name: entry.id, definition: definition, enabled: true)
                        let error = await save(value, snapshot: session.snapshot)
                        if error == nil, entry.isOAuth, let snapshot {
                            login = MCPLoginSession(snapshot: snapshot, server: OMPMCPServer(id: entry.id, definition: definition, enabled: true))
                        }
                        return error
                    } catch { return error.localizedDescription }
                }.id(session.id).presentedChrome()
            } else {
            MCPServerEditor(snapshot: session.snapshot, server: session.server, openFile: {
                await configuration.openFile(currentContext: { context })
            }) { value in
                await save(value, snapshot: session.snapshot)
            }.id(session.id).presentedChrome()
            }
        }
    }

    @MainActor private func save(_ value: JSONValue, snapshot: OMPMCPSnapshot) async -> String? {
        await configuration.save(value, snapshot: snapshot, currentContext: { context })
    }
}

/// Keeps one native profile warm across page navigation. A refresh never replaces an open form's snapshot.
@MainActor @Observable
final class MCPSettingsState {
    private(set) var snapshot: OMPMCPSnapshot?
    private(set) var document: JSONValue?
    private(set) var fileURL: URL?
    private(set) var busy = false
    var error: String?
    @ObservationIgnored private var context: OMPDiscoveryContext?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var fileWatch: PreviewFileWatch?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var needsProfileResolution = false
    @ObservationIgnored private var resolvingProfile = false

    // Transient I/O locks actions without toggling the native glass disabled appearance.
    var hasEditableConfiguration: Bool { snapshot != nil && document != nil }

    func start(context: OMPDiscoveryContext?) {
        if self.context == context, context != nil {
            // Reopening a page keeps its content and coalesces with an existing read.
            if !busy || (!resolvingProfile && !needsProfileResolution) { refresh() }
            return
        }
        stop()
        self.context = context
        guard context != nil else { error = ProviderError.notInstalled(.omp).localizedDescription; return }
        refresh()
    }

    func stop() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        fileWatch?.stop()
        fileWatch = nil
        context = nil
        needsRefresh = false
        needsProfileResolution = false
        resolvingProfile = false
        busy = false
        snapshot = nil
        document = nil
        fileURL = nil
        error = nil
    }

    func refresh(resolveProfile: Bool = true) {
        guard let context else { return }
        needsRefresh = true
        needsProfileResolution = needsProfileResolution || resolveProfile
        guard !busy else { return }
        busy = true
        let expected = generation
        refreshTask = Task { [weak self] in
            guard let self, generation == expected, !Task.isCancelled else { return }
            defer {
                if generation == expected { resolvingProfile = false; refreshTask = nil; finish(expected) }
            }
            repeat {
                needsRefresh = false
                let resolveProfile = needsProfileResolution
                needsProfileResolution = false
                resolvingProfile = resolveProfile || fileURL == nil
                do {
                    let directory: URL
                    if !resolveProfile, let fileURL {
                        directory = fileURL.deletingLastPathComponent()
                    } else {
                        directory = try await OMPMCPConfiguration.activeDirectory(context)
                    }
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                    let url = directory.appendingPathComponent("mcp.json")
                    if fileURL != url || fileWatch == nil {
                        if fileURL != url {
                            snapshot = nil
                            document = nil
                        }
                        fileWatch?.stop()
                        fileWatch = PreviewFileWatch(url: url) { [weak self] in self?.refresh(resolveProfile: false) }
                        fileURL = url
                    }
                    // Install the watch before reading so an overlapping external save queues another read.
                    let loaded = try await OMPMCPConfiguration.read(directory: directory, context: context)
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                    let value = try loaded.document()
                    try OMPMCPDocument.validate(value)
                    snapshot = loaded
                    document = value
                    error = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == expected else { return }
                    snapshot = nil
                    document = nil
                    self.error = error.localizedDescription
                }
            } while needsRefresh && generation == expected && !Task.isCancelled
        }
    }

    func save(_ value: JSONValue, snapshot: OMPMCPSnapshot,
              currentContext: () -> OMPDiscoveryContext?) async -> String? {
        guard !busy else { return Chrome.localized("OMP configuration is busy. Wait for it to finish and try again.") }
        guard context == snapshot.context else { return Chrome.localized("The OMP configuration changed. Reopen the editor before saving.") }
        busy = true
        let expected = generation
        defer { finish(expected) }
        do {
            let saved = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: {
                generation == expected && context == snapshot.context ? currentContext() : nil
            })
            guard generation == expected, context == snapshot.context else {
                return Chrome.localized("The OMP configuration changed. Reopen the editor before saving.")
            }
            self.snapshot = saved
            document = value
            error = nil
            return nil
        } catch {
            if generation == expected { self.error = error.localizedDescription }
            return error.localizedDescription
        }
    }

    func openFile(currentContext: () -> OMPDiscoveryContext?,
                  open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) async -> String? {
        guard !busy else { return Chrome.localized("OMP configuration is busy. Wait for it to finish and try again.") }
        guard let context else { return ProviderError.notInstalled(.omp).localizedDescription }
        busy = true
        let expected = generation
        defer { finish(expected) }
        do {
            let url = try await OMPMCPConfiguration.prepareForOpening(context: context, currentContext: {
                generation == expected ? currentContext() : nil
            })
            guard generation == expected else { return Chrome.localized("The OMP configuration changed. Reopen the editor before saving.") }
            guard open(url) else { throw OMPMCPDocument.failure("The JSON file could not be opened.") }
            error = nil
            needsRefresh = true
            return nil
        } catch {
            if generation == expected { self.error = error.localizedDescription }
            return error.localizedDescription
        }
    }

    private func finish(_ expected: UUID) {
        guard generation == expected else { return }
        busy = false
        if needsRefresh { refresh() }
    }
}
