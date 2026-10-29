import AppKit
import SwiftUI

/// The existing native split owns width and visibility; this shell only routes
/// the selected destination. Inactive retained pages stop reading and watching.
struct WorkspaceSidebarPane: View {
    let store: FilePreviewStore

    var body: some View {
        VStack(spacing: 0) {
            if !store.isFullscreen { WorkspaceSidebarTabBar(store: store) }
            WorkspaceSidebarContent(store: store)
                .id(store.context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { NoWindowDragArea() }
        .accessibilityLabel(Text("Workspace sidebar"))
        .dropDestination(for: URL.self) { urls, _ in
            let local = urls.filter(\.isFileURL)
            store.openFiles(local)
            return !local.isEmpty
        }
    }
}

/// Keep one Files page mounted while its tab exists in the current workspace.
/// Its native scroll container and folder rows retain their exact presentation;
/// only the active page may read directories or accept input.
private struct WorkspaceSidebarContent: View {
    @Environment(AppModel.self) private var model
    let store: FilePreviewStore
    @State private var filesHaveOpened = false
    @State private var gitHasOpened = false
    @State private var historyHasOpened = false

    private var showsFiles: Bool { store.activeSidebarTab == .panel(.files) }
    private var hasFilesTab: Bool { store.session?.panels.contains(.files) == true }
    private var showsGit: Bool { store.activeSidebarTab == .panel(.git) }
    private var hasGitTab: Bool { store.session?.panels.contains(.git) == true }
    private var showsHistory: Bool { store.activeSidebarTab == .panel(.trajectory) }
    private var hasHistoryTab: Bool { store.session?.panels.contains(.trajectory) == true }

    var body: some View {
        ZStack {
            if hasFilesTab && (filesHaveOpened || showsFiles) {
                FilePreviewPane(store: store, browsesFiles: true, isPresented: showsFiles)
                    .opacity(showsFiles ? 1 : 0)
                    .disabled(!showsFiles)
                    .allowsHitTesting(showsFiles)
                    .accessibilityHidden(!showsFiles)
            }
            if hasGitTab && (gitHasOpened || showsGit), let session = store.session {
                GitWorkspacePane(previews: store, session: session)
                    .id(session.key)
                    .opacity(showsGit ? 1 : 0)
                    .disabled(!showsGit)
                    .allowsHitTesting(showsGit)
                    .accessibilityHidden(!showsGit)
            }
            if hasHistoryTab && (historyHasOpened || showsHistory), let session = store.session {
                SessionHistoryPane(previews: store, session: session)
                    .id(session.key)
                    .opacity(showsHistory ? 1 : 0)
                    .disabled(!showsHistory)
                    .allowsHitTesting(showsHistory)
                    .accessibilityHidden(!showsHistory)
            }
            if !showsFiles && !showsGit && !showsHistory { content }
        }
        .animation(nil, value: store.activeSidebarTab)
        .onChange(of: showsFiles, initial: true) { _, shown in
            if shown { filesHaveOpened = true }
        }
        .onChange(of: hasFilesTab) { _, present in
            if !present { filesHaveOpened = false }
        }
        .onChange(of: showsGit, initial: true) { _, shown in
            if shown { gitHasOpened = true }
        }
        .onChange(of: hasGitTab) { _, present in
            if !present { gitHasOpened = false }
        }
        .onChange(of: showsHistory, initial: true) { _, shown in
            if shown { historyHasOpened = true }
        }
        .onChange(of: hasHistoryTab) { _, present in
            if !present { historyHasOpened = false }
        }
    }

    @ViewBuilder private var content: some View {
        if store.activeSidebarTab == .conversation {
            Color.clear
        } else if store.isChoosingPanel || store.sidebarTabs.isEmpty {
            WorkspacePanelPicker(store: store)
        } else if let panel = store.session?.activePanel {
            switch panel {
            case .files:
                EmptyView()
            case .terminal:
                if let context = store.context {
                    TerminalPanel(runtime: model.runtime(for: context.threadID), directory: context.workingDirectory,
                                  isSidebar: true, onHide: { store.setVisible(false) })
                        .id(context)
                }
            case .review:
                if let session = store.session {
                    DiffInspector(runtime: model.runtime(for: session.context.threadID), sidebarSession: session)
                        .environment(\.filePreviewContext, session.context)
                        .id(session.key)
                        .onChange(of: session.reviewSelection) { store.scheduleSave() }
                }
            case .git, .trajectory:
                EmptyView()
            case .debug:
                if let context = store.context {
                    DebugWorkspacePane(runtime: model.runtime(for: context.threadID), previews: store, context: context)
                        .id(context)
                }
            case .context:
                if let session = store.session {
                    ContextWorkspacePane(runtime: model.runtime(for: session.context.threadID), previews: store, session: session)
                        .id(session.key)
                }
            case .browser:
                if let session = store.session {
                    BrowserWorkspacePane(state: session.webBrowser, searchEngine: model.settings.browserSearchEngine)
                        .id(session.context.threadID)
                }
            }
        } else {
            FilePreviewPane(store: store)
        }
    }
}

private struct WorkspacePanelPicker: View {
    let store: FilePreviewStore

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(WorkspacePanel.allCases, id: \.self) { panel in
                        WorkspacePanelPickerRow(panel: panel) { store.openPanel(panel) }
                    }
                }
                .padding(16)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}

private struct WorkspacePanelPickerRow: View {
    let panel: WorkspacePanel
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: panel.symbol)
                    .font(.symbol(.body)).frame(width: 22)
                    .foregroundStyle(Chrome.secondaryText)
                Text(verbatim: Chrome.localized(panel.title))
                    .font(.ui(.body)).lineLimit(1)
                Spacer(minLength: 8)
                if !panel.isImplemented {
                    Text("Coming soon").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(.rect)
            .background(Chrome.overlay(isHovering ? 0.06 : 0), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct WorkspaceSidebarTabBar: View {
    let store: FilePreviewStore

    var body: some View {
        HStack(spacing: 6) {
            WorkspaceSidebarTabs(store: store)
            WorkspaceSidebarControls(store: store)
                .padding(.trailing, 8)
        }
        .frame(height: Chrome.capsuleHeight)
        .padding(.top, Chrome.chromeTopPadding)
        .padding(.bottom, 6)
    }
}

/// Both layouts use the same peer tabs. The conversation is a permanent tab
/// only while fullscreen; only panel and file tabs expose close actions.
struct WorkspaceSidebarTabs: View {
    @Environment(WindowLiveResize.self) private var liveResize
    let store: FilePreviewStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(store.sidebarTabs) { tab in
                        tabButton(tab).id(tab.id)
                    }
                    WorkspaceNewPanelButton(store: store)
                }
                .padding(.horizontal, 8).padding(.vertical, Chrome.capsuleVerticalPadding)
            }
            .scrollIndicators(.hidden)
            .onChange(of: store.activeSidebarTab, initial: true) { old, selected in
                if let selected {
                    if old != nil, old != selected, !liveResize.isReshaping,
                       !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        withAnimation(Chrome.panelSlide) { proxy.scrollTo(selected.id, anchor: .center) }
                    } else {
                        proxy.scrollTo(selected.id, anchor: .center)
                    }
                }
            }
        }
        .frame(minWidth: 100, maxWidth: .infinity)
    }

    @ViewBuilder private func tabButton(_ tab: WorkspaceSidebarTab) -> some View {
        switch tab {
        case .conversation:
            WorkspaceConversationTab(store: store)
        case .panel(let panel):
            WorkspacePanelTabButton(panel: panel, isSelected: store.activeSidebarTab == tab, store: store)
        case .file(let path):
            if let file = store.session?.tabs.first(where: { $0.id == path }) {
                PreviewTabButton(tab: file, isSelected: store.activeSidebarTab == tab, store: store)
                    .draggable(path)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first, store.session?.tabs.contains(where: { $0.id == id }) == true else { return false }
                        store.move(id, before: path)
                        return true
                    }
            }
        }
    }
}

