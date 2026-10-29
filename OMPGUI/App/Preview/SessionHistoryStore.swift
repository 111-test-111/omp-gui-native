import Foundation
import Observation

/// Navigation survives sidebar visits; only a presented source owns I/O.
@MainActor @Observable
final class SessionHistoryStore {
    private(set) var sources: [OMPSessionRecordSource] = []
    private(set) var sourceID: String?
    private(set) var records: [OMPSessionRecord] = []
    private(set) var treeRows: [OMPSessionRecordTreeRow] = []
    private(set) var totalRounds: Int?
    private(set) var totalRoots: Int?
    private(set) var viewMode: OMPSessionRecordViewMode
    private(set) var detailViewMode: OMPSessionRecordViewMode
    private(set) var detailFocusPath: [OMPSessionDetailKey] = []
    private(set) var total = 0
    private(set) var page = 0
    private(set) var selectedID: String?
    private(set) var detail: OMPSessionRecordDetail?
    private(set) var filter = OMPSessionRecordFilter()
    private(set) var sortOrder = OMPSessionRecordSortOrder.oldestFirst
    private(set) var error: OMPSessionRecordError?
    private(set) var captureWarning = false
    private(set) var isLoading = false
    private(set) var isCopyingJSON = false
    private(set) var isPresented = false
    var showsSearch = false
    var scrollID: String?

    @ObservationIgnored private let reader: any OMPSessionRecordReading
    @ObservationIgnored private let watchRoot: URL
    @ObservationIgnored private var watch: PreviewFileWatch?
    @ObservationIgnored private var captureWatch: PreviewFileWatch?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var jsonTask: Task<OMPSessionRecordPage, Error>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var needsRead = false
    @ObservationIgnored private var address = OMPSessionDetailAddress()
    @ObservationIgnored private var anchor: String?
    @ObservationIgnored private var expandedRecordIDs: Set<String>?
    @ObservationIgnored private var filteredCollapsedIDs: Set<String> = []
    @ObservationIgnored private var childPages: [String: Int] = [:]
    private struct DetailScope: Hashable { let recordID: String; let section: OMPSessionDetailSection }
    private struct DetailAddressKey: Hashable { let recordID: String; let viewMode: OMPSessionRecordViewMode }
    @ObservationIgnored private var detailStates: [DetailScope: OMPSessionDetailExpansion] = [:]
    @ObservationIgnored private var detailOrder: [DetailScope] = []
    @ObservationIgnored private var detailAddresses: [DetailAddressKey: OMPSessionDetailAddress] = [:]
    private struct Navigation {
        let page: Int
        let scrollID: String?
        let selectedID: String?
        let address: OMPSessionDetailAddress
        let expanded: Set<String>?
        let childPages: [String: Int]
        let details: [DetailScope: OMPSessionDetailExpansion]
        let detailOrder: [DetailScope]
        let addresses: [DetailAddressKey: OMPSessionDetailAddress]
        let focusPath: [OMPSessionDetailKey]
    }
    @ObservationIgnored private var navigation: [String: Navigation] = [:]
    @ObservationIgnored private var navigationOrder: [String] = []

    init(reader: any OMPSessionRecordReading = OMPSessionRecordReader(),
         watchRoot: URL = StoragePaths.root.appendingPathComponent("omp/sessions", isDirectory: true),
         viewMode: OMPSessionRecordViewMode = .tree, detailViewMode: OMPSessionRecordViewMode = .tree) {
        self.reader = reader
        self.watchRoot = watchRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.viewMode = viewMode
        self.detailViewMode = detailViewMode
    }

    isolated deinit { watch?.stop(); captureWatch?.stop(); task?.cancel(); jsonTask?.cancel(); searchTask?.cancel() }

    var source: OMPSessionRecordSource? { sources.first { $0.id == sourceID } }
    var pageCount: Int {
        if let totalRoots { return max(1, (totalRoots + OMPSessionRecordTree.roundPageSize - 1) / OMPSessionRecordTree.roundPageSize) }
        return max(1, (total + OMPSessionRecordPage.size - 1) / OMPSessionRecordPage.size)
    }
    var oldestPage: Int { sortOrder == .oldestFirst ? 0 : pageCount - 1 }
    var newestPage: Int { sortOrder == .oldestFirst ? pageCount - 1 : 0 }
    var hasFilter: Bool {
        !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filter.kind != nil || filter.status != nil
    }
    /// Reveal the first detail only once its complete snapshot is ready. Later
    /// navigation keeps the accepted snapshot visible until the next one arrives.
    var showsDetail: Bool { selectedID != nil && (detail != nil || error != nil) }
    /// A record change is pending while the accepted snapshot still belongs to
    /// the previous selection. The snapshot stays visible to avoid flicker;
    /// actions that would address it are disabled until the next read commits.
    var isDetailPending: Bool {
        guard let selectedID, let detail else { return false }
        return detail.record.id != selectedID || detail.viewMode != detailViewMode
    }

