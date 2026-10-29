import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var filePreviews = FilePreviewStore()

    private var mcpContext: OMPDiscoveryContext? { OMPMCPConfiguration.context(registry: model.providers) }

    var body: some View {
        let sidebar = model.sidebar
        let settingsShown = SettingsNavigation.shared.isPresented
        GeometryReader { geometry in
            ZStack {
                HStack(spacing: 0) {
                    // The rows are laid out at the sidebar's width once, and the slide moves the clip
                    // alone, so no row re-wraps per frame.
                    SidebarView()
                        .frame(width: sidebar.width)
                        .frame(width: sidebar.renderedWidth, alignment: .trailing)
                        .clipped()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { sidebar.noteLaidOutWidth($0) }
                        .overlay(alignment: .trailing) {
                            SidebarResizeHandle(
                                isActive: sidebar.isVisible && !settingsShown,
                                onBegin: { sidebar.beginDrag() },
                                onChange: { sidebar.drag(by: $0) },
                                onEnd: { sidebar.endDrag() }
                            )
                            .frame(width: SidebarResizeHandle.hitWidth)
                            .padding(.top, Chrome.trafficLightTop + Chrome.trafficLightDiameter)
                        }

                    WorkspaceDetailView(previews: filePreviews, sidebarTargetWidth: sidebar.isSliding
                        ? max(0, geometry.size.width - sidebar.renderedWidth - Chrome.sheetInset * (sidebar.isVisible ? 1 : 2))
                        : nil)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        // The sheet keeps to its own bounds. A conversation gliding sideways to make
                        // room for a panel (`ReserveSlide` carries it on an offset), a panel settling
                        // into a corner of a pane that just changed size, and rows re-wrapping in a
                        // live resize all reach past the sheet for a few frames, and drew over the
                        // sidebar or off the window's edge until they landed.
                        .clipped()
                        .padding(.leading, sidebar.isVisible ? 0 : Chrome.sheetInset)
                        .padding(.trailing, Chrome.sheetInset)
                        .padding(.vertical, Chrome.sheetInset)
                }
                .opacity(settingsShown ? 0 : 1)
                .disabled(settingsShown)
                .allowsHitTesting(!settingsShown)
                .accessibilityHidden(settingsShown)
                if settingsShown { SettingsView() }
            }
        }
        // While the sidebar is hidden, dragging the window's leading edge pulls it back out.
        .overlay(alignment: .leading) {
            SidebarResizeHandle(
                isActive: !sidebar.isVisible && !settingsShown,
                onBegin: { sidebar.beginDrag() },
                onChange: { sidebar.drag(by: $0) },
                onEnd: { sidebar.endDrag() }
            )
            .frame(width: SidebarResizeHandle.hitWidth)
            .padding(.top, Chrome.trafficLightTop + Chrome.trafficLightDiameter)
        }
        .overlay(alignment: .topLeading) {
            if !settingsShown, !sidebar.holdsTrafficLights,
               model.selectedThreadID.flatMap({ model.thread($0) }) == nil {
                SidebarToggleButton()
                    .padding(.leading, Chrome.trafficLightsWidth + Chrome.trafficLightClearance + Chrome.chromeHorizontalPadding)
                    .padding(.top, Chrome.chromeTopPadding)
            }
        }
        .background { WindowBackdrop(opacity: model.settings.backdropOpacity, wallpaper: WallpaperStore.shared.image) }
        .background { WindowChromeConfigurator(sidebarVisible: settingsShown || sidebar.holdsTrafficLights, sidebarDragging: sidebar.isDragging && !settingsShown, performanceMode: model.settings.performanceMode) }
        .onChange(of: settingsShown, initial: true) { _, shown in filePreviews.setWorkspacePresented(!shown) }
        .task(id: mcpContext) {
            guard !CaptureRun.isEnabled else { return }
            await LoginEnvironment.load()
            guard !Task.isCancelled else { return }
            model.mcpSettings.start(context: mcpContext)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !CaptureRun.isEnabled, LoginEnvironment.isLoaded {
                model.mcpSettings.start(context: mcpContext)
            }
        }
        .ignoresSafeArea()
        .coordinateSpace(.named(GenieAnimator.coordinateSpace))
        .environment(\.openURL, OpenURLAction { url in
            if model.openWebLink(url, previews: filePreviews) { return .handled }
            return .systemAction
        })
        .overlay { GenieLayer().opacity(settingsShown ? 0 : 1) }
        .overlay { RowGlideLayer().opacity(settingsShown ? 0 : 1) }
        .overlay {
            if model.isCommandPalettePresented {
                CommandPalette()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            return settingsShown ? false : handleDrop(urls)
        }
        .alert(
            Chrome.localized(model.alert?.title ?? ""),
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(verbatim: Chrome.localized(alert.message))
        }
    }

    @discardableResult
    private func handleDrop(_ urls: [URL]) -> Bool {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { folders.append(url) } else { files.append(url) }
        }
        var lastProject: Project?
        for folder in folders { lastProject = model.addProject(at: folder) }
        if let lastProject { model.newThread(in: lastProject) }
        if !files.isEmpty, let threadID = model.selectedThreadID {
            Storage.attach(files.map(AttachmentSource.file), to: Bindable(model.runtime(for: threadID)).draft.attachments)
        }
        return !folders.isEmpty || !files.isEmpty
    }
}

