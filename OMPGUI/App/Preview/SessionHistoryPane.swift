import AppKit
import CoreText
import SwiftUI

struct SessionHistoryPane: View {
    @Environment(AppModel.self) private var model
    let previews: FilePreviewStore
    let session: PreviewSession
    let state: SessionHistoryStore
    /// Isolated layout checks can supply native fixture identities without a runtime.
    var sourceOverride: [OMPSessionRecordSource]?
    @State private var discoveredSources: [OMPSessionRecordSource] = []
    @State private var jsonCopyError: String?

    init(previews: FilePreviewStore, session: PreviewSession, state: SessionHistoryStore? = nil,
         sourceOverride: [OMPSessionRecordSource]? = nil) {
        self.previews = previews; self.session = session
        self.state = state ?? session.history
        self.sourceOverride = sourceOverride
    }

    private var presented: Bool {
        previews.isVisible && previews.isWindowPresented && previews.isWorkspacePresented
            && previews.activeSidebarTab == .panel(.trajectory)
    }

    private var sources: [OMPSessionRecordSource] {
        sourceOverride ?? discoveredSources
    }

    private struct DetailLocation: Equatable {
        let recordID: String
        let address: OMPSessionDetailAddress
        let viewMode: OMPSessionRecordViewMode
    }

    private var detailLocation: DetailLocation? {
        state.detail.map { .init(recordID: $0.record.id, address: $0.address, viewMode: $0.viewMode) }
    }