    func present(sources: [OMPSessionRecordSource]) {
        let wasPresented = isPresented
        updateSources(sources)
        if !wasPresented { isPresented = true; installWatch(); refresh() }
    }

    func updateSources(_ next: [OMPSessionRecordSource]) {
        guard sources != next else { return }
        let previous = source
        if let previous { saveNavigation(previous.id) }
        sources = next
        if !sources.contains(where: { $0.id == sourceID }) { sourceID = sources.first?.id }
        if previous?.id != source?.id || previous?.file != source?.file {
            resetContent()
            restoreNavigation()
            installWatch()
            requestRead()
        }
    }

    func selectSource(_ id: String) {
        guard id != sourceID, sources.contains(where: { $0.id == id }) else { return }
        cancelBulkDetailExpansion()
        if let sourceID { saveNavigation(sourceID) }
        sourceID = id
        resetContent(); restoreNavigation(); installWatch(); requestRead()
    }

    func suspend() {
        cancelBulkDetailExpansion()
        isPresented = false
        generation &+= 1
        needsRead = false
        task?.cancel(); searchTask?.cancel(); searchTask = nil
        jsonTask?.cancel()
        watch?.stop(); watch = nil
        captureWatch?.stop(); captureWatch = nil
        isLoading = false
        // Navigation and bounded pixels remain; large indexes never live in all
        // 24 retained PreviewSessions. Release is serialized behind any read.
        let reader = reader
        Task { await reader.release() }
    }

    func refresh() {
        // Keep the reading page anchored while later records append or delayed
        // request captures arrive, including on the oldest page.
        anchor = scrollID ?? records.first?.id
        requestRead()
    }

