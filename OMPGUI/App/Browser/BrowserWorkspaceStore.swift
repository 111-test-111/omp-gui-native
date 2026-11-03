import AppKit
import CefSwiftUI
import Observation

@MainActor @Observable
final class BrowserPage: Identifiable {
    let id: UUID
    private(set) var record: BrowserPageRecord
    let model: CefWebViewModel
    let favicon: BrowserFaviconState
    private(set) var targetID: String?
    var error: String?
    var notice: String?
    var dialog: CefJSDialog?
    var isBeforeUnload = false
    var promptText = ""
    var showsFind = false
    var findText = ""
    var searchText = ""
    var addressFocus = 0
    var isPresented = false
    var downloads: [CefDownload] = []
    private(set) var downloadErrors: [UInt32: String] = [:]
    @ObservationIgnored private var quarantinedDownloadIDs: Set<UInt32> = []
    @ObservationIgnored private var dialogCallback: CefJSDialogCallback?
    @ObservationIgnored private var identityTask: Task<Void, Never>?
    @ObservationIgnored private(set) var host: CefBrowserHostView?
    @ObservationIgnored weak var owner: BrowserWorkspaceStore?
    @ObservationIgnored private var isDisposing = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var initialURL: URL
    @ObservationIgnored private var historyNavigation = BrowserHistoryNavigation()
    @ObservationIgnored private var historyTitle = ""
    @ObservationIgnored private var historyIcon: BrowserHistoryIcon?

    var title: String {
        if BrowserAddress.isBlankPage(record.url) { return BrowserLocalization.localized("New browser tab") }
        if !record.title.isEmpty, !BrowserAddress.isBlankPage(record.title) { return record.title }
        return URL(string: record.url)?.host ?? BrowserLocalization.localized("New browser tab")
    }
    var url: String { record.url }
    var isLoading: Bool { !BrowserAddress.isBlankPage(url) && model.isLoading }

