import Foundation
import Observation

/// The mounted Git page retains bounded snapshots beside session navigation. Only a
/// presented Git panel owns reads and filesystem observations, independently of
/// OMP's connection or the conversation's turn-attribution diff.
@MainActor @Observable
final class GitWorkspaceStore {
    typealias WatchFactory = @MainActor (GitRepositoryLocation, @escaping @MainActor () -> Void) -> GitRepositoryWatch?
    private(set) var context: FilePreviewContext?
    private(set) var location: GitRepositoryLocation?
    private(set) var status: GitWorkspaceStatus?
    private(set) var source: GitHistorySource?
    private(set) var referenceLabels: [String: [GitHistoryReference]] = [:]
    private(set) var commits: [GitBrowseCommit] = []
    private(set) var graph = GitCommitGraph.empty
    private(set) var details: GitCommitDetails?
    private(set) var diff: DiffFile?
    /// Navigation can request a child before its first read finishes. Keep the
    /// accepted parent on screen until the child's complete snapshot is ready.
    private(set) var displayedRoute: GitBrowseRoute?
    private(set) var workspaceStatistics: GitWorkspaceStatistics?
    private(set) var isStatisticsLoading = false
    private(set) var statisticsError: String?
    let navigation: GitBrowseNavigation
    private(set) var mode: GitBrowseMode { get { navigation.mode } set { navigation.mode = newValue } }
    private(set) var group: GitChangeGroup { get { navigation.group } set { navigation.group = newValue } }
    private(set) var historyReference: String? { get { navigation.historyReference } set { navigation.historyReference = newValue } }
    private(set) var routes: [GitBrowseRoute] { get { navigation.routes } set { navigation.routes = newValue } }
    private(set) var selectedParent: String? { get { navigation.selectedParent } set { navigation.selectedParent = newValue } }
    private(set) var isPresented = false
    private(set) var isLoading = false
    private(set) var isHistoryLoading = false
    private(set) var isSelectionLoading = false
    private(set) var isNotRepository = false
    private(set) var hasMoreHistory = false
    private(set) var automaticRefreshAvailable = true
    private(set) var error: String?
    private(set) var historyError: String?
    private(set) var selectionError: String?
    var query: String { get { navigation.query } set { navigation.query = newValue } }
    var historyAnchor: String? { get { navigation.historyAnchor } set { navigation.historyAnchor = newValue } }
    var graphOffset: CGFloat { get { navigation.graphOffset } set { navigation.graphOffset = newValue } }
    var showsSearch: Bool { get { navigation.showsSearch } set { navigation.showsSearch = newValue } }
    var commitMessage: String { get { navigation.commitMessage } set { navigation.commitMessage = newValue } }
    var commitReview: GitCommitReview? { navigation.commitReview }
    var isWriting: Bool { navigation.isWriting }
    private(set) var isGeneratingMessage = false

    @ObservationIgnored private let reader: GitWorkspaceReading
    @ObservationIgnored private let writer: GitWorkspaceWriting
    @ObservationIgnored private let watchFactory: WatchFactory
    @ObservationIgnored private var watcher: GitRepositoryWatch?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsTask: Task<Void, Never>?
    @ObservationIgnored private var statisticsInputs: GitStatisticsInputs?
    @ObservationIgnored private var statisticsGeneration = 0
    // Compare the reader's original result, so a silent refresh also preserves
    // an explicitly expanded deferred diff and its native reading position.
    @ObservationIgnored private var lastReadDiff: DiffFile?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var historyGeneration = 0
    @ObservationIgnored private var historyNeedsReload = false
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var acceptsReviewOnRefresh = false
    private var needsResumeValidation = false
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var messageGeneration = 0

    init(navigation: GitBrowseNavigation = GitBrowseNavigation(), reader: GitWorkspaceReading = .live,
         writer: GitWorkspaceWriting = .live,
         watchFactory: @escaping WatchFactory = { GitRepositoryWatch(location: $0, onChange: $1) }) {
        self.navigation = navigation
        self.reader = reader
        self.writer = writer
        self.watchFactory = watchFactory
    }

    isolated deinit {
        refreshTask?.cancel(); historyTask?.cancel(); selectionTask?.cancel(); statisticsTask?.cancel(); messageTask?.cancel(); watcher?.stop()
    }