    var body: some View {
        GeometryReader { overviewGeometry in
            WorkspaceDetailColumns(isFullscreen: previews.isFullscreen, hasDetail: state.showsDetail,
                fraction: Binding(get: { session.historyDetailFraction }, set: { session.historyDetailFraction = $0 }),
                minimumSplitWidth: 720, minimumOverviewWidth: 280, minimumDetailWidth: 360) { width in
                    VStack(spacing: 0) {
                        listToolbar(width: width)
                        recordList(overviewWidth: max(0, overviewGeometry.size.width - 12), columnWidth: width)
                    }
                } detail: {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            detailToolbar(width: geometry.size.width)
                            detailBody(width: geometry.size.width)
                        }
                        .animation(nil, value: detailLocation)
                    }
                }
        }
        .onChange(of: presented, initial: true) { _, visible in
            if visible { state.present(sources: sources) } else { state.suspend() }
        }
        .onChange(of: model.threadsRevision, initial: true) { _, _ in
            guard sourceOverride == nil else { return }
            discoveredSources = SessionHistoryStore.sources(threadID: session.context.threadID, threads: model.threads)
        }
        .onChange(of: sources) { _, next in state.updateSources(next) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if presented { state.refresh() }
        }
        .onDisappear { state.suspend() }
        .accessibilityLabel(Text("Session history"))
        .alert("Could not copy JSON", isPresented: Binding(get: { jsonCopyError != nil }, set: { if !$0 { jsonCopyError = nil } })) {
            Button("OK", role: .cancel) { jsonCopyError = nil }
        } message: { Text(verbatim: jsonCopyError ?? "") }
    }

    private func listToolbar(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            if state.showsSearch {
                TextField("", text: Binding(get: { state.filter.query }, set: { state.setQuery($0) }),
                          prompt: Text("Search record summaries"))
                    .font(.ui(.callout)).textFieldStyle(.chromeGlass)
                    .accessibilityLabel(Text("Search record summaries"))
                    .onExitCommand { state.showsSearch = false }
                ChromeCapsule {
                    ChromeIconButton(symbol: "xmark", help: "Close history search") { state.showsSearch = false }
                }
            } else {
                sourceMenu(compact: width < 440)
                ChromeCapsule {
                    ChromeMenuButton(symbol: "line.3.horizontal.decrease",
                                     help: "Filter session history") { filterMenu }
                    ChromeIconButton(symbol: "magnifyingglass", isActive: !state.filter.query.isEmpty, help: "Search record summaries") {
                        state.showsSearch = true
                    }
                    if width >= 560 {
                        ChromeIconButton(symbol: "arrow.clockwise", help: "Refresh session history") { state.refresh() }
                    }
                }
                Spacer(minLength: 0)
                if width >= 400 { pageLabel(state.page, count: state.pageCount) }
                ChromeCapsule {
                    if width >= 300 {
                        ChromeIconButton(symbol: "chevron.left", isEnabled: state.page > 0, help: state.sortOrder.previousPageTitle) {
                            state.goToPage(state.page - 1)
                        }
                        ChromeIconButton(symbol: "chevron.right", isEnabled: state.page + 1 < state.pageCount, help: state.sortOrder.nextPageTitle) {
                            state.goToPage(state.page + 1)
                        }
                    }
                    ChromeMenuButton(symbol: state.captureWarning ? "exclamationmark.triangle" : "ellipsis",
                                     help: state.captureWarning
                                         ? "Session history actions; some request captures could not be saved or read."
                                         : "Session history actions") { listActions }
                }
            }
        }
        .padding(Chrome.workspaceToolbarInsets)
        .accessibilityIdentifier("session-history.toolbar")
    }

    @ViewBuilder private func sourceMenu(compact: Bool) -> some View {
        if compact {
            ChromeCircleMenuButton(symbol: "road.lanes", help: "Choose history source") { sourceItems }
        } else {
            ChromeTextMenu(title: state.source?.title ?? Chrome.localized("Session history"), help: "Choose history source",
                           titleText: Text(verbatim: state.source?.title ?? Chrome.localized("Session history")),
                           allowsTitleTruncation: true) { sourceItems }
                .frame(maxWidth: 150)
        }
    }

    @ViewBuilder private var sourceItems: some View {
        ForEach(state.sources) { source in
            sourceItem(source)
        }
    }

    private func sourceItem(_ source: OMPSessionRecordSource) -> PopoverItem {
        let glyph = source.personaIndex.map { AnyView(HydraGlyph(persona: HydraRoster.persona(at: $0), size: 16)) }
        var item = PopoverItem(source.title, symbol: source.isAgent ? nil : "road.lanes", leading: glyph,
                               isChecked: source.id == state.sourceID) { state.selectSource(source.id) }
        item.titleText = Text(verbatim: source.title)
        return item
    }

    private var filterMenu: some View {
        Group {
            PopoverItem("All record types", isChecked: state.filter.kind == nil) { state.setKind(nil) }
            ForEach(OMPSessionRecordKind.allCases, id: \.self) { kind in
                PopoverItem(kind.title, symbol: kind.symbol, isChecked: state.filter.kind == kind) { state.setKind(kind) }
            }
            PopoverDivider()
            PopoverItem("All statuses", isChecked: state.filter.status == nil) { state.setStatus(nil) }
            ForEach(OMPSessionRecordStatus.allCases, id: \.self) { status in
                PopoverItem(status.title, isChecked: state.filter.status == status) { state.setStatus(status) }
            }
            PopoverDivider()
            PopoverItem("Clear filters", isEnabled: state.hasFilter) { state.clearFilters() }
        }
    }

    private var listActions: some View {
        Group {
            if state.captureWarning {
                Text("Some request captures could not be saved or read.")
                    .font(.ui(.caption)).foregroundStyle(Chrome.danger).padding(8)
            }
            PopoverItem("Refresh session history", symbol: "arrow.clockwise") { state.refresh() }
            PopoverDivider()
            ForEach(OMPSessionRecordViewMode.allCases, id: \.self) { mode in
                PopoverItem(mode.title, symbol: mode == .tree ? "list.bullet.indent" : "list.bullet",
                            isChecked: state.viewMode == mode) { state.setViewMode(mode) }
            }
            if state.viewMode == .tree {
                PopoverItem("Collapse all rounds", symbol: "chevron.up") { state.collapseRecords() }
            }
            PopoverDivider()
            ForEach(OMPSessionRecordSortOrder.allCases, id: \.self) { order in
                PopoverItem(order.title, isChecked: state.sortOrder == order) { state.setSortOrder(order) }
            }
            PopoverDivider()
            PopoverItem("Oldest records", symbol: state.oldestPage == 0 ? "arrow.up.to.line" : "arrow.down.to.line",
                        isEnabled: state.page != state.oldestPage) { state.goToPage(state.oldestPage) }
            PopoverItem("Newest records", symbol: state.newestPage == 0 ? "arrow.up.to.line" : "arrow.down.to.line",
                        isEnabled: state.page != state.newestPage) { state.goToPage(state.newestPage) }
            PopoverItem(state.sortOrder.previousPageTitle, symbol: "chevron.left", isEnabled: state.page > 0) { state.goToPage(state.page - 1) }
            PopoverItem(state.sortOrder.nextPageTitle, symbol: "chevron.right", isEnabled: state.page + 1 < state.pageCount) { state.goToPage(state.page + 1) }
            PopoverDivider()
            if let rounds = state.totalRounds {
                Text(verbatim: String(format: Chrome.localized("Page %d of %d · %d rounds · %d records"), state.page + 1, state.pageCount, rounds, state.total))
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(8)
            } else {
                Text(verbatim: String(format: Chrome.localized("Page %d of %d · %d records"), state.page + 1, state.pageCount, state.total))
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(8)
            }
        }
    }

    @ViewBuilder private func recordList(overviewWidth: CGFloat, columnWidth: CGFloat) -> some View {
        if let error = state.error {
            message(error.title, symbol: "exclamationmark.triangle")
        } else if state.records.isEmpty {
            if state.isLoading { loading }
            else { message(state.source == nil ? "No session history yet" : state.hasFilter ? "No matching records" : "No session records", symbol: "road.lanes") }
        } else {
            ScrollView {
                LazyVStack(spacing: state.viewMode == .tree ? 0 : 1) {
                    if state.viewMode == .tree {
                        ForEach(state.treeRows) { row in
                            if let parent = row.continuationParentID {
                                recordContinuation(row, parent: parent, width: overviewWidth)
                            } else {
                                SessionHistoryRecordRow(record: row.record, selected: state.selectedID == row.id,
                                    overviewWidth: overviewWidth, tree: row, compactTree: columnWidth < 420,
                                    containsSelection: !row.isExpanded && state.detail.map {
                                        $0.record.roundID == row.id || $0.record.parentRecordID == row.id
                                    } == true, onToggle: { state.toggleRecord(row.id) }) {
                                        if row.isSessionEvents { state.toggleRecord(row.id) } else { state.select(row.id) }
                                    }
                                    .id(row.id)
                            }
                        }
                    } else {
                        ForEach(state.records) { record in
                            SessionHistoryRecordRow(record: record, selected: state.selectedID == record.id, overviewWidth: overviewWidth) { state.select(record.id) }
                                .id(record.id)
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .scrollTargetLayout()
            }
            .scrollPosition(id: Binding(get: { state.scrollID }, set: { state.scrollID = $0 }), anchor: .top)
            .accessibilityIdentifier("session-history.records")
            .onMoveCommand { direction in moveInRecords(direction) }
        }
    }

    private func moveInRecords(_ direction: MoveCommandDirection) {
        let rows = state.viewMode == .tree ? state.treeRows.filter { $0.continuationParentID == nil && !$0.isSessionEvents }.map(\.record) : state.records
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == state.selectedID } ?? 0
        switch direction {
        case .up: state.select(rows[max(0, index - 1)].id)
        case .down: state.select(rows[min(rows.count - 1, index + 1)].id)
        case .right:
            if let row = state.treeRows.first(where: { $0.id == rows[index].id }), row.childCount > 0, !row.isExpanded { state.toggleRecord(row.id) }
        case .left:
            if let row = state.treeRows.first(where: { $0.id == rows[index].id }), row.childCount > 0, row.isExpanded { state.toggleRecord(row.id) }
            else if let parent = rows[index].parentRecordID ?? rows[index].roundID, parent != rows[index].id { state.select(parent) }
        default: break
        }
    }

    private func recordContinuation(_ row: OMPSessionRecordTreeRow, parent: String, width: CGFloat) -> some View {
        let geometry = SessionHistoryTreeGeometry(depth: row.depth, step: width < 420 ? 12 : 14, maximumIndent: 56)
        return branchPager(page: row.page, count: row.pageCount, enabled: row.canLoadMore) {
            state.recordBranchPage(parent, page: $0)
        }
        .padding(.leading, geometry.gutterWidth).padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionHistoryTreeDecoration(geometry: geometry, ancestors: row.ancestorContinuations, last: true,
            expanded: false, connectsChildren: false, hasDisclosure: false, title: "", toggle: {}))
    }

    @ViewBuilder private func branchPager(page: Int, count: Int, enabled: Bool, action: @escaping (Int) -> Void) -> some View {
        if enabled {
            HStack(spacing: 6) {
                ChromeCapsule {
                    ChromeIconButton(symbol: "chevron.left", isEnabled: page > 0, help: "Previous branch page") { action(page - 1) }
                    ChromeIconButton(symbol: "chevron.right", isEnabled: page + 1 < count, help: "Next branch page") { action(page + 1) }
                }
                pageLabel(page, count: count)
            }.anchorPreference(key: SessionHistoryTitleAnchor.self, value: .bounds) { $0 }
        } else {
            Text("Display limit reached. Collapse a branch to show more.")
                .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true)
                .anchorPreference(key: SessionHistoryTitleAnchor.self, value: .bounds) { $0 }
        }
    }

    private func detailToolbar(width: CGFloat) -> some View {
        let detail = state.detail
        let pending = state.isDetailPending
        return HStack(spacing: 6) {
            ChromeCapsule {
                ChromeIconButton(symbol: "chevron.left", help: state.detail?.address.path.isEmpty == false ? "Parent value" : "Back to session records") {
                    if let path = state.detail?.address.path, !path.isEmpty { state.ascend(to: path.count - 1) }
                    else { state.select(nil) }
                }
            }
            if width >= 320 {
                ChromeTextMenu(title: detail?.address.section?.title ?? "Record metadata",
                               help: "Choose record detail") {
                    if let detail { detailSections(detail) }
                }
                .disabled(detail == nil).allowsHitTesting(!pending)
            } else {
                ChromeCircleMenuButton(symbol: "text.alignleft", help: "Choose record detail") {
                    if let detail { detailSections(detail) }
                }
                .disabled(detail == nil).allowsHitTesting(!pending)
            }
            Spacer(minLength: 0)
            if width >= 480 { pageLabel(detail?.address.page ?? 0, count: detail?.pageCount ?? 1) }
            ChromeCapsule {
                if width >= 380 {
                    ChromeIconButton(symbol: "chevron.left", isEnabled: (detail?.address.page ?? 0) > 0, help: "Previous detail page") {
                        if let detail { state.detailPage(detail.address.page - 1) }
                    }
                    ChromeIconButton(symbol: "chevron.right", isEnabled: (detail?.address.page ?? 0) + 1 < (detail?.pageCount ?? 1), help: "Next detail page") {
                        if let detail { state.detailPage(detail.address.page + 1) }
                    }
                }
                if width >= 440 {
                    ChromeIconButton(symbol: "doc.on.doc", isEnabled: detail != nil, help: "Copy visible detail", action: copyVisibleDetail)
                        .allowsHitTesting(!pending)
                }
                if width >= 560 {
                    ChromeIconButton(symbol: "curlybraces", isEnabled: detail != nil, help: "Copy as JSON", action: copyDetailJSON)
                        .allowsHitTesting(state.canCopyDetailJSON)
                }
                ChromeMenuButton(symbol: "ellipsis", help: "Record detail actions") { detailActions(detail) }
            }
        }
        .padding(Chrome.workspaceToolbarInsets)
        .accessibilityIdentifier("session-history.detail-toolbar")
    }

    private func detailSections(_ detail: OMPSessionRecordDetail) -> some View {
        Group {
            ForEach(detail.sections, id: \.self) { section in
                PopoverItem(section.title, isChecked: detail.address.section == section) { state.setSection(section) }
            }
            if !detail.address.path.isEmpty {
                PopoverDivider()
                PopoverItem("Root value", symbol: "arrow.up.to.line") { state.ascend(to: 0) }
                ForEach(Array(detail.address.path.enumerated()), id: \.offset) { index, key in
                    PopoverItem(key.title, text: Text(verbatim: key.title), isChecked: index == detail.address.path.count - 1) {
                        state.ascend(to: index + 1)
                    }
                }
            }
        }
    }

    private func detailActions(_ detail: OMPSessionRecordDetail?) -> some View {
        Group {
            PopoverItem("Copy visible detail", symbol: "doc.on.doc",
                        isEnabled: detail != nil && !state.isDetailPending, confirmation: "Copied") {
                copyVisibleDetail()
            }
            PopoverItem("Copy as JSON", symbol: "curlybraces", isEnabled: state.canCopyDetailJSON, action: copyDetailJSON)
            PopoverItem("Copy entry ID", symbol: "number",
                        isEnabled: detail != nil && !state.isDetailPending, confirmation: "Copied") {
                if let detail { copy(detail.record.entryID) }
            }
            PopoverItem("Refresh session history", symbol: "arrow.clockwise") { state.refresh() }
            PopoverDivider()
            ForEach(OMPSessionRecordViewMode.allCases, id: \.self) { mode in
                PopoverItem(mode.title, symbol: mode == .tree ? "list.bullet.indent" : "list.bullet",
                            isChecked: state.detailViewMode == mode, isEnabled: detail != nil && !state.isDetailPending) {
                    state.setDetailViewMode(mode)
                }
            }
            if state.detailViewMode == .tree {
                PopoverItem("Expand all parameters", symbol: "chevron.down", isEnabled: state.canExpandAllDetails) { state.expandDetails() }
                PopoverItem("Collapse parameter branches", symbol: "chevron.up", isEnabled: detail != nil && !state.isDetailPending) { state.collapseDetails() }
            }
            PopoverDivider()
            PopoverItem("Previous detail page", symbol: "chevron.left", isEnabled: (detail?.address.page ?? 0) > 0) {
                if let detail { state.detailPage(detail.address.page - 1) }
            }
            PopoverItem("Next detail page", symbol: "chevron.right", isEnabled: (detail?.address.page ?? 0) + 1 < (detail?.pageCount ?? 1)) {
                if let detail { state.detailPage(detail.address.page + 1) }
            }
            PopoverItem("Back to session records", symbol: "list.bullet") { state.select(nil) }
            Text(verbatim: String(format: Chrome.localized("Page %d of %d"), (detail?.address.page ?? 0) + 1, detail?.pageCount ?? 1))
                .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(8)
        }
    }

    private func detailBody(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("session-history.detail-top")
                    if let detail = state.detail {
                        detailContent(detail, width: width)
                    }
                }
            }
            .overlay {
                if let error = state.error { message(error.title, symbol: "exclamationmark.triangle") }
                else if state.detail == nil { loading }
            }
            .onChange(of: detailLocation) { _, _ in
                proxy.scrollTo("session-history.detail-top", anchor: .top)
            }
            .accessibilityIdentifier("session-history.detail")
        }
    }

    @ViewBuilder private func detailContent(_ detail: OMPSessionRecordDetail, width: CGFloat) -> some View {
        if let text = detail.text {
            Text(verbatim: text).font(.code(.callout)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        } else if detail.viewMode == .flat {
            flatDetailContent(detail)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(detail.outlineRows) { item in
                    if item.isContinuation {
                        detailContinuation(item.row, width: width, limited: detail.isLimited)
                    } else {
                        SessionHistoryDetailValueRow(row: item.row, state: state, width: width,
                            identity: detail.record.id + ":\(detail.address.section?.rawValue ?? ""):\(item.row.path)")
                    }
                }
                if detail.isLimited || !state.canExpandDetail {
                    Text("Display limit reached. Collapse a branch to show more.")
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(12)
                }
            }
            .padding(.top, 4)
        }
    }

    private func flatDetailContent(_ detail: OMPSessionRecordDetail) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(detail.rows) { row in
                Button { state.descend(row.key) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: row.key.title).font(.code(.callout)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: row.preview).font(.code(.caption)).foregroundStyle(Chrome.secondaryText)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if detail.address.path.count < OMPSessionRecordReader.maximumDepth {
                            Image(systemName: "chevron.right").font(.symbol(.caption2)).foregroundStyle(Chrome.secondaryText)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(state.isDetailPending || detail.address.path.count >= OMPSessionRecordReader.maximumDepth)
                Divider().padding(.horizontal, 12)
            }
        }.padding(.top, 4)
    }

    private func detailContinuation(_ row: OMPSessionDetailRow, width: CGFloat, limited: Bool) -> some View {
        let geometry = SessionHistoryTreeGeometry(depth: row.depth + 1, step: width < 420 ? 12 : 14, maximumIndent: width < 420 ? 36 : 56)
        return branchPager(page: row.page, count: row.pageCount, enabled: !limited) {
            state.detailBranchPage(row.path, page: $0)
        }
        .padding(.leading, geometry.gutterWidth).padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionHistoryTreeDecoration(geometry: geometry, ancestors: row.ancestorContinuations + [!row.isLastSibling],
            last: true, expanded: false, connectsChildren: false, hasDisclosure: false, title: "", toggle: {}))
    }

    private func pageLabel(_ page: Int, count: Int) -> some View {
        Text(verbatim: String(format: Chrome.localized("%d / %d"), page + 1, count))
            .font(.ui(.caption)).monospacedDigit().foregroundStyle(Chrome.secondaryText).fixedSize()
    }

    private var loading: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ title: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.symbol(.title2))
            Text(verbatim: Chrome.localized(title)).font(.ui(.callout)).multilineTextAlignment(.center)
        }
        .foregroundStyle(Chrome.secondaryText).padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func copyVisibleDetail() {
        guard !state.isDetailPending, let detail = state.detail else { return }
        copy(detail.copyText)
    }

    private func copyDetailJSON() {
        Task {
            do {
                if let json = try await state.copyDetailJSON() { copy(json) }
            } catch {
                jsonCopyError = Chrome.localized((error as? OMPSessionRecordError)?.title ?? "Unable to copy detail as JSON.")
            }
        }
    }
}

