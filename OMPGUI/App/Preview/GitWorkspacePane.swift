import AppKit
import SwiftUI

struct GitWorkspacePane: View {
    @Environment(AppModel.self) private var model
    let previews: FilePreviewStore
    let session: PreviewSession
    @State private var state: GitWorkspaceStore
    @State private var referenceMenuSizing = GitReferenceMenuSizing()
    @State private var nextMatch = 0
    @State private var scrollRequest = 0
    @State private var scrollTarget: String?
    @State private var dragOrigin: CGFloat?

    init(previews: FilePreviewStore, session: PreviewSession, state: GitWorkspaceStore? = nil) {
        self.previews = previews
        self.session = session
        _state = State(initialValue: state ?? GitWorkspaceStore(navigation: session.gitNavigation))
    }

    private var isPresented: Bool {
        previews.isVisible && previews.isWindowPresented && previews.isWorkspacePresented
            && previews.activeSidebarTab == .panel(.git)
    }

    private var canKeepInactiveTab: Bool {
        previews.isVisible && previews.isWindowPresented && previews.isWorkspacePresented
            && session.panels.contains(.git)
    }

    private var showsCommit: Bool {
        if case .commit = state.displayedRoute { return true }
        if previews.isFullscreen, let comparison = displayedComparison,
           comparison.file.side == .commit, comparison.commit == state.details?.commit.id { return true }
        return false
    }

    private var displayedComparison: GitFileComparison? {
        if case .file(let comparison) = state.displayedRoute { return comparison }
        return nil
    }

    private var showsComposer: Bool {
        state.displayedRoute == .compose
            || (previews.isFullscreen && displayedComparison != nil && state.routes.contains(.compose))
    }