    var route: GitBrowseRoute? { routes.last }
    var reachedHistoryLimit: Bool { commits.count >= GitWorkspaceReader.maximumCommits && hasMoreHistory }
    var filteredFiles: [GitBrowseFile] {
        (status?.files(in: group) ?? []).filter { matches($0.path) }
    }
    var historyMatches: [String] {
        commits.filter { query.isEmpty || matches($0.subject + " " + $0.author + " " + $0.id) }.map(\.id)
    }

    func matches(_ text: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || text.localizedStandardContains(query)
    }

    func present(_ next: FilePreviewContext?) {
        guard let next else { suspend(); return }
        guard !isPresented || context != next else { return }
        let changed = context != nil && context != next
        suspend(keepingContent: !changed)
        if changed { clearRepository(); routes = []; historyReference = nil; selectedParent = nil; query = "" }
        context = next
        isPresented = true
        refresh()
    }

    func suspend(keepingContent: Bool = false) {
        generation &+= 1; historyGeneration &+= 1; selectionGeneration &+= 1
        refreshTask?.cancel(); refreshTask = nil
        historyTask?.cancel(); historyTask = nil
        selectionTask?.cancel(); selectionTask = nil
        cancelStatistics(keepingValues: keepingContent)
        cancelMessageGeneration()
        watcher?.stop(); watcher = nil
        pendingRefresh = false
        isPresented = false
        isLoading = false; isHistoryLoading = false; isSelectionLoading = false
        needsResumeValidation = true
        if !keepingContent {
            diff = nil; lastReadDiff = nil; details = nil; selectionError = nil; displayedRoute = nil
        }
    }

    private func clearRepository() {
        cancelStatistics()
        location = nil; status = nil; source = nil; commits = []; graph = .empty
        historyNeedsReload = false
        details = nil; diff = nil; lastReadDiff = nil; hasMoreHistory = false; referenceLabels = [:]
        displayedRoute = nil
        error = nil; historyError = nil; selectionError = nil
    }

    func refresh() {
        guard isPresented, let context else { return }
        guard !isWriting else { pendingRefresh = true; return }
        // A filesystem burst joins the current refresh. Its results are withheld
        // and one further read follows, rather than publishing an invalidated read.
        guard refreshTask == nil else { pendingRefresh = true; return }
        generation &+= 1
        let token = generation
        cancelStatistics(keepingValues: true)
        historyGeneration &+= 1; historyTask?.cancel(); historyTask = nil; isHistoryLoading = false
        cancelSelection(keepingContent: true)
        isLoading = true
        refreshTask = Task { [weak self, reader] in
            guard let self else { return }
            do {
                let located = try await reader.locate(context.workingDirectory)
                guard owns(token, context) else { return }
                guard let located else {
                    clearRepository(); isNotRepository = true
                    watcher?.stop(); watcher = nil
                    finishRefresh(token, context)
                    return
                }
                if location != located {
                    let changed = navigation.repositoryKey != nil && navigation.repositoryKey != located.gitDirectory.path
                    clearRepository()
                    watcher?.stop(); watcher = nil
                    if changed {
                        routes = []; selectedParent = nil; historyAnchor = nil; graphOffset = 0; historyReference = nil
                        navigation.commitReview = nil
                    }
                    navigation.repositoryKey = located.gitDirectory.path
                    location = located
                }
                isNotRepository = false
                if watcher == nil {
                    watcher = watchFactory(located) { [weak self] in self?.refresh() }
                    automaticRefreshAvailable = watcher?.isAvailable == true
                }
                let status = try await reader.status(located)
                let source = try await reader.source(located, status.head)
                guard owns(token, context), !pendingRefresh else { finishRefresh(token, context); return }
                error = nil
                if self.status != status { self.status = status }
                needsResumeValidation = false
                cancelStatistics(keepingValues: true)
                loadStatistics()
                if acceptsReviewOnRefresh {
                    acceptsReviewOnRefresh = false
                    if routes.contains(.compose) { acceptCommitReview() }
                }
                if self.source != source {
                    self.source = source
                    referenceLabels = Dictionary(grouping: source.references, by: \.commit)
                    historyNeedsReload = true
                }
                if mode == .history, historyNeedsReload || commits.isEmpty || historyError != nil { loadMoreHistory() }
                loadSelection(keepingContent: true)
            } catch {
                guard owns(token, context) else { return }
                if !(error is CancellationError) {
                    clearRepository()
                    watcher?.stop(); watcher = nil
                    self.error = error.localizedDescription
                }
            }
            finishRefresh(token, context)
        }
    }