    init(record: BrowserPageRecord, owner workspace: BrowserWorkspaceStore) {
        self.id = record.id
        self.record = record
        self.owner = workspace
        initialURL = Self.bootstrapURL()
        let viewModel = CefWebViewModel(url: initialURL)
        model = viewModel
        favicon = BrowserFaviconState(profileID: BrowserProfileConfiguration.activeProfile.id) { [weak viewModel] url, bypass, completion in
            guard let browser = viewModel?.browser, !browser.isClosed else { completion(nil); return }
            browser.downloadFavicon(url, bypassCache: bypass) { image in
                completion(image.map(AdaptiveIconImage.prepared))
            }
        }
        favicon.onImageLoaded = { [weak self] document, image in
            guard let self, acceptsFaviconUpdates, owner?.isShuttingDown != true,
                  let visit = historyNavigation.visit, BrowserFaviconState.documentURL(for: visit.url) == document,
                  let icon = BrowserHistoryIconCodec.encode(image), icon != historyIcon else { return }
            historyIcon = icon
            owner?.history.updateIcon(icon, visitID: visit.id)
        }
        favicon.navigate(to: record.url)
        model.onFaviconChanged = { [weak self] urls in
            guard let self, acceptsFaviconUpdates else { return }
            favicon.receive(urls)
        }
        model.onMainFrameLoadStarted = { [weak self] in
            guard let self, acceptsFaviconUpdates else { return }
            favicon.startedLoading()
        }
        model.onLoadingChanged = { [weak self] loading in
            guard let self, !loading, acceptsFaviconUpdates else { return }
            favicon.finishedLoading()
            updateHistoryTitle(model.title)
        }
        model.onBrowserCreated = { [weak self] browser in self?.created(browser) }
        model.onBrowserClosed = { [weak self] in
            guard let self else { return }
            let expectedGeneration = generation
            // Do not release the CEF client inside on_before_close.
            Task { @MainActor [weak self] in
                guard let self, !isDisposing, generation == expectedGeneration else { return }
                owner?.didClose(id)
            }
        }
        model.onURLChanged = { [weak self] url in
            guard let self, !isDisposing, owner?.isShuttingDown != true,
                  targetID != nil, let url, !BrowserAddress.isBootstrapURL(url) else { return }
            recordURL(url.absoluteString)
            if let visit = historyNavigation.navigate(to: url.absoluteString) {
                historyTitle = ""
                historyIcon = nil
                owner?.history.record(visit)
            }
            // History API updates can change the address without loading a
            // new document or causing another native favicon notification.
            if !model.isLoading, acceptsFaviconUpdates {
                favicon.receive(model.faviconURL.map { [$0] } ?? [])
                updateHistoryTitle(model.title)
            }
        }
        model.onTitleChanged = { [weak self] title in
            guard let self, !isDisposing, owner?.isShuttingDown != true,
                  targetID != nil, !BrowserAddress.isBlankPage(self.url),
                  !BrowserAddress.isBlankPage(title),
                  model.url.map({ !BrowserAddress.isBootstrapURL($0) }) == true else { return }
            let title = String(title.prefix(512))
            updateHistoryTitle(title)
            guard record.title != title else { return }
            self.record.title = title; owner?.changed()
        }
        model.onLoadError = { [weak self] code, text, _ in
            guard let self, !isDisposing, code != -3 else { return } // A replaced/canceled navigation.
            error = String(format: BrowserLocalization.localized("The page could not load: %@"), text)
        }
        model.onRendererTerminated = { [weak self] in
            guard let self, !isDisposing else { return }
            error = BrowserLocalization.localized("The browser page stopped responding. Reload to recover it.")
        }
        model.onNavigation = { [weak self] url in
            guard BrowserAddress.allowsPageNavigation(url) else {
                self?.notice = BrowserLocalization.localized("This link uses a protocol that the embedded browser does not open.")
                return .cancel
            }
            return .allow
        }
        model.onWindowOpen = { [weak self] request in
            guard let self, let url = request.targetURL, BrowserAddress.resolve(url.absoluteString) != nil else { return .deny }
            guard request.userGesture else {
                notice = BrowserLocalization.localized("A popup was blocked. Open the link directly to continue.")
                return .deny
            }
            // Creating native browsers inside CEF's popup callback is reentrant.
            Task { @MainActor [weak self] in
                guard let self, !isDisposing, let owner else { return }
                do { _ = try owner.open(url: url, select: request.disposition != .newBackgroundTab) }
                catch { self.notice = error.localizedDescription }
            }
            return .handled
        }
        model.onDialog = { [weak self] dialog, callback in
            guard let self, !isDisposing else { callback.cancel(); return }
            self.dialog = dialog; dialogCallback = callback
            isBeforeUnload = false; promptText = dialog.defaultPromptText
        }
        model.onBeforeUnload = { [weak self] message, _, callback in
            guard let self, !isDisposing else { callback.continue(success: true); return }
            dialog = CefJSDialog(kind: .confirm, message: message, origin: self.record.url)
            isBeforeUnload = true; dialogCallback = callback
        }
        model.onDialogClosed = { [weak self] in self?.clearDialog() }
        model.onPermission = { [weak self] _ in
            self?.notice = BrowserLocalization.localized("This site requested a device permission. Use the default browser for camera, microphone or location access.")
            return .deny
        }
        model.onFocusRequested = { [weak self] in self?.isPresented != true }
        model.onDownloadDecision = { [weak self] _, suggested in
            guard let self, let owner else { return .deny }
            do {
                let folder = owner.downloadDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = (suggested as NSString).lastPathComponent
                return .allow(destination: folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "download" : name))
            } catch { notice = error.localizedDescription; return .deny }
        }
        model.onDownloadProgress = { [weak self] item in
            guard let self, !isDisposing else { return }
            if item.isComplete, let file = item.fullPath,
               !quarantinedDownloadIDs.contains(item.id), downloadErrors[item.id] == nil {
                do {
                    try BrowserDownloadQuarantine.mark(file)
                    quarantinedDownloadIDs.insert(item.id)
                } catch {
                    downloadErrors[item.id] = error.localizedDescription
                    notice = error.localizedDescription
                }
            }
            if let index = downloads.firstIndex(where: { $0.id == item.id }) { downloads[index] = item }
            else {
                if downloads.count == 50 {
                    let removed = downloads.removeFirst()
                    quarantinedDownloadIDs.remove(removed.id)
                    downloadErrors.removeValue(forKey: removed.id)
                }
                downloads.append(item)
            }
        }
    }

    private var acceptsFaviconUpdates: Bool {
        !isDisposing && targetID != nil && !BrowserAddress.isBlankPage(url)
            && model.browser?.url?.absoluteString == url
    }

    func materialize() throws {
        guard owner?.isShuttingDown != true else { throw WorkspaceBrowserError.closed }
        guard host == nil, !isDisposing else { return }
        guard BrowserWorkspaceRegistry.shared.livePageCount < 64 else { throw WorkspaceBrowserError.limit }
        try EmbeddedBrowserRuntime.shared.start()
        guard !isDisposing, owner?.isShuttingDown != true else { throw WorkspaceBrowserError.closed }
        generation &+= 1
        model.options.runtimeStyle = .alloy
        model.options.profile = EmbeddedBrowserRuntime.shared.browsingProfile()
        let host = CefBrowserHostView(model: model)
        host.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        self.host = host
        EmbeddedBrowserRuntime.shared.park(host)
        host.layoutSubtreeIfNeeded()
    }

    private func created(_ browser: CefBrowser) {
        guard !isDisposing else { browser.close(force: true); return }
        guard !browser.isClosed else { error = WorkspaceBrowserError.unavailable.localizedDescription; return }
        browser.setAccessibilityEnabled(true)
        identityTask?.cancel()
        identityTask = Task { [weak self] in
            guard let self else { return }
            do {
                let target = try await EmbeddedBrowserRuntime.shared.identifyPage(initialURL: initialURL)
                try Task.checkCancellation()
                guard !isDisposing, model.browser === browser else { return }
                targetID = target
                // The discovery document already is an empty page. Navigating
                // it to another about:blank flashes its title/loading UI and
                // creates a redundant history entry. Keep it until real navigation.
                if !BrowserAddress.isBlankPage(record.url), let url = URL(string: record.url) { model.load(url) }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func navigate(_ input: String) {
        guard !isDisposing else { return }
        guard let url = BrowserAddress.resolve(input) else { error = WorkspaceBrowserError.invalidAddress.localizedDescription; return }
        error = nil; notice = nil
        recordURL(url.absoluteString)
        if targetID != nil { model.load(url) }
    }

    @discardableResult
    func submitAddress(_ input: String, using engine: BrowserSearchEngine) -> Bool {
        switch BrowserOmnibox.classify(input) {
        case .empty: return false
        case .navigate(let url): navigate(url.absoluteString); return true
        case .search(let query): return search(query, using: engine)
        case .invalid:
            error = BrowserLocalization.localized("Enter a valid web address or search query.")
            return false
        }
    }

    @discardableResult
    func search(_ input: String, using engine: BrowserSearchEngine) -> Bool {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let url = engine.searchURL(for: input) else {
            error = BrowserLocalization.localized("Enter a shorter search query.")
            return false
        }
        navigate(url.absoluteString)
        return true
    }

    private func recordURL(_ value: String) {
        favicon.navigate(to: value)
        record.url = value; owner?.changed()
    }

    private func updateHistoryTitle(_ value: String) {
        let title = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !isDisposing, owner?.isShuttingDown != true, !title.isEmpty, title != historyTitle,
              !BrowserAddress.isBlankPage(title), let visit = historyNavigation.visit,
              visit.url == model.url?.absoluteString, visit.url == url else { return }
        historyTitle = title
        owner?.history.updateTitle(title, visitID: visit.id)
    }

    func reload() {
        guard owner?.isShuttingDown != true else { return }
        error = nil
        favicon.reload()
        if targetID == nil {
            // Failed startup/discovery gets a fresh target, never a sibling.
            dispose()
            isDisposing = false
            initialURL = Self.bootstrapURL()
            model.url = initialURL
            do { try materialize() } catch { self.error = error.localizedDescription }
        } else { model.reload() }
    }

    func answerDialog(_ accepted: Bool) {
        let callback = dialogCallback
        let text = promptText
        clearDialog()
        callback?.continue(success: accepted, userInput: accepted ? text : nil)
    }

    private func clearDialog() { dialog = nil; dialogCallback = nil; isBeforeUnload = false; promptText = "" }

    func prepareForDisplay() throws {
        guard !BrowserAddress.isBlankPage(url) else { return }
        try materialize()
    }

    func requestClose() {
        if let browser = model.browser { browser.close(force: false) }
        else { owner?.didClose(id) }
    }

    @discardableResult func dispose() -> CefBrowser? {
        generation &+= 1
        isDisposing = true
        isPresented = false
        favicon.reset()
        identityTask?.cancel(); identityTask = nil
        targetID = nil
        let browser = model.browser
        browser?.closeDevTools()
        browser?.close(force: true)
        clearDialog()
        host?.tearDown()
        host?.removeFromSuperview(); host = nil
        model.options.profile = nil
        return browser
    }

    private static func bootstrapURL() -> URL {
        // Chromium canonicalizes about: URLs; use the same lowercase spelling
        // for exact CDP discovery and never persist these internal addresses.
        URL(string: "about:blank#omp-gui-" + UUID().uuidString.lowercased())!
    }

    func attachment() async throws -> JSONValue {
        try materialize()
        let deadline = ContinuousClock.now + .seconds(15)
        while targetID == nil, error == nil, !isDisposing, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard owner?.pages.contains(where: { $0 === self }) == true, !isDisposing else { throw WorkspaceBrowserError.closed }
        guard let targetID, let endpoint = EmbeddedBrowserRuntime.shared.endpoint else { throw WorkspaceBrowserError.connection }
        return .object(["id": .string(id.uuidString), "title": .string(title), "url": .string(url),
            "open": BrowserAutomationAttachment.openOptions(pageID: id, targetID: targetID,
                endpoint: endpoint, downloads: owner?.downloadDirectory.path ?? "")])
    }
}

@MainActor @Observable
final class BrowserWorkspaceStore {
    let threadID: UUID
    let history: BrowserHistoryStore
    private(set) var pages: [BrowserPage] = []
    var selectedID: UUID? { didSet { if oldValue != selectedID { changed() } } }
    var error: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private(set) var isShuttingDown = false
    var selectedPage: BrowserPage? { pages.first { $0.id == selectedID } }
    var record: BrowserWorkspaceRecord { BrowserWorkspaceRecord(pages: pages.map(\.record), selectedID: selectedID) }
    var downloadDirectory: URL { StoragePaths.directory("browser/downloads").appendingPathComponent(threadID.uuidString, isDirectory: true) }

    init(threadID: UUID, record: BrowserWorkspaceRecord = .init(), history: BrowserHistoryStore = .shared) {
        self.threadID = threadID
        self.history = history
        var ids = Set<UUID>()
        pages = record.pages.prefix(16).filter { ids.insert($0.id).inserted }.map {
            var page = $0
            page.url = BrowserAddress.restoredURL(page.url)
            page.title = String(page.title.prefix(512))
            return BrowserPage(record: page, owner: self)
        }
        selectedID = pages.contains(where: { $0.id == record.selectedID }) ? record.selectedID : pages.first?.id
    }

    @discardableResult func open(url: URL = URL(string: "about:blank")!, select: Bool = true, materialize: Bool = true) throws -> BrowserPage {
        guard !isShuttingDown else { throw WorkspaceBrowserError.closed }
        guard pages.count < 16 else { throw WorkspaceBrowserError.limit }
        guard BrowserAddress.resolve(url.absoluteString) != nil else { throw WorkspaceBrowserError.invalidAddress }
        let page = BrowserPage(record: BrowserPageRecord(url: url.absoluteString), owner: self)
        pages.append(page)
        do { if materialize { try page.prepareForDisplay() } }
        catch { pages.removeAll { $0 === page }; throw error }
        if select || selectedID == nil { selectedID = page.id }
        changed()
        return page
    }

    func activate() {
        guard !isShuttingDown else { return }
        do {
            if pages.isEmpty { _ = try open() }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func didClose(_ id: UUID) {
        guard !isShuttingDown else { return }
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].dispose()
        pages.remove(at: index)
        if selectedID == id { selectedID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id }
        changed()
    }

    @discardableResult func closeAll() -> [CefBrowser] {
        guard !isShuttingDown else { return [] }
        let closing = pages.compactMap { $0.dispose() }
        pages.removeAll(); selectedID = nil
        changed()
        return closing
    }

    func prepareForShutdown() -> [CefBrowser] {
        isShuttingDown = true
        onChange = nil
        // Keep the selected tab and native sidebar layout while AppKit awaits
        // the quit reply. Closing the app is not the user's Close Panel action.
        return pages.compactMap { $0.dispose() }
    }

    func changed() { onChange?() }
}

/// One owner per conversation even when it is moved between native windows.
/// Stores own stable hosts; representable teardown only parks those hosts.
@MainActor
final class BrowserWorkspaceRegistry {
    static let shared = BrowserWorkspaceRegistry()
    private var workspaces: [UUID: BrowserWorkspaceStore] = [:]
    private var saved: [String: BrowserWorkspaceRecord] = [:]
    private var saveTask: Task<Void, Never>?
    private var isShuttingDown = false
    private let persistenceURL: URL
    var livePageCount: Int { workspaces.values.flatMap(\.pages).filter { $0.host != nil }.count }

    init(persistenceURL: URL = StoragePaths.root.appendingPathComponent("browser-tabs.json")) {
        self.persistenceURL = persistenceURL
        if let handle = try? FileHandle(forReadingFrom: persistenceURL) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 {
                saved = (try? JSONDecoder().decode([String: BrowserWorkspaceRecord].self, from: data)) ?? [:]
            }
        }
    }

    func workspace(for id: UUID) -> BrowserWorkspaceStore {
        if let workspace = workspaces[id] { return workspace }
        let workspace = BrowserWorkspaceStore(threadID: id, record: saved[id.uuidString] ?? .init())
        if isShuttingDown { _ = workspace.prepareForShutdown() }
        else { workspace.onChange = { [weak self] in self?.scheduleSave() } }
        workspaces[id] = workspace
        return workspace
    }

    func closePanel(for id: UUID) {
        guard !isShuttingDown else { return }
        workspaces[id]?.closeAll(); saved[id.uuidString] = nil; scheduleSave()
    }
    func remove(_ id: UUID) {
        guard !isShuttingDown else { return }
        closePanel(for: id); workspaces[id] = nil
    }

    private func scheduleSave() {
        guard !isShuttingDown else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel(); saveTask = nil
        for (id, workspace) in workspaces { saved[id.uuidString] = workspace.pages.isEmpty ? nil : workspace.record }
        guard let data = try? JSONEncoder().encode(saved), data.count <= 1_048_576 else { return }
        DiskWriter.shared.encodeAndWrite(saved, to: persistenceURL)
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        save()
        DiskWriter.shared.writeSynchronously(saved, to: persistenceURL)
        let closing = workspaces.values.flatMap { $0.prepareForShutdown() }
        await BrowserHistoryStore.shared.flush()
        let importDrained = await BrowserCookieImporter.shared.shutdown()
        let deadline = ContinuousClock.now + .seconds(5)
        while closing.contains(where: { !$0.isClosed }) {
            // A failed helper must not make Quit wait forever. In this rare
            // case let process termination dispose CEF; calling cef_shutdown
            // with live clients is unsafe. Normal shutdown remains observed.
            guard ContinuousClock.now < deadline else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        // An import host has the same on_before_close requirement as user pages.
        // On timeout, process termination must dispose CEF instead of cef_shutdown.
        guard importDrained else { return }
        await Task.yield()
        EmbeddedBrowserRuntime.shared.shutdown()
    }
}