    private var showsOverview: Bool { previews.isFullscreen || state.route == nil }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar(width: geometry.size.width)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: isPresented, initial: true) { _, presented in
            if presented { state.present(session.context) }
            else { state.suspend(keepingContent: canKeepInactiveTab) }
        }
        .onChange(of: canKeepInactiveTab) { _, canKeep in
            if !canKeep && !isPresented { state.suspend() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isPresented { state.refresh() }
        }
        .onDisappear { state.suspend() }
        .accessibilityLabel(Text("Git browser"))
    }

    /// Global actions and selectors stay on one row. Per-file staging and the
    /// message generator live beside the specific content they act on.
    private func toolbar(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            if state.route != nil && !previews.isFullscreen {
                ChromeCapsule { ChromeIconButton(symbol: "chevron.left", help: "Back") { state.back() } }
            }
            if state.route == .compose || (previews.isFullscreen && showsComposer) {
                modeMenu(compact: width < 340)
                scopeSelector
                Spacer(minLength: 0)
                ChromeCapsule {
                    ChromeIconButton(symbol: "arrow.clockwise", help: "Refresh and review staged changes") { state.refreshReview() }
                    ChromeIconButton(symbol: "checkmark", help: "Commit staged changes") {
                        // An inline comparison belongs to this same composer.
                        if previews.isFullscreen, state.route != .compose { state.back() }
                        state.submitCommit(allowed: writesAllowed)
                    }
                        .disabled(!state.canSubmitCommit || taskIsActive)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("git-browser.commit")
                    ChromeMenuButton(symbol: "ellipsis", help: "More Git browser actions") { moreMenu(width: width) }
                }
            } else if state.showsSearch {
                modeMenu(compact: true)
                TextField("", text: Binding(get: { state.query }, set: { state.query = $0; nextMatch = 0; focusMatch() }),
                          prompt: Text(verbatim: Chrome.localized(state.mode == .history ? "Find commits" : "Filter changed files")))
                .font(.ui(.callout)).textFieldStyle(.chromeGlass)
                .onSubmit { focusMatch(advance: true) }
                .onExitCommand { state.showsSearch = false }
                .accessibilityLabel(Text(verbatim: Chrome.localized(state.mode == .history ? "Find commits" : "Filter changed files")))
                ChromeCapsule {
                    ChromeIconButton(symbol: "xmark", help: "Close Git search") { state.showsSearch = false }
                }
            } else {
                modeMenu(compact: width < 340)
                scopeSelector
                Spacer(minLength: 0)
                ChromeCapsule {
                    if let file = stagingFile {
                        ChromeIconButton(symbol: file.side == .index ? "minus" : "plus",
                                         help: file.side == .index ? "Unstage this file" : "Stage this file") {
                            state.stage(file, unstaging: file.side == .index, allowed: writesAllowed)
                        }
                        .disabled(state.writeBlocker != nil || taskIsActive)
                        .accessibilityIdentifier("git-browser.stage-file")
                    }
                    ChromeIconButton(symbol: "magnifyingglass", isActive: !state.query.isEmpty, help: "Search Git browser") {
                        state.beginSearch()
                    }
                    ChromeIconButton(symbol: "arrow.clockwise", help: "Refresh Git browser") { state.refresh() }
                    ChromeMenuButton(symbol: "ellipsis", help: "More Git browser actions") { moreMenu(width: width) }
                }
            }
        }
        .padding(Chrome.workspaceToolbarInsets)
        .accessibilityIdentifier("git-browser.toolbar")
    }

    @ViewBuilder private func modeMenu(compact: Bool) -> some View {
        if compact {
            compactModeMenu
        } else if state.mode == .changes {
            // Large totals must not push global actions out of a narrow row.
            // Native fitting uses the actual localized label and interface font.
            ViewThatFits(in: .horizontal) {
                textModeMenu
                compactModeMenu
            }
        } else {
            textModeMenu
        }
    }

    private var textModeMenu: some View {
        ChromeTextMenu(symbol: nil, title: state.mode.title, help: "Choose Git view", accessory: {
            if state.mode == .changes {
                GitLineStatisticsLabel(value: state.workspaceStatistics?.total,
                                       isLoading: state.isLoading || state.isStatisticsLoading,
                                       totals: true)
            }
        }) { modeItems }
    }

    private var compactModeMenu: some View {
        ChromeCircleMenuButton(symbol: state.mode.symbol, help: "Choose Git view") { modeItems }
            .help(Text(verbatim: compactModeHelp))
            .accessibilityValue(Text(verbatim: compactModeHelp))
    }

    private var compactModeHelp: String {
        guard state.mode == .changes, let total = state.workspaceStatistics?.total else {
            return Chrome.localized("Choose Git view")
        }
        return String(format: Chrome.localized("Choose Git view · all changes: +%lld −%lld"), total.additions, total.deletions)
    }

    private var modeItems: some View {
        ForEach(GitBrowseMode.allCases, id: \.self) { mode in
            PopoverItem(mode.title, symbol: mode.symbol, isChecked: state.mode == mode) { state.show(mode) }
        }
    }

    @ViewBuilder private var scopeSelector: some View {
        if state.mode == .changes {
            ChromeCircleMenuButton(symbol: "line.3.horizontal.decrease", help: "Choose change group") { scopeMenu }
        } else {
            let menuWidth = referenceMenuWidth
            ChromeTextMenu(symbol: "arrow.triangle.branch", title: historySelectorTitle, help: "Choose history scope",
                           titleText: Text(verbatim: historySelectorTitle), menuWidth: menuWidth, allowsTitleTruncation: true) { scopeMenu }
            .accessibilityIdentifier("git-browser.branch-name")
            .accessibilityValue(Text(verbatim: historyScopeTitle))
            .help(Text(verbatim: historySelectorTitle))
        }
    }

    private var referenceMenuWidth: CGFloat {
        let screenWidth = (previews.window?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1024
        return referenceMenuSizing.width(references: state.source?.references ?? [], maximumWidth: max(1, screenWidth - 32))
    }

    private var historySelectorTitle: String {
        guard state.historyReference != nil else { return Chrome.localized("All branches and tags") }
        if let reference = state.historyReference, reference != "HEAD" {
            return state.source?.references.first { $0.name == reference }?.title ?? reference
        }
        return checkoutBranchTitle ?? Chrome.localized("Current checkout")
    }

    private var checkoutBranchTitle: String? {
        state.status?.branch ?? state.status?.head.map { head in
            return String(format: Chrome.localized("Detached HEAD · %@"), String(head.prefix(8)))
        }
    }

    @ViewBuilder private var scopeMenu: some View {
        if state.mode == .changes {
            ForEach(GitChangeGroup.allCases, id: \.self) { group in
                PopoverItem(group.title, isChecked: state.group == group) { state.chooseGroup(group) }
            }
        } else {
            GitHistoryReferenceMenu(references: state.source?.references ?? [], selection: state.historyReference,
                                    onSelect: state.chooseReference)
        }
    }

    @ViewBuilder private func moreMenu(width: CGFloat) -> some View {
        PopoverItem("Commit staged changes…", symbol: "checkmark.circle", isEnabled: state.location != nil && !state.isWriting) { state.openCommitComposer() }
        PopoverItem("Stage all changes", symbol: "plus", isEnabled: state.writeBlocker == nil && !taskIsActive
                    && state.status?.files.contains(where: { $0.side == .working || $0.side == .untracked }) == true) {
            state.stage(allowed: writesAllowed)
        }
        PopoverItem("Unstage all changes", symbol: "minus", isEnabled: state.writeBlocker == nil && !taskIsActive
                    && state.status?.files.contains(where: { $0.side == .index }) == true) {
            state.stage(unstaging: true, allowed: writesAllowed)
        }
        if session.gitNavigation.needsCommitInspection || session.gitNavigation.lastCommit != nil {
            PopoverItem("Review commit result", symbol: "point.3.connected.trianglepath.dotted") { state.inspectCommitResult() }
        }
        PopoverDivider()
        if state.route != .compose && !(previews.isFullscreen && showsComposer) {
        PopoverItem("Load more commits", symbol: "arrow.down", isEnabled: state.mode == .history && showsOverview
                    && state.hasMoreHistory && !state.isHistoryLoading && !state.reachedHistoryLimit) { state.loadMoreHistory() }
        PopoverItem("Next matching commit", symbol: "arrow.down.to.line", isEnabled: state.mode == .history && showsOverview && !state.historyMatches.isEmpty) {
            focusMatch(advance: true)
        }
        }
        if let details = state.details, details.commit.parents.count > 1 {
            PopoverDivider()
            PopoverSectionHeader("Compare with parent")
            ForEach(Array(details.commit.parents.enumerated()), id: \.element) { index, parent in
                PopoverItem(String(format: Chrome.localized("Parent %lld · %@"), index + 1, String(parent.prefix(8))),
                            isChecked: details.parent == parent) { state.chooseParent(parent) }
            }
        }
        if state.diff?.isDeferred == true {
            PopoverItem("Load full file diff", symbol: "text.alignleft", isEnabled: !state.isSelectionLoading) { state.expandDiff() }
        }
        if case .file(let comparison) = state.route {
            PopoverItem("Open current file", symbol: "doc.text", isEnabled: comparison.file.status != "D") {
                guard let root = state.location?.root else { return }
                previews.open(FilePreviewReference(path: root.appendingPathComponent(comparison.file.path).path), context: session.context, pinned: true)
            }
        }
        if state.mode == .history && showsOverview {
            PopoverDivider()
            PopoverItem("Previous graph lanes", symbol: "arrow.left", isEnabled: state.graphOffset > 0) {
                state.graphOffset = max(0, state.graphOffset - graphWidth(width))
            }
            PopoverItem("Next graph lanes", symbol: "arrow.right", isEnabled: state.graphOffset < maximumGraphOffset(width)) {
                state.graphOffset = min(maximumGraphOffset(width), state.graphOffset + graphWidth(width))
            }
            PopoverItem("Widen Git sidebar", symbol: "arrow.left.and.right") { previews.setWidth(max(480, previews.width + 160)) }
        }
        PopoverDivider()
        PopoverItem("Retry Git read", symbol: "arrow.clockwise") { state.refreshReview() }
        if let root = state.location?.root {
            PopoverItem("Copy repository path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(root.path, forType: .string)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let error = state.error {
            message(error)
        } else if state.isNotRepository {
            message(Chrome.localized("This working directory is not a Git repository."))
        } else if state.location == nil || state.status == nil {
            message(Chrome.localized("Reading repository…"))
        } else {
            WorkspaceDetailColumns(isFullscreen: previews.isFullscreen, hasDetail: state.displayedRoute != nil,
                                   fraction: Binding(get: { session.gitDetailFraction }, set: { session.gitDetailFraction = $0 })) { listWidth in
                Group {
                    if state.mode == .changes { changes }
                    else { history(width: listWidth) }
                }
            } detail: {
                ZStack {
                    if state.details != nil || showsCommit {
                        commitDetail
                            .id(state.details?.commit.id)
                            .opacity(showsCommit ? 1 : 0)
                            .disabled(!showsCommit)
                            .allowsHitTesting(showsCommit)
                            .accessibilityHidden(!showsCommit)
                    }
                    if state.routes.contains(.compose) {
                        commitComposer
                            .opacity(showsComposer ? 1 : 0)
                            .disabled(!showsComposer)
                            .allowsHitTesting(showsComposer)
                            .accessibilityHidden(!showsComposer)
                    }
                    if let comparison = displayedComparison, !showsCommit && !showsComposer {
                        fileDiff(comparison).id(comparison)
                    }
                }
            }
            .animation(nil, value: state.displayedRoute)
        }
    }

    @ViewBuilder private var repositoryNotices: some View {
        // The selector carries repository context; only actionable notices need
        // a content row. An empty notice area must not reserve header spacing.
        if !state.automaticRefreshAvailable || state.status?.operations.isEmpty == false
            || session.gitNavigation.writeError != nil || session.gitNavigation.writeNotice != nil || taskIsActive {
            VStack(alignment: .leading, spacing: 3) {
                if !state.automaticRefreshAvailable {
                    Text("Automatic refresh is unavailable. Use the toolbar to refresh.").foregroundStyle(Chrome.secondaryText)
                }
                ForEach(state.status?.operations ?? [], id: \.self) { operation in
                    Text(verbatim: Chrome.localized(operation)).foregroundStyle(.orange)
                }
                writeFeedback
            }
            .font(.ui(.caption)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var stagingFile: GitBrowseFile? {
        guard state.displayedRoute == state.route, case .file(let comparison) = state.route,
              [.working, .untracked, .index].contains(comparison.file.side) else { return nil }
        return state.status?.files.first { $0 == comparison.file }
    }

    private var taskIsActive: Bool { state.location.map { model.hasActiveGitTask(in: $0) } ?? false }
    private var writesAllowed: @MainActor @Sendable () -> Bool {
        let location = state.location
        let model = model
        return { location.map { !model.hasActiveGitTask(in: $0) } ?? false }
    }

    @ViewBuilder private var writeFeedback: some View {
        if let error = session.gitNavigation.writeError {
            Text(verbatim: error).foregroundStyle(Chrome.danger).textSelection(.enabled)
        } else if let notice = session.gitNavigation.writeNotice {
            Text(verbatim: notice).foregroundStyle(Chrome.secondaryText).textSelection(.enabled)
        }
        if taskIsActive { Text(verbatim: GitWriteError.activeTask.localizedDescription).foregroundStyle(Chrome.secondaryText) }
    }

    private var commitComposer: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Commit staged changes").font(.ui(.callout))
                Text(verbatim: state.commitReview?.branch ?? state.commitReview?.revision.head.map {
                    String(format: Chrome.localized("Detached HEAD · %@"), String($0.prefix(8)))
                } ?? Chrome.localized("No commits yet"))
                    .font(.code(size: 11)).foregroundStyle(Chrome.secondaryText).textSelection(.enabled)
                commitMessageInput
                if state.commitMessage.utf8.count > 65_536 || state.commitMessage.utf8.contains(0) {
                    Text(verbatim: GitWriteError.invalidMessage.localizedDescription).foregroundStyle(Chrome.danger)
                }
                if state.isWriting { Text("Updating Git…").foregroundStyle(Chrome.secondaryText) }
                if let blocker = state.writeBlocker, !state.isWriting {
                    Text(verbatim: blocker).foregroundStyle(Chrome.secondaryText)
                } else if !state.reviewIsCurrent {
                    Text(verbatim: GitWriteError.changed.localizedDescription).foregroundStyle(.orange)
                }
                writeFeedback
                Text(verbatim: String(format: Chrome.localized("%lld staged files"), state.commitReview?.files.count ?? 0))
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                if state.commitReview?.files.isEmpty == true {
                    Text("Stage files using their row buttons, their diff toolbar, or Stage all changes in the top menu.")
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                }
                ForEach(state.commitReview?.files ?? []) { file in
                    fileRow(file, inComposer: true).padding(.horizontal, -12)
                    inlineDiff(for: file)
                }
            }
            .font(.ui(.callout)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("git-browser.commit-review")
    }

    private var commitMessageInput: some View {
        ChromeTextEditor(text: Binding(get: { state.commitMessage }, set: { state.commitMessage = $0 }),
                         label: "Commit message", placeholder: state.isGeneratingMessage ? "Writing a message…" : nil)
            .disabled(state.isWriting)
            .accessibilityLabel(Text("Commit message"))
            .accessibilityIdentifier("git-browser.commit-message")
            .padding(6)
            .padding(.bottom, Chrome.capsuleHeight + 6)
            .frame(height: 160)
            .chromeGlassInputSurface()
            .overlay(alignment: .bottomTrailing) {
                ChromeIconButton(symbol: "light.beacon.max", isEnabled: !state.isGeneratingMessage && state.reviewIsCurrent
                                 && state.commitReview?.files.isEmpty == false && !state.isWriting
                                 && model.textEngine(preferring: model.thread(session.context.threadID)?.provider) != nil,
                                 help: "Write a message from staged changes") { generateMessage() }
                    .accessibilityIdentifier("git-browser.generate-message")
                    .padding(6)
            }
    }

    private func generateMessage() {
        guard let engine = model.textEngine(preferring: model.thread(session.context.threadID)?.provider) else { return }
        let instructions = model.settings.commitInstructions
        state.generateMessage { summary, patch, directory in
            await TextGeneration.commitMessage(summary: summary, patch: patch, instructions: instructions, engine: engine, directory: directory)
        }
    }

    private var changes: some View {
        VStack(spacing: 0) {
            Text(verbatim: checkoutBranchTitle ?? Chrome.localized("No commits yet"))
                .font(.ui(.callout)).foregroundStyle(Chrome.secondaryText)
                .lineLimit(1).truncationMode(.middle)
                .help(Text(verbatim: checkoutBranchTitle ?? Chrome.localized("No commits yet")))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
            repositoryNotices
            if state.filteredFiles.isEmpty {
                message(Chrome.localized((state.status?.files.isEmpty ?? false)
                    ? (state.status?.operations.isEmpty == true ? "Working tree clean" : "No file changes. A Git operation is still in progress.")
                    : "No files match this group or search."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach([GitChangeSide.index, .conflict, .working, .untracked], id: \.self) { side in
                            let files = state.filteredFiles.filter { $0.side == side }
                            if !files.isEmpty {
                                HStack {
                                    Text(verbatim: Chrome.localized(groupTitle(side)))
                                    Spacer()
                                    Text(verbatim: String(files.count)).monospacedDigit()
                                }
                                .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(.horizontal, 12).padding(.vertical, 8)
                                ForEach(files) { file in fileRow(file) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func groupTitle(_ side: GitChangeSide) -> String {
        switch side {
        case .index: "Staged changes"
        case .working: "Unstaged changes"
        case .untracked: "Untracked files"
        case .conflict: "Conflicts"
        case .commit: "Changed files"
        }
    }

    private func fileRow(_ file: GitBrowseFile, inComposer: Bool = false) -> some View {
        let isInline = previews.isFullscreen && (file.side == .commit || inComposer)
        let isExpanded = isInline && displayedComparison?.file == file
        return HStack(spacing: 8) {
            Button {
                if isInline { state.toggleInlineFile(file, inComposer: inComposer) }
                else { state.openFile(file, replacingDetail: previews.isFullscreen, inComposer: inComposer) }
            } label: {
                HStack(spacing: 8) {
                    if isInline {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.symbol(.caption2)).foregroundStyle(Chrome.secondaryText).frame(width: 10)
                    }
                    Text(verbatim: file.status).font(.code(size: 11)).foregroundStyle(statusColor(file))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: file.name).font(.ui(.callout)).lineLimit(1).truncationMode(.middle)
                        let detail = file.oldPath.map { $0 + " → " + file.path } ?? file.directory
                        if !detail.isEmpty {
                            Text(verbatim: detail)
                                .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Chrome.capsuleHeight, alignment: .leading)
                    if file.side == .commit {
                        GitCommitFileStatistics(state: state, comparison: state.comparison(for: file), isPresented: isPresented && state.isPresented && showsCommit)
                    } else {
                        GitLineStatisticsLabel(value: inComposer && !state.reviewIsCurrent
                                               ? nil : state.workspaceStatistics?.files[file.id],
                                               isLoading: state.isLoading || state.isStatisticsLoading)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: file.oldPath.map { $0 + " → " + file.path } ?? file.path))
            .accessibilityLabel(Text(verbatim: String(format: Chrome.localized(isExpanded ? "Hide diff: %@" : "View diff: %@"), file.path)))
            if file.side != .commit {
                ChromeIconButton(symbol: file.side == .index ? "minus" : "plus",
                                 isEnabled: state.writeBlocker == nil && !taskIsActive && file.side != .conflict
                                    && state.status?.files.contains(file) == true && (!inComposer || state.reviewIsCurrent),
                                 help: file.side == .index ? "Unstage this file" : "Stage this file") {
                    state.stage(file, unstaging: file.side == .index, allowed: writesAllowed)
                }
                .accessibilityIdentifier("git-browser.stage-file.\(file.id)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(previews.isFullscreen && displayedComparison?.file == file ? Chrome.overlay(0.06) : .clear)
    }

    private func statusColor(_ file: GitBrowseFile) -> Color {
        if file.side == .conflict { return .orange }
        switch file.status {
        case "M": return .yellow
        case "A": return Chrome.success
        case "D": return Chrome.danger
        case "R": return .blue
        case "C": return .purple
        case "T": return .pink
        case "?": return .cyan
        default: return Chrome.secondaryText
        }
    }

    private func history(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    repositoryNotices
                    if !state.query.isEmpty {
                        Text(verbatim: String(format: Chrome.localized("%lld matching commits in loaded history"), state.historyMatches.count))
                            .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(.horizontal, 12).padding(.bottom, 6)
                    }
                    if maximumGraphOffset(width) > 0 {
                        Text(verbatim: String(format: Chrome.localized("%lld graph lanes · drag the graph or use the toolbar to move between lanes."), state.graph.laneCount))
                            .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(.horizontal, 12).padding(.bottom, 6)
                    }
                    ForEach(Array(zip(state.commits, state.graph.rows)), id: \.0.id) { commit, row in
                        GitCommitRow(commit: commit, graph: row, references: state.referenceLabels[commit.id] ?? [],
                                     isHead: state.source?.head == commit.id, graphWidth: graphWidth(width),
                                     graphOffset: min(state.graphOffset, maximumGraphOffset(width)),
                                     isMatch: state.matches(commit.subject + " " + commit.author + " " + commit.id),
                                     isSelected: state.historyAnchor == commit.id,
                                     showsDate: width >= 340,
                                     onSelect: { state.openCommit(commit) },
                                     onDrag: { delta, ended in
                                         if dragOrigin == nil { dragOrigin = state.graphOffset }
                                         state.graphOffset = min(maximumGraphOffset(width), max(0, (dragOrigin ?? 0) - delta))
                                         if ended { dragOrigin = nil }
                                     })
                            .id(commit.id)
                    }
                    if state.hasMoreHistory || state.graph.pendingParents.contains(where: { $0 != nil }) {
                        GitGraphBoundary(parents: state.graph.pendingParents, graphOffset: min(state.graphOffset, maximumGraphOffset(width)), graphWidth: graphWidth(width))
                        Text(verbatim: Chrome.localized(state.reachedHistoryLimit
                            ? "The history display limit is reached. Narrow the history scope to continue browsing."
                            : state.hasMoreHistory ? "More history is available. Load more commits from the toolbar menu."
                            : "Some parent commits are outside the available history."))
                            .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(12)
                    }
                    if state.isHistoryLoading && state.commits.isEmpty { message(Chrome.localized("Reading commit graph…")) }
                    else if let error = state.historyError { message(error) }
                    else if state.commits.isEmpty { message(Chrome.localized("No commits in this history scope.")) }
                }
            }
            .onAppear { if let anchor = state.historyAnchor { proxy.scrollTo(anchor, anchor: .top) } }
            .onChange(of: state.commits.count) { old, _ in
                if old == 0, let anchor = state.historyAnchor { proxy.scrollTo(anchor, anchor: .top) }
            }
            .onChange(of: scrollRequest) { if let target = scrollTarget { proxy.scrollTo(target, anchor: .center) } }
        }
    }

    private var historyScopeTitle: String {
        if state.historyReference == "HEAD" { return Chrome.localized("Current checkout") }
        if let name = state.historyReference { return state.source?.references.first { $0.name == name }?.title ?? name }
        return Chrome.localized("All branches and tags")
    }

    private func graphWidth(_ width: CGFloat) -> CGFloat { min(max(44, CGFloat(state.graph.laneCount) * 14 + 18), min(120, width * 0.32)) }
    private func maximumGraphOffset(_ width: CGFloat) -> CGFloat { max(0, CGFloat(state.graph.laneCount) * 14 + 18 - graphWidth(width)) }

    private func focusMatch(advance: Bool = false) {
        guard state.mode == .history, showsOverview else { return }
        let matches = state.historyMatches
        guard !matches.isEmpty else { return }
        if advance { nextMatch = (nextMatch + 1) % matches.count }
        else { nextMatch = 0 }
        scrollTarget = matches[nextMatch % matches.count]; scrollRequest &+= 1
    }

    private var commitDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let error = state.selectionError, showsCommit { message(error) }
                else if let details = state.details {
                    Text(verbatim: details.commit.id).font(.code(size: 11)).foregroundStyle(Chrome.secondaryText).textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: details.commit.author).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text(details.commit.date, format: .dateTime).foregroundStyle(Chrome.secondaryText).fixedSize()
                    }
                    .font(.ui(.callout))
                    Text(verbatim: details.message).font(.ui(.callout)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    if details.files.isEmpty { Text("No file changes against this parent").foregroundStyle(Chrome.secondaryText) }
                    ForEach(details.files) { file in
                        fileRow(file).padding(.horizontal, -12)
                        inlineDiff(for: file)
                    }
                } else { message(Chrome.localized("Reading commit details…")) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func inlineDiff(for file: GitBrowseFile) -> some View {
        if previews.isFullscreen, let comparison = displayedComparison, comparison.file == file {
            PopoverScroll(maxHeight: 360) {
                fileDiff(comparison, inline: true)
            }
            .id(comparison)
            .padding(.bottom, 4)
        }
    }

    private func fileDiff(_ comparison: GitFileComparison, inline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !inline {
                Text(verbatim: comparison.file.name)
                    .font(.ui(.callout)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .help(Text(verbatim: comparison.file.path))
                    .accessibilityLabel(Text(verbatim: comparison.file.path))
                    .padding(12)
            }
            writeFeedback.font(.ui(.caption)).padding(.horizontal, 12)
            if let error = state.selectionError { message(error) }
            else if let file = state.diff {
                if file.isDeferred {
                    message(Chrome.localized("This large diff is deferred. Load the full file diff from the toolbar menu."))
                } else if file.isBinary || file.hunks.isEmpty {
                    message(Chrome.localized(file.isBinary ? "Binary file" : "No text changes"))
                } else if inline {
                    DiffLinesView(file: file, collapsesLongDiff: false).equatable().padding(.bottom, 8)
                } else {
                    ScrollView { DiffLinesView(file: file, collapsesLongDiff: false).equatable().padding(.bottom, 8) }
                }
            } else { message(Chrome.localized("Loading diff…")) }
        }
    }

    private func message(_ text: String) -> some View {
        Text(verbatim: text).font(.ui(.callout)).foregroundStyle(Chrome.secondaryText).textSelection(.enabled)
            .multilineTextAlignment(.center).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GitLineStatisticsLabel: View {
    let value: GitLineStatistics?
    var isLoading = false
    var totals = false

    var body: some View {
        Group {
            if let value {
                if value.isBinary && value.additions == 0 && value.deletions == 0 && !totals {
                    Text("Binary file").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                } else {
                    DiffStatLabel(additions: value.additions, deletions: value.deletions)
                }
            } else {
                Text(verbatim: isLoading ? "…" : "—")
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
            }
        }
        .fixedSize()
        .help(Text(verbatim: Chrome.localized(help)))
    }

    private var help: String {
        if value == nil { return isLoading ? "Reading line changes…" : "Line changes are unavailable. Refresh to try again." }
        return totals ? "Totals compare HEAD with the working tree, including new files. Staging does not change them. Binary contents have no line counts."
            : (value?.isBinary == true ? "Binary contents have no line counts." : "Line changes for this comparison")
    }
}

/// History is immutable and only visible detail rows need counts. Hiding the
/// panel cancels each native read and refuses any late, non-cooperative result.
private struct GitCommitFileStatistics: View {
    let state: GitWorkspaceStore
    let comparison: GitFileComparison
    let isPresented: Bool
    @State private var result: GitLineStatistics?
    @State private var resultComparison: GitFileComparison?
    @State private var isLoading = false

    var body: some View {
        GitLineStatisticsLabel(value: resultComparison == comparison ? result : nil, isLoading: isLoading)
            .task(id: isPresented ? comparison : nil) {
                isLoading = false
                guard isPresented else { return }
                if resultComparison == comparison, result != nil { return }
                result = nil; resultComparison = nil; isLoading = true
                do {
                    let value = try await state.statistics(for: comparison)
                    guard !Task.isCancelled else { return }
                    result = value; resultComparison = comparison; isLoading = false
                } catch {
                    if !Task.isCancelled { isLoading = false }
                }
            }
    }
}

/// The sidebar uses the shared branch rows at their natural, screen-bounded width.
/// Unusually long reference names wrap rather than losing their middle.
struct GitHistoryReferenceMenu: View {
    let references: [GitHistoryReference]
    let selection: String?
    let onSelect: (String?) -> Void

    var body: some View {
        PopoverItem("All branches and tags", isChecked: selection == nil) { onSelect(nil) }
        PopoverItem("Current checkout", isChecked: selection == "HEAD") { onSelect("HEAD") }
        PopoverDivider()
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(references) { ref in
                PopoverItem(ref.title, text: Text(verbatim: ref.title), isChecked: selection == ref.name, wrapsTitle: true) {
                    onSelect(ref.name)
                }
                .accessibilityLabel(Text(verbatim: ref.title))
            }
        }
    }
}

/// Match the shared choice row's font and horizontal space. Cache one bounded
/// reference snapshot so graph panning does not remeasure every branch name.
@MainActor
final class GitReferenceMenuSizing {
    private var references: [GitHistoryReference]?
    private var pointSize: CGFloat?
    private var contentWidth: CGFloat = 210

    func width(references: [GitHistoryReference], maximumWidth: CGFloat) -> CGFloat {
        let pointSize = TypeScale.shared.ui(TypeScale.stockPointSize(.body))
        if self.references != references || self.pointSize != pointSize {
            let font = NSFont.systemFont(ofSize: pointSize)
            let titles = [Chrome.localized("All branches and tags"), Chrome.localized("Current checkout")]
            let measure: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: [.font: font]).width }
            let longest = references.reduce(titles.map(measure).max() ?? 0) { max($0, measure($1.title)) }
            // Checkmark, two gaps, spacer minimum, row padding and menu padding.
            let horizontalSpace: CGFloat = 14 + 2 * 8 + 16 + 2 * 8 + 2 * 6
            contentWidth = max(210, ceil(longest) + horizontalSpace)
            self.references = references
            self.pointSize = pointSize
        }
        return min(contentWidth, maximumWidth)
    }
}