    private func owns(_ token: Int, _ context: FilePreviewContext) -> Bool {
        isPresented && generation == token && self.context == context && !Task.isCancelled
    }

    private func finishRefresh(_ token: Int, _ context: FilePreviewContext) {
        guard owns(token, context) else { return }
        refreshTask = nil
        isLoading = false
        if pendingRefresh { pendingRefresh = false; refresh() }
    }

    func show(_ next: GitBrowseMode) {
        guard mode != next else { return }
        cancelMessageGeneration()
        mode = next; routes = []; selectedParent = nil
        cancelSelection()
        if mode == .changes { loadStatistics() } else { cancelStatistics(keepingValues: true) }
        if mode == .history, historyNeedsReload || commits.isEmpty { loadMoreHistory() }
    }

    func chooseGroup(_ next: GitChangeGroup) { cancelMessageGeneration(); group = next; routes = []; cancelSelection() }

    func beginSearch() {
        cancelMessageGeneration()
        routes = []; selectedParent = nil
        cancelSelection()
        showsSearch = true
    }

    func chooseReference(_ name: String?) {
        guard historyReference != name else { return }
        historyReference = name; routes = []; selectedParent = nil; historyAnchor = nil; graphOffset = 0
        navigation.historyCount = GitWorkspaceReader.pageSize
        historyNeedsReload = true
        historyGeneration &+= 1; historyTask?.cancel(); historyTask = nil; isHistoryLoading = false
        commits = []; graph = .empty; hasMoreHistory = false
        cancelSelection()
        loadMoreHistory()
    }

    func loadMoreHistory() {
        guard isPresented, let location, let source, !isHistoryLoading,
              historyNeedsReload || (commits.count < GitWorkspaceReader.maximumCommits && (commits.isEmpty || hasMoreHistory)) else { return }
        if let reference = historyReference, reference != "HEAD", !source.references.contains(where: { $0.name == reference }) {
            historyError = Bundle.main.localizedString(forKey: "This reference no longer exists. Choose another history scope.", value: nil, table: "Localizable")
            return
        }
        historyGeneration &+= 1
        let token = historyGeneration
        let tips = source.tips(for: historyReference)
        let before = historyNeedsReload ? [] : commits
        let requested = before.isEmpty ? max(GitWorkspaceReader.pageSize, navigation.historyCount) : GitWorkspaceReader.pageSize
        let count = min(requested, GitWorkspaceReader.maximumCommits - before.count)
        isHistoryLoading = true; historyError = nil
        historyTask = Task { [weak self, reader] in
            do {
                let page = try await reader.history(location, tips, before.count, count)
                let combined = before + page.commits
                let layoutTask = Task.detached(priority: .userInitiated) { try GitCommitGraph.build(combined) }
                let graph = try await withTaskCancellationHandler { try await layoutTask.value } onCancel: { layoutTask.cancel() }
                guard let self, isPresented, self.location == location, historyGeneration == token, !Task.isCancelled else { return }
                commits = combined; self.graph = graph; hasMoreHistory = page.hasMore
                historyNeedsReload = false
                navigation.historyCount = combined.count
                isHistoryLoading = false; historyTask = nil
            } catch {
                guard let self, isPresented, self.location == location, historyGeneration == token, !Task.isCancelled else { return }
                historyError = error.localizedDescription; isHistoryLoading = false; historyTask = nil
            }
        }
    }

    func openCommit(_ commit: GitBrowseCommit) {
        cancelMessageGeneration()
        historyAnchor = commit.id
        selectedParent = nil
        routes = [.commit(commit.id)]
        loadSelection(keepingContent: true)
    }

    func openFile(_ file: GitBrowseFile, replacingDetail: Bool = false, inComposer: Bool = false) {
        // Another row can be chosen while a first child is preparing. Replace
        // that pending child rather than appending a phantom navigation level.
        if replacingDetail {
            if file.side == .commit, let details { routes = [.commit(details.commit.id)] }
            else { routes = inComposer ? [.compose] : [] }
        } else if displayedRoute != route {
            if let displayedRoute, let index = routes.firstIndex(of: displayedRoute) {
                routes = Array(routes.prefix(through: index))
            } else { routes = [] }
        }
        if file.side == .commit { selectedParent = details?.parent }
        routes.append(.file(comparison(for: file)))
        loadSelection(keepingContent: true)
    }