struct WorkspaceSidebarControls: View {
    let store: FilePreviewStore

    var body: some View {
        ChromeCapsule {
            ChromeIconButton(symbol: store.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             help: store.isFullscreen ? "Exit workspace fullscreen" : "Enter workspace fullscreen") {
                store.setFullscreen(!store.isFullscreen)
            }
            .accessibilityIdentifier("workspace.fullscreen")
            ChromeIconButton(symbol: "sidebar.right", help: "Hide workspace sidebar") { store.setVisible(false) }
        }
    }
}

private struct WorkspaceNewPanelButton: View {
    let store: FilePreviewStore
    @State private var isHovering = false

    var body: some View {
        Button { store.togglePanelPicker() } label: {
            Image(systemName: "plus")
                .font(.symbol(.body))
                .foregroundStyle(isHovering || store.isChoosingPanel ? Color.accentColor : Chrome.secondaryText)
                .frame(width: Chrome.capsuleHeight, height: Chrome.capsuleHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text("Open a panel"))
        .accessibilityLabel(Text("Open a panel"))
        .background { NoWindowDragArea() }
    }
}

private struct WorkspaceConversationTab: View {
    @Environment(AppModel.self) private var model
    let store: FilePreviewStore
    @State private var isRenaming = false
    @State private var renameText = ""