    func setQuery(_ value: String) {
        filteredCollapsedIDs = []
        filter.query = String(value.prefix(512))
        resetPage()
        generation &+= 1; task?.cancel()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            self?.requestRead()
        }
    }

    func setKind(_ value: OMPSessionRecordKind?) { filter.kind = value; filteredCollapsedIDs = []; resetPage(); requestRead() }
    func setStatus(_ value: OMPSessionRecordStatus?) { filter.status = value; filteredCollapsedIDs = []; resetPage(); requestRead() }
    func clearFilters() { filter = .init(); filteredCollapsedIDs = []; resetPage(); requestRead() }

    func setSortOrder(_ value: OMPSessionRecordSortOrder) {
        guard value != sortOrder else { return }
        sortOrder = value
        page = 0; anchor = nil; scrollID = nil
        requestRead()
    }

    func setViewMode(_ value: OMPSessionRecordViewMode) {
        guard viewMode != value else { return }
        anchor = selectedID ?? scrollID ?? records.first?.id
        viewMode = value; page = 0; scrollID = nil
        if value == .tree, let record = detail?.record ?? records.first(where: { $0.id == selectedID }) {
            var expanded = expandedRecordIDs ?? []
            if let round = record.roundID { expanded.insert(round) }
            if let parent = record.parentRecordID { expanded.insert(parent) }
            expandedRecordIDs = expanded
        }
        requestRead()
    }

    func toggleRecord(_ id: String) {
        guard let row = treeRows.first(where: { $0.id == id }), row.childCount > 0 else { return }
        var expanded = expandedRecordIDs ?? []
        if hasFilter {
            if row.isExpanded { filteredCollapsedIDs.insert(id); expanded.remove(id) }
            else { filteredCollapsedIDs.remove(id); expanded.insert(id) }
        } else if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        // The index is bounded, and this small UI cache need not retain every
        // round visited in a long session.
        if expanded.count > 512 { expanded = Set(expanded.sorted().prefix(511)); expanded.insert(id) }
        expandedRecordIDs = expanded
        anchor = scrollID ?? records.first?.id
        requestRead()
    }

    func collapseRecords() {
        expandedRecordIDs = []
        if hasFilter { filteredCollapsedIDs.formUnion(treeRows.filter { $0.childCount > 0 }.map(\.id)) }
        requestRead()
    }

    func recordBranchPage(_ id: String, page: Int) {
        guard let row = treeRows.first(where: { $0.continuationParentID == id && $0.canLoadMore }) else { return }
        childPages[id] = min(row.pageCount - 1, max(0, page))
        if childPages.count > 64 { childPages = [id: childPages[id]!] }
        anchor = id; scrollID = id
        requestRead()
    }

    func goToPage(_ value: Int) {
        page = min(max(0, value), pageCount - 1)
        anchor = nil; scrollID = nil
        requestRead()
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        cancelBulkDetailExpansion()
        selectedID = id
        address = id.flatMap { detailAddresses[.init(recordID: $0, viewMode: detailViewMode)] } ?? .init()
        detailFocusPath = []
        if id == nil { detail = nil }
        requestRead()
    }

    func setSection(_ section: OMPSessionDetailSection) {
        guard let detail, detail.sections.contains(section) else { return }
        navigate(to: .init(section: section))
    }

    func setDetailViewMode(_ value: OMPSessionRecordViewMode) {
        guard value != detailViewMode else { return }
        cancelBulkDetailExpansion()
        let section = address.section
        var next = selectedID.flatMap { detailAddresses[.init(recordID: $0, viewMode: value)] } ?? .init(section: section)
        // A presentation change stays in the current section. Paths/pages are
        // restored only when that mode's saved address belongs to this section.
        if next.section != section { next = .init(section: section) }
        detailViewMode = value; address = next; detailFocusPath = []
        requestRead()
    }

    var canExpandAllDetails: Bool {
        detailViewMode == .tree && !isDetailPending && !isLoading
            && detail?.rows.contains(where: { $0.canExpand && !$0.isExpanded }) == true
    }

    func expandDetails() {
        guard canExpandAllDetails, let detail, let section = detail.address.section else { return }
        let scope = DetailScope(recordID: detail.record.id, section: section)
        var expansion = detailStates[scope] ?? .init()
        expansion.expandAll = true
        detailStates[scope] = expansion; touchDetail(scope); detailFocusPath = []
        requestRead()
    }

    func toggleDetail(_ path: [OMPSessionDetailKey]) {
        guard detailViewMode == .tree, !isDetailPending, let detail, let section = detail.address.section,
              detail.rows.contains(where: { $0.path == path && $0.canExpand }) else { return }
        let scope = DetailScope(recordID: detail.record.id, section: section)
        var expansion = detailStates[scope] ?? .init()
        expansion.expandAll = false
        if expansion.paths.contains(path) { expansion.paths.remove(path); expansion.pages[path] = nil }
        else {
            guard expansion.paths.count < OMPSessionDetailExpansion.maximumBranches else { return }
            expansion.paths.insert(path)
        }
        detailStates[scope] = expansion; touchDetail(scope)
        detailFocusPath = path
        requestRead()
    }

    func collapseDetails() {
        guard detailViewMode == .tree, !isDetailPending, let detail, let section = detail.address.section else { return }
        let scope = DetailScope(recordID: detail.record.id, section: section)
        detailStates[scope] = .init(); detailFocusPath = []; requestRead()
    }

    func detailBranchPage(_ path: [OMPSessionDetailKey], page: Int) {
        guard detailViewMode == .tree, !isDetailPending, let detail, let section = detail.address.section,
              let row = detail.rows.first(where: { $0.path == path }), row.isExpanded else { return }
        let scope = DetailScope(recordID: detail.record.id, section: section)
        var expansion = detailStates[scope] ?? .init()
        guard expansion.paths.contains(path) else { return }
        expansion.expandAll = false
        expansion.pages[path] = max(0, min(row.pageCount - 1, page))
        detailStates[scope] = expansion; touchDetail(scope)
        detailFocusPath = path; requestRead()
    }

    var canExpandDetail: Bool {
        guard detailViewMode == .tree, let detail, let section = detail.address.section else { return false }
        return (detailStates[.init(recordID: detail.record.id, section: section)]?.paths.count ?? 0) < OMPSessionDetailExpansion.maximumBranches
    }

    private func touchDetail(_ scope: DetailScope) {
        detailOrder.removeAll { $0 == scope }; detailOrder.append(scope)
        while detailOrder.count > 12 { detailStates[detailOrder.removeFirst()] = nil }
        let retained = Set(detailOrder.map(\.recordID))
        detailAddresses = detailAddresses.filter { retained.contains($0.key.recordID) || $0.key.recordID == selectedID }
    }

    private func cancelBulkDetailExpansion() {
        for scope in Array(detailStates.keys) where detailStates[scope]?.expandAll == true {
            detailStates[scope]?.expandAll = false
        }
    }

    var canCopyDetailJSON: Bool {
        isPresented && source != nil && detail != nil && !isDetailPending && !isLoading && !isCopyingJSON
    }

    /// Export a complete selected value without replacing the displayed,
    /// bounded snapshot. The same serial reader serves copy and navigation;
    /// changes to the selection/source cancel copy before queued reads begin.
    func copyDetailJSON() async throws -> String? {
        guard canCopyDetailJSON, task == nil, let source, let detail else { return nil }
        let expected = generation
        let expectedMode = detailViewMode
        let expectedAddress = detail.address
        let recordID = detail.record.id
        let reader = reader
        let request = OMPSessionRecordRequest(file: source.file, selectedID: recordID, address: expectedAddress,
                                              detailViewMode: expectedMode, includeJSON: true)
        isCopyingJSON = true
        let operation = Task { try await reader.read(request) }
        jsonTask = operation
        defer { jsonTask = nil; isCopyingJSON = false; startReadIfNeeded() }
        let snapshot: OMPSessionRecordPage
        do {
            snapshot = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
        } catch is CancellationError { return nil }
        catch {
            guard generation == expected, isPresented, self.source?.id == source.id else { return nil }
            throw error
        }
        guard !Task.isCancelled, generation == expected, isPresented, self.source?.id == source.id,
              selectedID == recordID, detailViewMode == expectedMode else { return nil }
        guard let copied = snapshot.detail, copied.record.id == recordID,
              copied.address.section == expectedAddress.section, copied.address.path == expectedAddress.path,
              let json = copied.jsonCopy else { throw OMPSessionRecordError.changed }
        return json
    }

    func descend(_ key: OMPSessionDetailKey) {
        guard let detail, detail.rows.contains(where: { $0.key == key }),
              detail.address.path.count < OMPSessionRecordReader.maximumDepth else { return }
        var next = detail.address
        next.path.append(key); next.page = 0
        navigate(to: next)
    }

    func ascend(to depth: Int) {
        guard let detail else { return }
        var next = detail.address
        next.path = Array(next.path.prefix(max(0, depth))); next.page = 0
        navigate(to: next)
    }

    func detailPage(_ value: Int) {
        guard let detail else { return }
        var next = detail.address
        next.page = min(max(0, value), detail.pageCount - 1)
        navigate(to: next)
    }

    private func navigate(to next: OMPSessionDetailAddress) {
        guard let detail, !isDetailPending, detail.record.id == selectedID, next != address else { return }
        // Actions address the displayed value, never an unfinished child read.
        // Repeated clicks cannot append the same field twice while I/O is pending.
        cancelBulkDetailExpansion(); address = next
        requestRead()
    }

    private func resetContent() {
        records = []; treeRows = []; totalRounds = nil; totalRoots = nil; total = 0; error = nil; captureWarning = false
        expandedRecordIDs = nil; filteredCollapsedIDs = []; childPages = [:]; detailStates = [:]; detailOrder = []; detailAddresses = [:]
        resetPage()
    }

    private func saveNavigation(_ id: String) {
        let savedDetails = detailStates.mapValues { state in
            var saved = state; saved.expandAll = false; return saved
        }
        navigation[id] = .init(page: page, scrollID: scrollID, selectedID: selectedID, address: address,
            expanded: expandedRecordIDs, childPages: childPages, details: savedDetails, detailOrder: detailOrder,
            addresses: detailAddresses, focusPath: detailFocusPath)
        navigationOrder.removeAll { $0 == id }; navigationOrder.append(id)
        while navigationOrder.count > 4 { navigation[navigationOrder.removeFirst()] = nil }
    }

    private func restoreNavigation() {
        guard let sourceID, let saved = navigation[sourceID] else { return }
        page = saved.page; scrollID = saved.scrollID; anchor = saved.scrollID
        selectedID = saved.selectedID; address = saved.address; expandedRecordIDs = saved.expanded
        childPages = saved.childPages; detailStates = saved.details; detailOrder = saved.detailOrder; detailAddresses = saved.addresses
        detailFocusPath = saved.focusPath
        if let selectedID {
            let section = saved.address.section
            let cached = detailAddresses[.init(recordID: selectedID, viewMode: detailViewMode)]
            if let cached, cached.section == section { address = cached }
            else { address = .init(section: section) }
        }
    }

    private func resetPage() {
        cancelBulkDetailExpansion()
        page = 0; anchor = nil; scrollID = nil; selectedID = nil; detail = nil; address = .init(); detailFocusPath = []
    }

    private func installWatch() {
        watch?.stop(); watch = nil
        captureWatch?.stop(); captureWatch = nil
        guard isPresented, let source else { return }
        let url = URL(fileURLWithPath: source.file).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(watchRoot.path + "/"), url.pathExtension == "jsonl" else { return }
        watch = PreviewFileWatch(url: url) { [weak self] in self?.refresh() }
        let revision = watchRoot.deletingLastPathComponent().appendingPathComponent("requests/.revision")
        captureWatch = PreviewFileWatch(url: revision) { [weak self] in self?.refresh() }
    }

    private func requestRead() {
        generation &+= 1
        task?.cancel()
        jsonTask?.cancel()
        guard isPresented, source != nil else { needsRead = false; isLoading = false; return }
        needsRead = true
        startReadIfNeeded()
    }

    private func startReadIfNeeded() {
        guard task == nil, jsonTask == nil, needsRead, isPresented, let source else { return }
        needsRead = false; isLoading = true; error = nil
        let expected = generation
        let expansion = detailViewMode == .tree
            ? selectedID.flatMap { id in address.section.map { detailStates[.init(recordID: id, section: $0)] ?? .init() } } ?? .init()
            : OMPSessionDetailExpansion()
        let request = OMPSessionRecordRequest(file: source.file, filter: filter, sortOrder: sortOrder, page: page, anchor: anchor,
            selectedID: selectedID, address: address, viewMode: viewMode, expandedRecordIDs: expandedRecordIDs,
            collapsedRecordIDs: filteredCollapsedIDs, childPages: childPages, detailExpansion: expansion, detailViewMode: detailViewMode)
        let reader = reader
        task = Task { [weak self] in
            let result: Result<OMPSessionRecordPage, Error>
            do { result = .success(try await reader.read(request)) }
            catch { result = .failure(error) }
            guard let self else { return }
            task = nil
            if generation == expected, isPresented, self.source?.id == source.id {
                isLoading = false
                switch result {
                case .success(let snapshot):
                    if expansion.expandAll { cancelBulkDetailExpansion() }
                    if records != snapshot.records { records = snapshot.records }
                    if treeRows != snapshot.treeRows { treeRows = snapshot.treeRows }
                    totalRounds = snapshot.totalRounds
                    totalRoots = snapshot.totalRoots
                    if viewMode == .tree { expandedRecordIDs = snapshot.expandedRecordIDs }
                    total = snapshot.total; page = snapshot.page
                    captureWarning = snapshot.captureWarning
                    if detail != snapshot.detail { detail = snapshot.detail }
                    if selectedID != nil, detail == nil { selectedID = nil; address = .init() }
                    if let detail {
                        selectedID = detail.record.id; address = detail.address
                        detailAddresses[.init(recordID: detail.record.id, viewMode: detail.viewMode)] = detail.address
                        if let section = detail.address.section {
                            let scope = DetailScope(recordID: detail.record.id, section: section)
                            if expansion.expandAll, detail.viewMode == .tree {
                                var resolved = detailStates[scope] ?? expansion
                                resolved.paths = detail.expandedPaths; resolved.expandAll = false
                                detailStates[scope] = resolved
                            }
                            touchDetail(scope)
                        }
                    }
                    error = nil
                case .failure(is CancellationError): break
                case .failure(let failure):
                    error = failure as? OMPSessionRecordError ?? .unavailable
                    // A deleted/replaced source must not leave stale detail on screen.
                    detail = nil
                }
            }
            startReadIfNeeded()
        }
    }

    /// Only identities already discovered by OMP/Hydra are eligible; never scan
    /// other threads, native profiles or arbitrary directories for more sources.
    static func sources(threadID: UUID, threads: [ChatThread]) -> [OMPSessionRecordSource] {
        let children = Dictionary(grouping: threads.filter {
            $0.hydra?.kind == .native && $0.hydra?.nativeCanonicalID == nil && $0.parentThreadID != nil
        }, by: { $0.parentThreadID! })
        var queue = [threadID]
        var seen = Set<UUID>()
        var files = Set<String>()
        var result: [OMPSessionRecordSource] = []
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while !queue.isEmpty, seen.count < 512 {
            let id = queue.removeFirst()
            guard seen.insert(id).inserted, let thread = byID[id] else { continue }
            if let file = thread.providerSessionID, files.insert(file).inserted {
                result.append(.init(id: "\(id)|\(thread.hydra?.nativeObservationID ?? "")|\(file)",
                                    title: thread.title, file: file, isAgent: id != threadID, personaIndex: thread.hydra?.index))
            }
            queue.append(contentsOf: (children[id] ?? []).sorted {
                if $0.hydra?.index != $1.hydra?.index { return ($0.hydra?.index ?? 0) < ($1.hydra?.index ?? 0) }
                return $0.id.uuidString < $1.id.uuidString
            }.map(\.id))
        }
        return result
    }
}
