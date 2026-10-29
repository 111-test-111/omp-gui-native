import AppKit
import Observation

/// One registry for the sidebar picker, tabs and placeholder destinations.
enum WorkspacePanel: String, CaseIterable, Sendable {
    case git, trajectory, review, context, terminal, debug, browser, files

    var title: String {
        switch self {
        case .git: "Git"
        case .trajectory: "Session history"
        case .review: "Review"
        case .context: "Context"
        case .terminal: "Terminal"
        case .debug: "Debug"
        case .browser: "Browser"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .git: "arrow.triangle.branch"
        case .trajectory: "point.bottomleft.forward.to.arrow.triangle.uturn.scurvepath"
        case .review: "checkmark.rectangle.stack"
        case .context: "text.redaction"
        case .terminal: "terminal"
        case .debug: "ladybug"
        case .browser: "globe"
        case .files: "folder"
        }
    }

    var isImplemented: Bool { true }
}

enum WorkspaceSidebarTab: Hashable, Identifiable {
    case conversation
    case panel(WorkspacePanel)
    case file(String)

    var id: String {
        switch self {
        case .conversation: "conversation"
        case .panel(let panel): "panel:" + panel.rawValue
        case .file(let path): "file:" + path
        }
    }
}

@MainActor @Observable
final class PreviewTab: Identifiable {
    let url: URL
    let origin: FilePreviewContext
    let reader: PreviewReaderState
    var isPinned: Bool
    var location: FilePreviewLocation?
    nonisolated var id: String { url.path }

    init(url: URL, origin: FilePreviewContext, isPinned: Bool, location: FilePreviewLocation? = nil, reader: PreviewReaderState = PreviewReaderState()) {
        self.url = url
        self.origin = origin
        self.isPinned = isPinned
        self.location = location
        self.reader = reader
    }
}

/// Small navigation state belongs to the conversation, rather than to a row
/// that a lazy stack can discard. Directory data still follows visible reads.
@MainActor @Observable
final class PreviewBrowserState {
    var expandedFolders: Set<String> = []
    var showsHidden = false
}

@MainActor @Observable
final class PreviewSession {
    enum ReviewSelection: Equatable {
        case latest
        case all
        case turn(UUID)
    }

    let context: FilePreviewContext
    var tabs: [PreviewTab] = []
    var selectedID: String?
    let browser = PreviewBrowserState()
    let gitNavigation = GitBrowseNavigation()
    var gitDetailFraction: CGFloat = 0.42
    var debugDetailFraction: CGFloat = 0.42
    var historyDetailFraction: CGFloat = 0.42
    let history = SessionHistoryStore()
    let contextInspection = ContextWorkspaceStore()
    var webBrowser: BrowserWorkspaceStore { BrowserWorkspaceRegistry.shared.workspace(for: context.threadID) }
    var panels: [WorkspacePanel] = [.files]
    var activePanel: WorkspacePanel? = .files
    var isChoosingPanel = false
    var isFullscreen = false
    var isConversationSelected = false
    var reviewSelection: ReviewSelection = .latest
    var reviewTurnID: UUID? {
        get {
            if case .turn(let id) = reviewSelection { return id }
            return nil
        }
        set { reviewSelection = newValue.map(ReviewSelection.turn) ?? .all }
    }
    var reviewRequest = 0
    // Keep the selected debug step when visiting its source tab. No adapter
    // references or result payloads live in workspace navigation state.
    var debugRecordID: String?
    var debugRunID: String?
    let debugHistory = DebugHistoryStore()
    var lastVisited = Date.now
    var selectedTab: PreviewTab? { tabs.first { $0.id == selectedID } }
    var key: String { Self.key(context) }

    init(context: FilePreviewContext) { self.context = context }

    func selectDebugRun(_ id: String?) {
        debugRunID = id; debugRecordID = nil
    }

    static func key(_ context: FilePreviewContext) -> String {
        context.threadID.uuidString + "\n" + URL(fileURLWithPath: context.workingDirectory).standardizedFileURL.path
    }
}

/// UI state belongs to a window, independently of OMP's session lifecycle. Only
/// the selected visible file has a reader, a load task and a filesystem watcher.
@MainActor @Observable
final class FilePreviewStore {
    static let maximumConcurrentOpens = 4
    static let maximumSessions = 24
    private static let maximumPersistenceBytes = 4 * 1_024 * 1_024
    typealias Opener = @Sendable (FilePreviewReference, String, Bool, PreviewFileSnapshot?) async throws -> PreviewFileOpening