    func comparison(for file: GitBrowseFile) -> GitFileComparison {
        .init(file: file, commit: file.side == .commit ? details?.commit.id : nil,
              parent: file.side == .commit ? details?.parent : nil)
    }

    func toggleInlineFile(_ file: GitBrowseFile, inComposer: Bool = false) {
        let child = GitBrowseRoute.file(comparison(for: file))
        if route == child || displayedRoute == child {
            // Collapse the accepted or pending comparison to its own parent,
            // including when another file read is already replacing it.
            if file.side == .commit, let details {
                selectedParent = details.parent
                routes = [.commit(details.commit.id)]
            }
            else { routes = inComposer ? [.compose] : [] }
            loadSelection(keepingContent: true)
        } else {
            openFile(file, replacingDetail: true, inComposer: inComposer)
        }
    }

    func statistics(for comparison: GitFileComparison) async throws -> GitLineStatistics {
        guard isPresented, let location else { throw CancellationError() }
        let value = try await reader.statistics(location, comparison)
        try Task.checkCancellation()
        guard isPresented, self.location == location else { throw CancellationError() }
        return value
    }

    private func cancelStatistics(keepingValues: Bool = false) {
        statisticsGeneration &+= 1
        statisticsTask?.cancel(); statisticsTask = nil
        if !keepingValues { workspaceStatistics = nil; statisticsInputs = nil; statisticsError = nil }
        isStatisticsLoading = false
    }

    private func loadStatistics() {
        guard isPresented, !isWriting, mode == .changes, let location, let status, statisticsTask == nil else { return }
        let token = statisticsGeneration
        let previousInputs = statisticsInputs
        let previous = workspaceStatistics
        let previousPaths = Array(previousInputs?.paths ?? [])
        isStatisticsLoading = true
        statisticsTask = Task { [weak self, reader] in
            do {
                let inputs = try await reader.statisticsInputs(location, status, previousPaths)
                let value: GitWorkspaceStatistics
                if let previousInputs, let previous, previous.total != nil, inputs.canReuseRows(previousInputs) {
                    value = previous
                } else {
                    let total: GitStatisticsTotal
                    if let previousInputs, let previous, previous.total != nil, inputs.canReuseTotal(previousInputs) {
                        total = .reuse(previous.total)
                    } else { total = .read }
                    value = try await reader.workspaceStatistics(location, status, total)
                    guard try await reader.statisticsInputs(location, status, previousPaths) == inputs else { throw GitBrowseError.changedDuringRead }
                }
                guard let self, isPresented, statisticsGeneration == token, self.location == location,
                      self.status == status, !pendingRefresh, !Task.isCancelled else { return }
                if workspaceStatistics != value { workspaceStatistics = value }
                statisticsInputs = inputs; statisticsError = nil
                isStatisticsLoading = false; statisticsTask = nil
            } catch {
                guard let self, isPresented, statisticsGeneration == token, !Task.isCancelled else { return }
                workspaceStatistics = nil; statisticsInputs = nil
                statisticsError = error.localizedDescription
                isStatisticsLoading = false; statisticsTask = nil
            }
        }
    }

    func back() {
        guard !routes.isEmpty else { return }
        if route == .compose { cancelMessageGeneration() }
        routes.removeLast()
        loadSelection(keepingContent: true)
    }

    func chooseParent(_ parent: String) {
        guard let details, details.commit.parents.contains(parent), details.parent != parent else { return }
        selectedParent = parent
        routes = [.commit(details.commit.id)]
        loadSelection(keepingContent: true)
    }

    private func cancelSelection(keepingContent: Bool = false) {
        selectionGeneration &+= 1
        selectionTask?.cancel(); selectionTask = nil
        if !keepingContent { diff = nil; lastReadDiff = nil; details = nil; selectionError = nil; displayedRoute = nil }
        isSelectionLoading = false
    }