/// Whether the chat column a view sits in is the one on screen. The columns of the threads
/// visited last stay built behind the selected one (see `ThreadColumns`), so a view that
/// would react to appearing or disappearing reacts to this instead.
extension EnvironmentValues {
    @Entry var chatColumnIsShown = true
}

struct DetailView: View {
    var previews: FilePreviewStore? = nil
    @Environment(AppModel.self) private var model
    @Environment(WindowLiveResize.self) private var liveResize
    @Environment(\.workspaceTerminalAction) private var workspaceTerminalAction
    @Environment(\.workspaceReviewAction) private var workspaceReviewAction
    @Environment(\.filePreviewAction) private var filePreviewAction
    @Environment(\.filePreviewToggle) private var filePreviewToggle
    @Environment(\.filePreviewIsVisible) private var filePreviewIsVisible
    /// Threads whose columns are built behind the selection, ahead of a click on them.
    @State private var prebuilt: [UUID] = []
    @State private var hasPrebuiltTopRows = false
    /// `kCGAnyInputEventType`, which Quartz leaves out of the Swift enum.
    private static let anyInput = CGEventType(rawValue: ~0)!

    var body: some View {
        if let threadID = model.selectedThreadID, model.thread(threadID) != nil {
            let running = Set(model.threads.compactMap { model.existingRuntime(for: $0.id)?.isRunning == true ? $0.id : nil })
            ThreadColumns(previews: previews, threadID: threadID, prebuilt: prebuilt, running: running, model: model, liveResize: liveResize,
                          filePreviewAction: filePreviewAction, filePreviewToggle: filePreviewToggle, filePreviewIsVisible: filePreviewIsVisible, workspaceReviewAction: workspaceReviewAction, workspaceTerminalAction: workspaceTerminalAction)
                .onChange(of: threadID) { _, _ in prebuilt = [] }
                .task(id: threadID) {
                    // The neighbours, and at launch the sidebar's top rows, one at a time, once
                    // the reader has settled on the thread and nothing streams in it: each is a
                    // frame's worth of building.
                    try? await Task.sleep(for: .milliseconds(1500))
                    var candidates = model.neighbors(of: threadID)
                    if !hasPrebuiltTopRows {
                        hasPrebuiltTopRows = true
                        candidates += model.sidebarThreads.prefix(ThreadColumns.topRowsBuiltAtLaunch).map(\.id)
                    }
                    for id in candidates where !Task.isCancelled {
                        // Never under the reader's hands: a build holds the main thread for a
                        // frame or a few, which a keystroke would wait on.
                        while !Task.isCancelled, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput) < 1 {
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                        guard !Task.isCancelled, !(model.existingRuntime(for: threadID)?.isRunning ?? false) else { return }
                        if id != threadID, !prebuilt.contains(id) { prebuilt.append(id) }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
        } else {
            Group {
                // The library decodes off the main thread at launch: until it lands, an empty
                // project list says nothing, and the welcome screen would flash.
                if !model.isLibraryLoaded {
                    Color.clear
                } else if model.projects.isEmpty {
                    WelcomeView()
                } else {
                    NoThreadView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The chat column, hosted on its own per thread. The columns of the threads visited last
/// stay in the pane, hidden, so switching back to one is a change of visibility rather
/// than a rebuild of the timeline, the composer and the panels: the rows of a long thread
/// took a quarter of a second to build each time. Hosting each column apart also keeps
/// every view tree small: SwiftUI walks a tree whole whenever a focusable view appears in
/// it or the pointer moves over it. Hidden rather than detached, because a hosting view
/// taken out of the window disappears to its views, and every task of the column starts
/// over when it comes back.
private struct ThreadColumns: NSViewRepresentable {
    let previews: FilePreviewStore?
    /// How many of the sidebar's top rows are built behind the first thread shown.
    static let topRowsBuiltAtLaunch = 6

    let threadID: UUID
    let prebuilt: [UUID]
    /// Threads with a turn under way. A hidden column of one goes: its rows would stream
    /// unseen, at the same cost as on screen.
    let running: Set<UUID>
    let model: AppModel
    let liveResize: WindowLiveResize
    let filePreviewAction: FilePreviewAction
    let filePreviewToggle: FilePreviewToggleAction
    let filePreviewIsVisible: Bool
    let workspaceReviewAction: WorkspaceReviewAction
    let workspaceTerminalAction: WorkspaceTerminalAction

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ pane: NSView, context: Context) {
        let columns = context.coordinator
        columns.previews = previews
        columns.show(threadID, in: pane, model: model, liveResize: liveResize, action: filePreviewAction, toggle: filePreviewToggle, visible: filePreviewIsVisible, review: workspaceReviewAction, terminal: workspaceTerminalAction)
        columns.dropHidden(where: { running.contains($0) || model.thread($0) == nil || model.existingRuntime(for: $0) == nil })
        columns.prebuild(prebuilt.filter { model.thread($0) != nil && !running.contains($0) }, in: pane, model: model, liveResize: liveResize,
                         action: filePreviewAction, toggle: filePreviewToggle, visible: filePreviewIsVisible, review: workspaceReviewAction, terminal: workspaceTerminalAction)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor final class Coordinator {
        var previews: FilePreviewStore?
        /// How many columns stay built behind the shown one.
        private static let keptLimit = 8
        /// Hidden columns keep the size they were built at and take the pane's size only
        /// when shown: resizing every hidden column per frame during a sidebar slide or
        /// live resize is what made them lag.
        private var columns: [UUID: FrameHostingView] = [:]
        /// The threads with a column, the one to drop first at the front and the shown one
        /// last. A column built ahead of a click goes in at the front: it is the first to
        /// make room for the columns the reader has been to.
        private var order: [UUID] = []
        private var shown: UUID?
        /// What was asked for ahead of a click, so a column dropped since is not built over
        /// and over on every update.
        private var requested: Set<UUID> = []
        /// Columns dropped, kept until the switch that dropped them has been drawn: taking
        /// a view tree down costs a frame's worth of time, better spent after the frame.
        private var retired: [FrameHostingView] = []
        private var retirement: Task<Void, Never>?
        private var previewVisible = false
        private var terminalAction = WorkspaceTerminalAction()

        func show(_ id: UUID, in pane: NSView, model: AppModel, liveResize: WindowLiveResize, action: FilePreviewAction, toggle: FilePreviewToggleAction, visible: Bool, review: WorkspaceReviewAction, terminal: WorkspaceTerminalAction) {
            if id == shown {
                if visible != previewVisible || terminal != terminalAction {
                    columns[id]?.rootView = Self.root(id, isShown: true, model: model, liveResize: liveResize, action: action, toggle: toggle, visible: visible, review: review, terminal: terminal, previews: previews)
                    previewVisible = visible
                    terminalAction = terminal
                }
                return
            }
            if let shown, let previous = columns[shown] {
                previous.isHidden = true
                previous.autoresizingMask = []
                previous.rootView = Self.root(shown, isShown: false, model: model, liveResize: liveResize, action: action, toggle: toggle, visible: visible, review: review, terminal: terminal, previews: previews)
            }
            if let kept = columns[id] {
                kept.rootView = Self.root(id, isShown: true, model: model, liveResize: liveResize, action: action, toggle: toggle, visible: visible, review: review, terminal: terminal, previews: previews)
                kept.frame = pane.bounds
                kept.autoresizingMask = [.width, .height]
                kept.isHidden = false
            } else {
                make(id, isShown: true, in: pane, model: model, liveResize: liveResize, action: action, toggle: toggle, visible: visible, review: review, terminal: terminal)
            }
            shown = id
            previewVisible = visible
            terminalAction = terminal
            order.removeAll { $0 == id }
            order.append(id)
            while order.count > Self.keptLimit + 1 { drop(order[0]) }
        }

        /// Drops the hidden columns the test names; each is built afresh when its thread is
        /// next selected.
        func dropHidden(where goes: (UUID) -> Bool) {
            for id in Array(columns.keys) where id != shown && goes(id) { drop(id) }
        }

        /// Builds the columns asked for, hidden and laid out at the pane's size, so a click
        /// on one of the threads finds its rows made. Each is built once per request: one
        /// dropped to make room for the columns visited since stays dropped.
        func prebuild(_ ids: [UUID], in pane: NSView, model: AppModel, liveResize: WindowLiveResize, action: FilePreviewAction, toggle: FilePreviewToggleAction, visible: Bool, review: WorkspaceReviewAction, terminal: WorkspaceTerminalAction) {
            for id in ids where !requested.contains(id) && columns[id] == nil {
                let started = ContinuousClock.now
                make(id, isShown: false, in: pane, model: model, liveResize: liveResize, action: action, toggle: toggle, visible: visible, review: review, terminal: terminal).layoutSubtreeIfNeeded()
                SwitchLatency.note("prebuilt \(model.thread(id)?.title.prefix(24) ?? "?") in \(started.duration(to: .now))")
                order.insert(id, at: 0)
                while order.count > Self.keptLimit + 1 { drop(order[0]) }
            }
            requested = Set(ids)
        }

        @discardableResult
        private func make(_ id: UUID, isShown: Bool, in pane: NSView, model: AppModel, liveResize: WindowLiveResize, action: FilePreviewAction, toggle: FilePreviewToggleAction, visible: Bool, review: WorkspaceReviewAction, terminal: WorkspaceTerminalAction) -> FrameHostingView {
            let column = FrameHostingView(rootView: Self.root(id, isShown: isShown, model: model, liveResize: liveResize, action: action, toggle: toggle, visible: visible, review: review, terminal: terminal, previews: previews))
            column.frame = pane.bounds
            column.isHidden = !isShown
            column.autoresizingMask = isShown ? [.width, .height] : []
            pane.addSubview(column)
            columns[id] = column
            return column
        }

        private static func root(_ id: UUID, isShown: Bool, model: AppModel, liveResize: WindowLiveResize, action: FilePreviewAction, toggle: FilePreviewToggleAction, visible: Bool, review: WorkspaceReviewAction, terminal: WorkspaceTerminalAction, previews: FilePreviewStore? = nil) -> AnyView {
            AnyView(
                ChatView(runtime: model.runtime(for: id), previews: previews)
                    .modifier(ChatVeilVisibility())
                    .modifier(ChatColumnVisibility(isSelected: isShown, previews: previews))
                    .modifier(HostedEnvironment(model: model, liveResize: liveResize, previews: previews))
                    .environment(\.filePreviewAction, action)
                    .environment(\.filePreviewToggle, toggle)
                    .environment(\.filePreviewIsVisible, visible)
                    .environment(\.workspaceReviewAction, review)
                    .environment(\.workspaceTerminalAction, terminal)
            )
        }

        private func drop(_ id: UUID) {
            order.removeAll { $0 == id }
            guard let column = columns.removeValue(forKey: id) else { return }
            retired.append(column)
            retirement?.cancel()
            retirement = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                for column in retired { column.removeFromSuperview() }
                retired.removeAll()
            }
        }
    }
}

private struct ChatColumnVisibility: ViewModifier {
    let isSelected: Bool
    var previews: FilePreviewStore? = nil
    func body(content: Content) -> some View {
        content.environment(\.chatColumnIsShown, isSelected && !SettingsNavigation.shared.isPresented && previews?.isConversationPresented != false)
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 104, height: 104)
                    Text("OMP GUI")
                        .font(AppFont.swiftUI(size: 34, weight: .semibold))
                    Text("A calm, native home for your coding agents.")
                        .font(.ui(.title3))
                        .foregroundStyle(Chrome.secondaryText)
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            model.chooseProjectFolder()
                        } label: {
                            Label("Add a project", systemImage: "folder.badge.plus")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        Button {
                            GitHubClonePanel.shared.present(model: model)
                        } label: {
                            Label {
                                Text("Clone from GitHub")
                            } icon: {
                                Image("mcp-github").resizable().scaledToFit()
                                    .frame(width: 16, height: 16)
                            }
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                    }
                    Button { model.newThread(affiliation: .standalone) } label: {
                        Label("New task", systemImage: "plus.circle")
                    }
                    .buttonStyle(.glass)
                    Text("Or drop a folder anywhere in this window.")
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                }
                ChromeSection(title: "Providers") {
                    ProviderChecklist()
                }
                .frame(maxWidth: 480)
            }
            .padding(48)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct ProviderChecklist: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ChromeCard {
            ForEach(Array(ProviderKind.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 { ChromeRowDivider() }
                ProviderStatusRow(provider: provider)
            }
        }
    }
}

private struct ProviderStatusRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind

    var body: some View {
        let status = model.providers.status(provider)
        HStack(spacing: 12) {
            ProviderIcon(provider: provider, size: 18)
                .foregroundStyle(Chrome.primaryText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: provider.displayName)
                    .font(.ui(.body))
                Text(verbatim: status.isChecking ? Chrome.localized("Checking…") : status.summary)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            Spacer()
            if status.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else if !status.isInstalled {
                if provider.isAPIKeyBased {
                    // Nothing to install: the key is typed in Settings, so the row opens it
                    // rather than sending the reader to a web page for it.
                    OpenProvidersSettingsButton()
                } else {
                    Link("Install", destination: provider.installURL)
                        .buttonStyle(.glass)
                }
            } else if status.auth == .signedOut {
                if provider.isAPIKeyBased {
                    OpenProvidersSettingsButton()
                } else {
                    Button("Login") { Workspace.openTerminal(running: provider.loginCommand) }
                        .buttonStyle(.glass)
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Chrome.success)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// Takes the reader to the Providers page, where a key-based provider's key is typed.
private struct OpenProvidersSettingsButton: View {
    var body: some View {
        Button("Add key") {
            WindowManager.shared.showSettings(page: .providers)
        }
        .buttonStyle(.glass)
        .help("Open Settings > Providers")
    }
}

struct NoThreadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Chrome.secondaryText)
            Text("Pick a thread or start a new one")
                .font(.ui(.title2, weight: .medium))
            Button {
                model.newThread()
            } label: {
                Label("New thread", systemImage: "plus.circle")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            // The chord as the store has it now, so a remap never leaves a stale key here.
            if let chord = ShortcutStore.label(for: .newThread) {
                Text(verbatim: chord)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatVeilVisibility: ViewModifier {
    @Environment(\.chatColumnIsShown) private var isShown
    @State private var scope = VeilRenderScope()

    func body(content: Content) -> some View {
        content.environment(\.veilRenderScope, scope)
            .onChange(of: isShown, initial: true) { _, shown in scope.setVisible(shown) }
            .onDisappear { scope.setVisible(false) }
    }
}