    private(set) var session: PreviewSession?
    private(set) var snapshot: PreviewFileSnapshot?
    private(set) var isLoading = false
    private(set) var hasPendingOpen = false
    private(set) var error: String?
    private(set) var renderRevision = 0
    var notice: String?
    var isVisible = false {
        willSet { if newValue != isVisible { visibilityWillChange?(newValue) } }
    }
    // Each conversation remembers its layout; the saved split width stays intact.
    var isFullscreen: Bool { session?.isFullscreen == true }
    var isConversationPresented: Bool { !isFullscreen || session?.isConversationSelected == true || session == nil }
    private(set) var isWindowPresented = true
    private(set) var isWorkspacePresented = true
    var width: CGFloat = 480
    var showsBrowser: Bool { isVisible && !isConversationSelected && session?.activePanel == .files && !isChoosingPanel }
    private var isConversationSelected: Bool { isFullscreen && session?.isConversationSelected == true }
    var isChoosingPanel: Bool { !isConversationSelected && session?.isChoosingPanel == true }
    var isFileReaderSelected: Bool { !isConversationSelected && session?.activePanel == nil && !isChoosingPanel && selectedTab != nil }
    var sidebarTabs: [WorkspaceSidebarTab] {
        guard let session else { return [] }
        return (isFullscreen ? [.conversation] : []) + session.panels.map(WorkspaceSidebarTab.panel) + session.tabs.map { .file($0.id) }
    }
    var activeSidebarTab: WorkspaceSidebarTab? {
        if isConversationSelected { return .conversation }
        guard let session, !session.isChoosingPanel else { return nil }
        if let panel = session.activePanel { return .panel(panel) }
        return session.selectedTab.map { .file($0.id) }
    }
    var browserDirectory: URL?

    @ObservationIgnored private var sessions: [String: PreviewSession] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    private struct PendingOpen {
        let reference: FilePreviewReference
        let source: FilePreviewContext
        let owner: PreviewSession
        let pinned: Bool
        let request: Int
    }
    @ObservationIgnored private var pendingOpens: [PendingOpen] = []
    @ObservationIgnored private var pendingOpenIndex = 0
    @ObservationIgnored private var openTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var directoryCache: CachedPreviewDirectory?
    @ObservationIgnored private var watcher: PreviewFileWatch?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var didInteract = false
    @ObservationIgnored private var didResize = false
    @ObservationIgnored private var touchedSessions = Set<String>()
    @ObservationIgnored private var touchedFullscreenSessions = Set<String>()
    @ObservationIgnored private var isRestored = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private let persistenceURL: URL
    @ObservationIgnored private let opener: Opener
    @ObservationIgnored private let actionIdentity = UUID()
    @ObservationIgnored var visibilityWillChange: ((Bool) -> Void)?
    @ObservationIgnored weak var window: NSWindow?

    var selectedTab: PreviewTab? { session?.selectedTab }
    var context: FilePreviewContext? { session?.context }
    var action: FilePreviewAction {
        FilePreviewAction(identity: actionIdentity) { [weak self] reference, context, pinned in
            self?.open(reference, context: context, pinned: pinned) ?? false
        }
    }
    var toggleAction: FilePreviewToggleAction {
        FilePreviewToggleAction(identity: actionIdentity) { [weak self] in self?.toggle() }
    }
    var terminalAction: WorkspaceTerminalAction {
        WorkspaceTerminalAction(identity: actionIdentity) { [weak self] threadID, isOpen in
            guard let self, self.context?.threadID == threadID else { return false }
            if isOpen { self.openPanel(.terminal) }
            else { self.closeSidebarTab(.panel(.terminal)) }
            return true
        }
    }
    var reviewAction: WorkspaceReviewAction {
        WorkspaceReviewAction(identity: actionIdentity) { [weak self] threadID, turnID in
            guard let self, self.context?.threadID == threadID else { return false }
            self.session?.reviewTurnID = turnID
            self.session?.reviewRequest &+= 1
            self.openPanel(.review)
            return true
        }
    }