    private func loadSelection(keepingContent: Bool = false) {
        guard let route else { cancelSelection(); return }
        if route == .compose {
            cancelSelection()
            displayedRoute = route
            return
        }
        cancelSelection(keepingContent: keepingContent)
        guard isPresented, let location else { return }
        let token = selectionGeneration
        let parent = selectedParent
        if case .commit(let id) = route, let details, details.commit.id == id,
           details.parent == (parent ?? details.commit.parents.first) {
            // The one retained parent snapshot makes Back synchronous. The
            // background read still detects missing objects or changed access.
            diff = nil; lastReadDiff = nil; selectionError = nil
            displayedRoute = route
        }
        isSelectionLoading = true
        selectionTask = Task { [weak self, reader] in
            do {
                switch route {
                case .compose: break
                case .commit(let commit):
                    let loaded = try await reader.details(location, commit, parent)
                    guard let self, acceptsSelection(token, location, route) else { return }
                    if details != loaded { details = loaded }
                    diff = nil; lastReadDiff = nil
                case .file(let comparison):
                    let loaded = try await reader.diff(location, comparison)
                    guard let self, acceptsSelection(token, location, route) else { return }
                    if lastReadDiff != loaded { diff = loaded; lastReadDiff = loaded }
                }
                guard let self, acceptsSelection(token, location, route) else { return }
                displayedRoute = route
                selectionError = nil; isSelectionLoading = false; selectionTask = nil
            } catch {
                guard let self, acceptsSelection(token, location, route) else { return }
                diff = nil; lastReadDiff = nil
                if case .commit = route { details = nil }
                displayedRoute = route
                selectionError = error.localizedDescription; isSelectionLoading = false; selectionTask = nil
            }
        }
    }

    private func acceptsSelection(_ token: Int, _ location: GitRepositoryLocation, _ route: GitBrowseRoute) -> Bool {
        isPresented && self.location == location && selectionGeneration == token && self.route == route && !Task.isCancelled
    }

    func expandDiff() {
        guard let file = diff, let patch = file.deferredPatch, let location, let route, displayedRoute == route else { return }
        selectionGeneration &+= 1
        let token = selectionGeneration
        isSelectionLoading = true
        selectionTask = Task { [weak self] in
            let parse = Task.detached(priority: .userInitiated) { DiffParser.parseHunks(patch, path: file.path, limitsSize: false) }
            let result = await withTaskCancellationHandler { await parse.value } onCancel: { parse.cancel() }
            guard let self, acceptsSelection(token, location, route) else { return }
            var expanded = file
            expanded.hunks = result.hunks; expanded.deferredPatch = nil
            diff = expanded; isSelectionLoading = false; selectionTask = nil
        }
    }

    var writeBlocker: String? {
        if isWriting { return AppText.localized("Updating Git…") }
        if !isPresented || needsResumeValidation { return AppText.localized("Reading repository…") }
        if navigation.needsCommitInspection { return GitWriteError.uncertain.localizedDescription }
        guard let status, status.revision != nil else { return GitWriteError.unsupportedIndex.localizedDescription }
        if !status.operations.isEmpty || status.files.contains(where: { $0.side == .conflict }) { return GitWriteError.operation.localizedDescription }
        return nil
    }

    var reviewIsCurrent: Bool {
        guard let review = commitReview, let revision = status?.revision else { return false }
        return review.revision == revision
    }

    var canSubmitCommit: Bool {
        writeBlocker == nil && reviewIsCurrent && !(commitReview?.files.isEmpty ?? true)
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && commitMessage.utf8.count <= 65_536 && !commitMessage.utf8.contains(0)
            && !isGeneratingMessage
    }

    func openCommitComposer() {
        cancelMessageGeneration()
        mode = .changes; showsSearch = false; selectedParent = nil
        routes = [.compose]
        cancelSelection()
        displayedRoute = .compose
        acceptCommitReview()
        if status == nil { acceptsReviewOnRefresh = true; refresh() }
    }

    private func acceptCommitReview() {
        guard let status, let revision = status.revision else { navigation.commitReview = nil; return }
        navigation.commitReview = .init(revision: revision, files: status.files.filter { $0.side == .index }, branch: status.branch)
    }

    func refreshReview() {
        acceptsReviewOnRefresh = routes.contains(.compose)
        cancelMessageGeneration()
        refresh()
    }