struct SessionHistoryRecordRow: View {
    let record: OMPSessionRecord
    let selected: Bool
    let overviewWidth: CGFloat
    var tree: OMPSessionRecordTreeRow? = nil
    var compactTree = false
    var containsSelection = false
    var onToggle: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovered = false

    private var title: String {
        if tree?.depth == 0, let number = record.roundNumber {
            return String(format: Chrome.localized("Round %d"), number)
        }
        if tree?.isSessionEvents == true { return Chrome.localized("Session events") }
        let key: String? = switch record.title {
        case "user": "User message"
        case "assistant": record.isFinalReply ? "Model reply" : "Model response"
        case "tool_execution_start": "Tool execution started"
        case "compaction": "Compaction"
        case "branch_summary": "Branch summary"
        case "reset_boundary": "Context reset"
        case "model_change": "Model change"
        case "thinking_level_change": "Thinking level change"
        case "service_tier_change": "Service tier change"
        case "model_usage": "Model usage"
        case "model_request": "Model request"
        case "side_request": "Side request"
        case "provider_payload": "Provider payload"
        case "provider_response": "Provider response"
        case "title_change": "Title change"
        case "label": "Label"
        case "custom_message": "Custom message"
        case "session_exit": "Session exit"
        case "custom": "Custom record"
        default: nil
        }
        return key.map(Chrome.localized) ?? record.title
    }