    init(persistenceURL: URL = StoragePaths.root.appendingPathComponent("file-previews.json"),
         opener: @escaping Opener = { reference, directory, readsContent, snapshot in
             try await PreviewFileLoader.open(reference, relativeTo: directory, readsContent: readsContent, reusing: snapshot)
         }) {
        self.persistenceURL = persistenceURL
        self.opener = opener
        let maximumPersistenceBytes = Self.maximumPersistenceBytes
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSynchronously() }
        }
        restoreTask = Task { [weak self] in
            let saved = await Task.detached(priority: .utility) {
                DiskWriter.shared.readSynchronously {
                    guard let handle = try? FileHandle(forReadingFrom: persistenceURL) else { return Optional<PersistedPreviews>.none }
                    defer { try? handle.close() }
                    guard let data = try? handle.read(upToCount: maximumPersistenceBytes), data.count < maximumPersistenceBytes else { return nil }
                    return try? JSONDecoder.storage.decode(PersistedPreviews.self, from: data)
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.restore(saved)
        }
    }

    isolated deinit {
        restoreTask?.cancel()
        loadTask?.cancel()
        saveTask?.cancel()
        for task in openTasks.values { task.cancel() }
        watcher?.stop()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func setContext(_ context: FilePreviewContext?) {
        let key = context.map(PreviewSession.key)
        guard key != session?.key else { return }
        if context?.workingDirectory != self.context?.workingDirectory { directoryCache = nil }
        cancelOpens()
        scheduleSave()
        stopReading()
        notice = nil
        browserDirectory = nil
        if let context, let key {
            let next = sessions[key] ?? PreviewSession(context: context)
            sessions[key] = next
            next.lastVisited = .now
            session = next
            next.isConversationSelected = next.isFullscreen
            if next.isFullscreen { isVisible = true }
            pruneSessions()
        } else {
            session = nil
        }
        if isVisible { loadSelected() }
    }

    @discardableResult
    func open(_ reference: FilePreviewReference, context source: FilePreviewContext? = nil, pinned: Bool = false) -> Bool {
        guard FilePreviewResolver.isLocalReference(reference.path), let owner = session else { return false }
        let source = source ?? owner.context
        didInteract = true
        if !isRestored { touchedSessions.insert(owner.key) }
        openGeneration &+= 1
        notice = nil
        hasPendingOpen = true
        owner.activePanel = nil
        owner.isChoosingPanel = false
        owner.isConversationSelected = false
        pendingOpens.append(PendingOpen(reference: reference, source: source, owner: owner,
                                        pinned: pinned, request: openGeneration))
        startQueuedOpens()
        isVisible = true
        return true
    }

    /// Tab count is unrestricted; only a bounded number of filesystem jobs run.
    /// Older clicks still create tabs, while the newest click owns activation.
    private func startQueuedOpens() {
        while openTasks.count < Self.maximumConcurrentOpens, pendingOpenIndex < pendingOpens.count {
            let pending = pendingOpens[pendingOpenIndex]
            pendingOpenIndex += 1
            let token = UUID()
            let openFile = opener
            let reusable = snapshot
            openTasks[token] = Task { [weak self] in
                let span = RuntimeMetrics.begin(.previewOpen)
                defer {
                    RuntimeMetrics.end(span)
                    self?.openTasks[token] = nil
                    if let self {
                        if self.openGeneration == pending.request { self.hasPendingOpen = false }
                        self.startQueuedOpens()
                    }
                }
                do {
                    let readsContent = !pending.pinned && self?.openGeneration == pending.request
                    let opened = try await openFile(pending.reference, pending.source.workingDirectory, readsContent, reusable)
                    guard !Task.isCancelled, let self else { return }
                    let owner = pending.owner
                    let activates = self.session === owner && pending.request == self.openGeneration
                    if opened.isDirectory {
                        if activates {
                            self.stopReading()
                            self.browserDirectory = opened.target.url
                            if !owner.panels.contains(.files) { owner.panels.append(.files) }
                            owner.activePanel = .files
                            owner.isChoosingPanel = false
                            self.scheduleSave()
                        }
                        return
                    }
                    self.insert(opened.target, source: pending.source, in: owner, pinned: true,
                                activates: activates, content: opened.content)
                } catch {
                    guard !Task.isCancelled, let self, self.session === pending.owner,
                          pending.request == self.openGeneration else { return }
                    self.notice = error.localizedDescription
                }
            }
        }
        if pendingOpenIndex == pendingOpens.count {
            pendingOpens.removeAll(keepingCapacity: true)
            pendingOpenIndex = 0
        }
    }

    func select(_ id: String) {
        guard let session, session.tabs.contains(where: { $0.id == id }), id != session.selectedID || !isFileReaderSelected || !openTasks.isEmpty else { return }
        didInteract = true
        if !isRestored { touchedSessions.insert(session.key) }
        let keepsReader = id == session.selectedID && isFileReaderSelected && snapshot?.url == session.selectedTab?.url
        let nextTab = session.tabs.first { $0.id == id }
        let keepsMarkdown = isFileReaderSelected && snapshot?.kind == .markdown && selectedTab?.reader.showsSource == false
            && nextTab?.reader.showsSource == false && nextTab.map { PreviewFileLoader.kind(for: $0.url) == .markdown } == true
        cancelOpens()
        session.activePanel = nil
        session.isChoosingPanel = false
        session.selectedID = id
        session.isConversationSelected = false
        notice = nil
        if !keepsReader { loadSelected(preservingContent: keepsMarkdown) }
        scheduleSave()
    }

    func pin(_ id: String) {
        guard let tab = session?.tabs.first(where: { $0.id == id }) else { return }
        didInteract = true
        if let session { if !isRestored { touchedSessions.insert(session.key) } }
        tab.isPinned = true
        scheduleSave()
    }

    func close(_ id: String) {
        guard let session, let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        didInteract = true
        if !isRestored { touchedSessions.insert(session.key) }
        cancelOpens()
        let wasSelected = session.selectedID == id
        session.tabs.remove(at: index)
        if wasSelected {
            session.selectedID = session.tabs.isEmpty ? nil : session.tabs[min(index, session.tabs.count - 1)].id
            if !collapseEmptySidebar() { loadSelected() }
        }
        scheduleSave()
    }

    func closeOthers(_ id: String) {
        guard let session, let tab = session.tabs.first(where: { $0.id == id }) else { return }
        didInteract = true
        if !isRestored { touchedSessions.insert(session.key) }
        cancelOpens()
        session.activePanel = nil
        session.isChoosingPanel = false
        session.isConversationSelected = false
        session.tabs = [tab]
        session.selectedID = id
        loadSelected()
        scheduleSave()
    }

    func closeAll() {
        guard let session else { return }
        didInteract = true
        if !isRestored { touchedSessions.insert(session.key) }
        cancelOpens()
        session.tabs.removeAll()
        session.selectedID = nil
        if !collapseEmptySidebar() { loadSelected() }
        scheduleSave()
    }

    func move(_ id: String, before destination: String) {
        guard let session, id != destination,
              let old = session.tabs.firstIndex(where: { $0.id == id }),
              session.tabs.contains(where: { $0.id == destination }) else { return }
        didInteract = true
        if !isRestored { touchedSessions.insert(session.key) }
        let tab = session.tabs.remove(at: old)
        guard let next = session.tabs.firstIndex(where: { $0.id == destination }) else { return }
        session.tabs.insert(tab, at: next)
        scheduleSave()
    }

    func selectNeighbor(_ offset: Int) {
        let tabs = sidebarTabs
        guard !tabs.isEmpty else { return }
        let current = activeSidebarTab.flatMap { tabs.firstIndex(of: $0) } ?? 0
        selectSidebarTab(tabs[(current + offset % tabs.count + tabs.count) % tabs.count])
    }

    func openPanel(_ panel: WorkspacePanel) {
        guard let session else { return }
        markSidebarInteraction()
        cancelOpens()
        stopReading()
        if !session.panels.contains(panel) { session.panels.append(panel) }
        session.activePanel = panel
        session.isChoosingPanel = false
        session.isConversationSelected = false
        notice = nil
        if panel == .files, browserDirectory == nil {
            browserDirectory = URL(fileURLWithPath: session.context.workingDirectory, isDirectory: true)
        }
        isVisible = true
        scheduleSave()
    }

    func selectSidebarTab(_ tab: WorkspaceSidebarTab) {
        switch tab {
        case .conversation:
            guard isFullscreen, let session else { return }
            markSidebarInteraction()
            cancelOpens()
            stopReading()
            session.isConversationSelected = true
        case .panel(let panel): openPanel(panel)
        case .file(let path): select(path)
        }
    }

    func togglePanelPicker() {
        guard let session else { return }
        markSidebarInteraction()
        cancelOpens()
        session.isChoosingPanel = isConversationSelected || !session.isChoosingPanel || sidebarTabs.isEmpty
        session.isConversationSelected = false
        if session.isChoosingPanel { stopReading() } else { loadSelected() }
        scheduleSave()
    }

    func closeSidebarTab(_ tab: WorkspaceSidebarTab) {
        guard tab != .conversation, let session, let index = sidebarTabs.firstIndex(of: tab) else { return }
        let wasActive = activeSidebarTab == tab
        markSidebarInteraction()
        switch tab {
        case .conversation: return
        case .file(let path): close(path)
        case .panel(let panel):
            if panel == .browser { BrowserWorkspaceRegistry.shared.closePanel(for: session.context.threadID) }
            session.panels.removeAll { $0 == panel }
        }
        if !collapseEmptySidebar(), wasActive {
            selectSidebarTab(sidebarTabs[min(index, sidebarTabs.count - 1)])
        }
        scheduleSave()
    }

    func closeOtherSidebarTabs(_ kept: WorkspaceSidebarTab) {
        guard let session, sidebarTabs.contains(kept) else { return }
        if kept != .panel(.browser) { BrowserWorkspaceRegistry.shared.closePanel(for: session.context.threadID) }
        markSidebarInteraction()
        cancelOpens()
        switch kept {
        case .conversation:
            closeAllSidebarTabs()
        case .panel(let panel):
            session.tabs.removeAll()
            session.selectedID = nil
            session.panels = [panel]
        case .file(let path):
            session.tabs.removeAll { $0.id != path }
            session.panels.removeAll()
        }
        selectSidebarTab(kept)
        scheduleSave()
    }

    func closeAllSidebarTabs() {
        guard let session else { return }
        BrowserWorkspaceRegistry.shared.closePanel(for: session.context.threadID)
        markSidebarInteraction()
        cancelOpens()
        stopReading()
        session.tabs.removeAll()
        session.selectedID = nil
        session.panels.removeAll()
        session.activePanel = nil
        session.isChoosingPanel = true
        setVisible(false)
        scheduleSave()
    }

    @discardableResult
    private func collapseEmptySidebar() -> Bool {
        guard let session, session.panels.isEmpty && session.tabs.isEmpty else { return false }
        session.activePanel = nil
        session.isChoosingPanel = true
        setVisible(false)
        return true
    }

    private func markSidebarInteraction() {
        didInteract = true
        if let session, !isRestored { touchedSessions.insert(session.key) }
    }

    func toggle() {
        guard session != nil else { return }
        setVisible(!isVisible)
    }

    func setFullscreen(_ fullscreen: Bool) {
        guard let session else { return }
        if !isRestored { touchedFullscreenSessions.insert(session.key) }
        guard isFullscreen != fullscreen else { return }
        let resumesReader = !isVisible || isConversationSelected
        didInteract = true
        session.isFullscreen = fullscreen
        session.isConversationSelected = false
        if fullscreen { isVisible = true }
        if isVisible && resumesReader { loadSelected() }
        scheduleSave()
    }

    func setVisible(_ visible: Bool) {
        if !visible {
            if let session, !isRestored { touchedFullscreenSessions.insert(session.key) }
            session?.isFullscreen = false
            session?.isConversationSelected = false
        }
        didInteract = true
        isVisible = visible
        if visible { loadSelected() } else { cancelOpens(); stopReading() }
        scheduleSave()
    }

    func refresh() {
        renderRevision &+= 1
        loadSelected(preservingContent: true)
    }

    func find() {
        guard isFileReaderSelected, selectedTab?.reader.showsDiff != true else { return }
        selectedTab?.reader.findRequest &+= 1
    }

    func questionContext(includingSelection: Bool) -> FileQuestionContext? {
        guard isFileReaderSelected, let tab = selectedTab else { return nil }
        if includingSelection {
            guard !tab.reader.showsDiff, let snapshot, snapshot.url == tab.url, let text = snapshot.text,
                  snapshot.kind == .text || (snapshot.kind == .markdown && tab.reader.showsSource) else {
                notice = Chrome.localized("Show source and select text to add it to your question.")
                return nil
            }
            let saved = tab.reader.source
            guard let selection = FileQuestionContext.selection(path: tab.url.path, source: tab.origin, text: text,
                    range: NSRange(location: saved.selectionLocation, length: saved.selectionLength)) else {
                notice = Chrome.localized("Select source text to add it to your question.")
                return nil
            }
            return selection
        }
        return FileQuestionContext(path: tab.url.path, source: tab.origin,
                                   startLine: tab.location?.line, endLine: nil, selectedText: nil)
    }

    func chooseFiles(in window: NSWindow?) {
        guard let context else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: context.workingDirectory, isDirectory: true)
        panel.prompt = Chrome.localized("Open in preview")
        panel.message = Chrome.localized("Choose files to preview beside this chat.")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let self, let panel else { return }
            self.openFiles(panel.urls, context: context)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    func openFiles(_ urls: [URL], context: FilePreviewContext? = nil) {
        let local = urls.filter(\.isFileURL)
        for url in local { open(FilePreviewReference(path: url.path), context: context, pinned: true) }
    }

    func showFiles() {
        openPanel(.files)
    }

    /// One folder's bounded metadata may survive a browser remount. Every open
    /// still lists the folder asynchronously; no source/document cache or
    /// recursive workspace index is retained.
    func cachedDirectoryListing(at directory: URL, showHidden: Bool, context: FilePreviewContext) -> PreviewDirectoryListing? {
        guard let directoryCache, directoryCache.workingDirectory == context.workingDirectory,
              directoryCache.path == directory.standardizedFileURL.path,
              directoryCache.showHidden == showHidden else { return nil }
        return directoryCache.listing
    }

    func rememberDirectoryListing(_ listing: PreviewDirectoryListing, at directory: URL,
                                  showHidden: Bool, context: FilePreviewContext) {
        guard self.context == context, showsBrowser,
              directory.standardizedFileURL.path == (browserDirectory ?? URL(fileURLWithPath: context.workingDirectory, isDirectory: true)).standardizedFileURL.path else { return }
        directoryCache = CachedPreviewDirectory(workingDirectory: context.workingDirectory,
                                               path: directory.standardizedFileURL.path,
                                               showHidden: showHidden, listing: listing)
    }

    func forgetDirectoryListing(at directory: URL) {
        if directoryCache?.path == directory.standardizedFileURL.path { directoryCache = nil }
    }

    func setWidth(_ newWidth: CGFloat) {
        let bounded = min(1_200, max(400, newWidth))
        guard abs(bounded - width) > 0.5 else { return }
        didResize = true
        width = bounded
        scheduleSave()
    }

    /// The pane may be detached while hidden; release expensive readers and
    /// filesystem descriptors even when the SwiftUI store itself stays alive.
    func suspend() { cancelOpens(); stopReading(); session?.history.suspend(); session?.contextInspection.suspend(); scheduleSave() }

    func setWorkspacePresented(_ presented: Bool) {
        guard isWorkspacePresented != presented else { return }
        isWorkspacePresented = presented
        if presented && isWindowPresented && isVisible { loadSelected() }
        else if !presented { suspend() }
    }

    func windowHidden() {
        isWindowPresented = false
        suspend()
    }

    func windowPresented() {
        guard !isWindowPresented else { return }
        isWindowPresented = true
        if isVisible && isWorkspacePresented { loadSelected() }
    }

    func scheduleSave() {
        guard isRestored else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            DiskWriter.shared.encodeAndWrite(self.persisted(), to: self.persistenceURL)
        }
    }

    func saveSynchronously() {
        guard isRestored else { return }
        saveTask?.cancel()
        DiskWriter.shared.writeSynchronously(persisted(), to: persistenceURL)
    }

    private func insert(_ target: FilePreviewTarget, source: FilePreviewContext, in owner: PreviewSession,
                        pinned: Bool, activates: Bool, content: Result<PreviewFileSnapshot, FilePreviewError>?) {
        let id = target.url.path
        let tab: PreviewTab
        if let existing = owner.tabs.first(where: { $0.id == id }) {
            tab = existing
            if pinned { tab.isPinned = true }
        } else {
            tab = PreviewTab(url: target.url, origin: source, isPinned: true)
            owner.tabs.append(tab)
        }
        if activates {
            tab.location = target.location
            if target.location != nil {
                tab.reader.showsDiff = false
                tab.reader.navigationRequest &+= 1
                if ["md", "markdown", "mdown", "mkd", "mdx"].contains(tab.url.pathExtension.lowercased()) { tab.reader.showsSource = true }
            }
            owner.selectedID = id
            owner.activePanel = nil
            owner.isChoosingPanel = false
            if let content { present(content, for: tab) }
            else { loadSelected() }
        } else if owner.selectedID == nil {
            owner.selectedID = id
        }
        scheduleSave()
    }

    private func present(_ content: Result<PreviewFileSnapshot, FilePreviewError>, for tab: PreviewTab) {
        guard isVisible, isWindowPresented, isWorkspacePresented, isFileReaderSelected else { stopReading(); return }
        // Revalidate a prepared failure with a watcher already installed. A
        // missing file may have appeared before its error reached this actor.
        guard case .success(let loaded) = content else { loadSelected(); return }
        let keepsWatch = snapshot?.url == loaded.url && snapshot?.revision == loaded.revision && !isLoading && watcher != nil
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        // A valid current snapshot can be reused without remounting its native
        // reader or reopening its descriptors for a repeated file/line click.
        if !keepsWatch { watcher?.stop(); watcher = nil }
        if snapshot?.url != loaded.url || snapshot?.revision != loaded.revision { snapshot = loaded }
        error = nil
        isLoading = false
        if watcher == nil {
            watcher = PreviewFileWatch(url: tab.url, expectedRevision: snapshot?.revision) { [weak self] in self?.loadSelected(preservingContent: true) }
        }
    }

    private func loadSelected(preservingContent: Bool = false) {
        // Wait for persisted tabs before deciding that launch is empty. All
        // presentation paths, including restoration and context changes, share
        // this fallback; a prepared file open keeps its current presentation.
        if isRestored, isVisible, !hasPendingOpen, let session, !session.isChoosingPanel {
            if session.activePanel == nil && session.tabs.isEmpty {
                session.activePanel = session.panels.first
                session.isChoosingPanel = session.panels.isEmpty
            }
            if session.activePanel == .files {
                browserDirectory = browserDirectory ?? URL(fileURLWithPath: session.context.workingDirectory, isDirectory: true)
            }
        }
        loadTask?.cancel()
        watcher?.stop()
        watcher = nil
        generation &+= 1
        let requested = generation
        let previous = snapshot
        if !preservingContent { snapshot = nil }
        error = nil
        guard isVisible, isWindowPresented, isWorkspacePresented, isFileReaderSelected, let owner = session, let tab = owner.selectedTab else {
            isLoading = false
            snapshot = nil
            return
        }
        isLoading = true
        let target = FilePreviewTarget(url: tab.url, location: tab.location)
        watcher = PreviewFileWatch(url: tab.url) { [weak self] in self?.loadSelected(preservingContent: true) }
        loadTask = Task { [weak self, weak owner, weak tab] in
            do {
                let loaded = try await PreviewFileLoader.load(target)
                guard !Task.isCancelled, let self, self.generation == requested,
                      self.session === owner, self.selectedTab === tab else { return }
                // A directory event often concerns a neighbour. Keep the reader
                // mounted when the selected file's version did not change.
                if previous?.url != loaded.url || previous?.revision != loaded.revision || self.snapshot == nil {
                    self.snapshot = loaded
                }
                self.isLoading = false
                self.scheduleSave()
            } catch {
                guard !Task.isCancelled, let self, self.generation == requested,
                      self.session === owner, self.selectedTab === tab else { return }
                self.snapshot = nil
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func stopReading() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        watcher?.stop()
        watcher = nil
        snapshot = nil
        isLoading = false
        error = nil
    }

    private func cancelOpens() {
        openGeneration &+= 1
        hasPendingOpen = false
        for task in openTasks.values { task.cancel() }
        openTasks.removeAll()
        pendingOpens.removeAll()
        pendingOpenIndex = 0
    }

    private func pruneSessions() {
        let retired = sessions.values.filter { $0 !== session }.sorted { $0.lastVisited < $1.lastVisited }
        for old in retired.prefix(max(0, sessions.count - Self.maximumSessions)) { sessions[old.key] = nil }
    }

    private func restore(_ saved: PersistedPreviews?) {
        defer {
            isRestored = true
            touchedSessions.removeAll()
            touchedFullscreenSessions.removeAll()
            if isVisible { loadSelected() }
            scheduleSave()
        }
        guard let saved, saved.version == 1 else { return }
        if !didResize, saved.width.isFinite { width = CGFloat(min(1_200, max(400, saved.width))) }
        for value in saved.sessions.prefix(Self.maximumSessions) {
            guard !value.context.workingDirectory.isEmpty else { continue }
            let key = PreviewSession.key(value.context)
            let restored = sessions[key] ?? PreviewSession(context: value.context)
            if !touchedFullscreenSessions.contains(key) { restored.isFullscreen = value.isFullscreen == true }
            if touchedSessions.contains(key) { continue }
            // A click made while disk restoration was under way takes precedence.
            if !restored.tabs.isEmpty { continue }
            var seen = Set<String>()
            for item in value.tabs where item.url.isFileURL && seen.insert(item.url.path).inserted {
                restored.tabs.append(PreviewTab(url: item.url, origin: item.origin, isPinned: true, reader: PreviewReaderState(snapshot: item.reader)))
            }
            restored.selectedID = restored.tabs.contains(where: { $0.id == value.selectedID }) ? value.selectedID : restored.tabs.first?.id
            if let panels = value.panels {
                var seenPanels = Set<WorkspacePanel>()
                restored.panels = panels.compactMap(WorkspacePanel.init(rawValue:)).filter { seenPanels.insert($0).inserted }
                restored.activePanel = value.activePanel.flatMap(WorkspacePanel.init(rawValue:)).flatMap { restored.panels.contains($0) ? $0 : nil }
                restored.isChoosingPanel = value.isChoosingPanel == true || (restored.panels.isEmpty && restored.tabs.isEmpty)
                restored.reviewSelection = value.reviewAllChanges == true ? .all
                    : value.reviewTurnID.map(PreviewSession.ReviewSelection.turn) ?? .latest
            } else {
                restored.activePanel = restored.tabs.isEmpty ? .files : nil
            }
            restored.lastVisited = value.lastVisited
            sessions[key] = restored
        }
        if let current = session, let kept = sessions[current.key] { session = kept }
        if !didInteract { isVisible = saved.isVisible }
        if isFullscreen {
            isVisible = true
            if let session, !touchedSessions.contains(session.key), !touchedFullscreenSessions.contains(session.key) {
                session.isConversationSelected = true
            }
        }
        pruneSessions()
    }

    private func persisted() -> PersistedPreviews {
        let kept = sessions.values.sorted { $0.lastVisited > $1.lastVisited }.prefix(Self.maximumSessions)
        return PersistedPreviews(version: 1, width: Double(width), isVisible: isVisible, sessions: kept.map { item in
            PersistedSession(context: item.context, lastVisited: item.lastVisited, selectedID: item.selectedID, tabs: item.tabs.map {
                PersistedTab(url: $0.url, origin: $0.origin, isPinned: $0.isPinned, reader: $0.reader.snapshot)
            }, panels: item.panels.map(\.rawValue), activePanel: item.activePanel?.rawValue,
               isChoosingPanel: item.isChoosingPanel, reviewTurnID: item.reviewTurnID,
               reviewAllChanges: item.reviewSelection == .all, isFullscreen: item.isFullscreen)
        })
    }
}

private struct CachedPreviewDirectory {
    let workingDirectory: String
    let path: String
    let showHidden: Bool
    let listing: PreviewDirectoryListing
}

private struct PersistedPreviews: Codable, Sendable {
    let version: Int
    let width: Double
    let isVisible: Bool
    let sessions: [PersistedSession]
}

private struct PersistedSession: Codable, Sendable {
    let context: FilePreviewContext
    let lastVisited: Date
    let selectedID: String?
    let tabs: [PersistedTab]
    let panels: [String]?
    let activePanel: String?
    let isChoosingPanel: Bool?
    let reviewTurnID: UUID?
    let reviewAllChanges: Bool?
    let isFullscreen: Bool?
}

private struct PersistedTab: Codable, Sendable {
    let url: URL
    let origin: FilePreviewContext
    let isPinned: Bool
    let reader: PreviewReaderState.Snapshot
}