    /// All writes retain this store until a definite outcome is recorded in the
    /// session. They are deliberately not cancelled by suspend/deinit.
    func stage(_ file: GitBrowseFile? = nil, unstaging: Bool = false, allowed: @escaping @MainActor @Sendable () -> Bool = { true }) {
        guard writeBlocker == nil, let location, let revision = status?.revision else { return }
        guard allowed() else { navigation.writeError = GitWriteError.activeTask.localizedDescription; return }
        let files = file.map { [$0] } ?? (status?.files.filter {
            unstaging ? $0.side == .index : $0.side == .working || $0.side == .untracked
        } ?? [])
        guard !files.isEmpty else { return }
        let oldRoute = route
        prepareWrite()
        navigation.isWriting = true; navigation.writeError = nil; navigation.writeNotice = nil
        Task { [self, writer] in
            do {
                guard allowed() else { throw GitWriteError.activeTask }
                try await writer.stage(location, revision, files, unstaging, GitWritePermission(check: allowed))
                if isPresented, route == oldRoute, case .file = oldRoute { back() }
            } catch { navigation.writeError = error.localizedDescription }
            navigation.isWriting = false
            NotificationCenter.default.post(name: .gitWorkspaceDidWrite, object: location.root.path)
            if isPresented { pendingRefresh = false; refresh() }
        }
    }

    func submitCommit(allowed: @escaping @MainActor @Sendable () -> Bool = { true }) {
        guard canSubmitCommit, let location, let review = commitReview else { return }
        guard allowed() else { navigation.writeError = GitWriteError.activeTask.localizedDescription; return }
        let submitted = commitMessage
        prepareWrite()
        navigation.isWriting = true; navigation.writeError = nil; navigation.writeNotice = nil
        navigation.lastCommit = nil
        Task { [self, writer] in
            do {
                guard allowed() else { throw GitWriteError.activeTask }
                let receipt = try await writer.commit(location, review.revision, submitted, GitWritePermission(check: allowed))
                navigation.lastCommit = receipt
                if commitMessage == submitted { commitMessage = "" }
                navigation.commitReview = nil
                navigation.writeNotice = String(format: AppText.localized("Committed %@"), String(receipt.id.prefix(8)))
                // Only the originating session's composer returns to its root.
                // A different page visited during the write stays in place.
                if route == .compose { back() }
            } catch {
                navigation.writeError = error.localizedDescription
                if let failure = error as? GitWriteError, failure.requiresInspection {
                    navigation.needsCommitInspection = true
                    if case .committed(let id) = failure { navigation.lastCommit = .init(id: id) }
                }
            }
            navigation.isWriting = false
            NotificationCenter.default.post(name: .gitWorkspaceDidWrite, object: location.root.path)
            if isPresented { pendingRefresh = false; refresh() }
        }
    }

    private func prepareWrite() {
        // A refresh that started before this write may otherwise fail its index
        // fence and clear the accepted view while the write is still running.
        generation &+= 1
        refreshTask?.cancel(); refreshTask = nil; isLoading = false; pendingRefresh = false
        cancelStatistics(keepingValues: true)
        cancelSelection(keepingContent: true)
        cancelMessageGeneration()
    }

    func inspectCommitResult() {
        navigation.needsCommitInspection = false
        show(.history)
        if let id = navigation.lastCommit?.id ?? status?.head {
            routes = [.commit(id)]; selectedParent = nil; loadSelection()
        }
    }

    func cancelMessageGeneration() {
        messageGeneration &+= 1
        messageTask?.cancel(); messageTask = nil; isGeneratingMessage = false
    }

    func generateMessage(using generate: @escaping @Sendable (String, String, URL) async -> String?) {
        guard writeBlocker == nil, reviewIsCurrent, let review = commitReview, !review.files.isEmpty, let location else { return }
        cancelMessageGeneration()
        let token = messageGeneration
        let original = commitMessage
        let summary = review.files.map { $0.status + "\t" + $0.path }.joined(separator: "\n")
        isGeneratingMessage = true
        messageTask = Task { [weak self, writer] in
            do {
                let patch = try await writer.patch(location, review.revision)
                try Task.checkCancellation()
                let message = await generate(summary, patch, location.root)
                guard let self, isPresented, self.location == location, messageGeneration == token, !Task.isCancelled else { return }
                isGeneratingMessage = false; messageTask = nil
                // Typed edits and a changed review always win over a late model reply.
                guard commitMessage == original, commitReview == review, reviewIsCurrent else { return }
                if let message { commitMessage = message }
                else { navigation.writeError = AppText.localized("Could not generate a commit message. Your draft is unchanged.") }
            } catch {
                guard let self, isPresented, messageGeneration == token, !Task.isCancelled else { return }
                isGeneratingMessage = false; messageTask = nil
                navigation.writeError = error.localizedDescription
            }
        }
    }
}