    private var title: String {
        let title = model.selectedThread?.title ?? ""
        return title.isEmpty ? Chrome.localized("New thread") : title
    }
    private var isSelected: Bool { store.activeSidebarTab == .conversation }

    var body: some View {
        Button { store.selectSidebarTab(.conversation) } label: {
            HStack(spacing: 6) {
                Image(systemName: "message").font(.symbol(.body))
                Text(verbatim: title).font(.ui(.body)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 260)
        .foregroundStyle(isSelected ? Chrome.primaryText : Chrome.secondaryText)
        .background(Chrome.overlay(isSelected ? 0.09 : 0), in: .rect(cornerRadius: 7))
        .help(title)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityIdentifier("workspace.conversation-tab")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Copy title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(title, forType: .string)
            }
            Button("Rename…") { renameText = title; isRenaming = true }
        }
        .chromePopover(isPresented: $isRenaming, arrowEdge: .bottom) {
            ChromeTextInputPopover(title: "Rename thread", prompt: "Title", submitTitle: "Rename", text: $renameText,
                onSubmit: {
                    isRenaming = false
                    if let id = store.context?.threadID { model.rename(id, to: renameText) }
                }, onCancel: { isRenaming = false })
        }
    }
}

private struct WorkspacePanelTabButton: View {
    let panel: WorkspacePanel
    let isSelected: Bool
    let store: FilePreviewStore

    var body: some View {
        HStack(spacing: 6) {
            Button { store.openPanel(panel) } label: {
                HStack(spacing: 6) {
                    Image(systemName: panel.symbol).font(.symbol(.body))
                    Text(verbatim: Chrome.localized(panel.title))
                        .font(.ui(.body)).lineLimit(1)
                }
                .frame(height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button { store.closeSidebarTab(.panel(panel)) } label: {
                Image(systemName: "xmark").font(.symbol(.caption2, weight: .semibold))
                    .frame(width: 20, height: 20).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text("Close sidebar tab"))
            .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Close %@ panel"), Chrome.localized(panel.title))))
        }
        .padding(.leading, 9).padding(.trailing, 3)
        .frame(height: 28)
        .foregroundStyle(isSelected ? Chrome.primaryText : Chrome.secondaryText)
        .background(Chrome.overlay(isSelected ? 0.09 : 0), in: .rect(cornerRadius: 7))
        .animation(Chrome.hover, value: isSelected)
        .contentShape(.rect)
        .contextMenu {
            Button("Close sidebar tab") { store.closeSidebarTab(.panel(panel)) }
            Button("Close other sidebar tabs") { store.closeOtherSidebarTabs(.panel(panel)) }
            Button("Close all sidebar tabs") { store.closeAllSidebarTabs() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