    private var summary: String {
        if record.title == "thinking_level_change", ModelOption.effortRank(record.summary) != nil {
            return Chrome.localized(ModelOption.effortTitle(record.summary))
        }
        return record.summary
    }

    private func summaryLines(font: NSFont) -> Int {
        // Measure one native line at the unsplit row's caption width. Detail
        // selection changes the rendered width, never this layout reference.
        let value = NSAttributedString(string: summary, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(value as CFAttributedString)
        let referenceGutter = tree.map { CGFloat($0.depth) * (overviewWidth < 420 ? 12 : 14) + 24 } ?? 0
        let firstLine = CTTypesetterSuggestLineBreak(typesetter, 0, Double(max(1, overviewWidth - 42 - referenceGutter)))
        let remaining = (summary as NSString).substring(from: firstLine)
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 2
    }

    @ViewBuilder var body: some View {
        if let tree {
            rowContent.modifier(SessionHistoryTreeDecoration(geometry: treeGeometry, ancestors: tree.ancestorContinuations,
                last: tree.isLastSibling, expanded: tree.isExpanded, connectsChildren: tree.childCount > 0,
                hasDisclosure: tree.childCount > 0, active: selected || containsSelection, title: title, toggle: { onToggle?() }))
                .accessibilityValue(Text(verbatim: String(format: Chrome.localized("Level %d"), tree.depth + 1)))
        } else { rowContent }
    }

    private var treeGeometry: SessionHistoryTreeGeometry {
        .init(depth: tree?.depth ?? 0, step: compactTree ? 12 : 14, maximumIndent: 56)
    }

    private var rowContent: some View {
        let titleCapHeight = NSFont.systemFont(ofSize: TypeScale.shared.ui(TypeScale.stockPointSize(.callout)), weight: .medium).capHeight
        let summaryFont = NSFont.systemFont(ofSize: TypeScale.shared.ui(TypeScale.stockPointSize(.caption)))
        let lines = summary.isEmpty ? 0 : summaryLines(font: summaryFont)
        let summaryHeight = CGFloat(lines) * (ceil(summaryFont.ascender) - floor(summaryFont.descender) + ceil(summaryFont.leading))
        return Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon.frame(width: TimelineIconMetrics.size, height: TimelineIconMetrics.size)
                    .alignmentGuide(.firstTextBaseline) { [titleCapHeight] dimensions in
                        // A small optical descent keeps the symbols aligned
                        // with the visible title glyphs.
                        dimensions[VerticalAlignment.center] + titleCapHeight / 2 - 1
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(verbatim: title).font(.ui(.callout, weight: .medium)).lineLimit(1)
                            .anchorPreference(key: SessionHistoryTitleAnchor.self, value: .bounds) { $0 }
                        Spacer(minLength: 0)
                        if let date = record.timestamp {
                            Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                                .font(.ui(.caption2)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                        }
                    }
                    if !summary.isEmpty {
                        Text(verbatim: summary).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                            .lineLimit(lines)
                            // Round each native font metric so actual wrapped
                            // text fits without reserving a second empty line.
                            .frame(maxWidth: .infinity, minHeight: summaryHeight, maxHeight: summaryHeight, alignment: .topLeading)
                    }
                    if let status = record.status, status != .completed {
                        Text(verbatim: Chrome.localized(status.title)).font(.ui(.caption2))
                            .foregroundStyle(status == .failed ? Chrome.danger : Chrome.secondaryText)
                    }
                }
            }
            .padding(.leading, tree == nil ? 0 : treeGeometry.gutterWidth)
            .padding(9).contentShape(.rect)
            .background(Chrome.overlay(selected ? 0.10 : hovered ? 0.05 : containsSelection ? 0.035 : 0), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var icon: some View {
        if record.kind == .tool {
            TimelineSymbolIcon(OMPTool.named(record.title).map { OMPToolSymbols.symbol(for: $0) }
                ?? OMPToolSymbols.symbol(for: ToolCall.Kind.other))
                .foregroundStyle(record.status == .failed ? Chrome.danger : Chrome.secondaryText)
        } else {
            Image(systemName: record.title == "tool_execution_start" ? "play" : record.symbol)
                .font(.symbol(.callout)).foregroundStyle(Chrome.secondaryText)
        }
    }
}
