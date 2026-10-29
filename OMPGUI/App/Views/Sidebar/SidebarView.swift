import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Shown from the chat's Threads button while the sidebar is hidden: the same list in a
    /// popover, without the window buttons' clearance or the window-dragging background, and
    /// picking a thread closes it.
    var inPopover = false
    var dismiss: (() -> Void)? = nil

    @State private var search = ""
    @State private var isAddingProject = false
    @State private var renaming: ChatThread?
    @State private var renameText = ""
    /// The thread whose delete popover is open, by id: the popover's binding compares two
    /// UUIDs and never reaches into a thread snapshot that may since have changed hands.
    @State private var pendingDeletionID: UUID?
    /// The thread whose archive question is open, by id, the same way.
    @State private var pendingArchiveID: UUID?
    /// A delete the popover confirmed, carried out once the popover has closed (see
    /// `confirmDeletion` and `deletePopover`).
    @State private var confirmedDeletion: ConfirmedDeletion?
    /// Whether a delete popover's content is on screen, from its appearance to its
    /// disappearance: a confirmed delete waits for it to go. One flag serves every row,
    /// since only one delete popover is ever open.
    @State private var isDeletePopoverShown = false
    /// Carries context-menu intents (rename, delete) outside any row's @State, so an AppKit
    /// menu's callbacks never retain a row's state storage. The menu posts a value-type
    /// request here (holding this box weakly); the list takes it up below.
    @State private var menuRequests = SidebarMenuRequests()
    /// The live reorder, exactly the queue's: the grabbed row follows the pointer, its
    /// helpers with it, and neighbours slide across as its centre passes theirs.
    @State private var drag = RowDrag<UUID>()
    @State private var projectDrag = RowDrag<UUID>()
    @State private var projectFrames = RowFrames()
    @State private var projectDragPeers: DragPeers?
    private static let listTopInset: CGFloat = 12
    /// Every row's height by its item id. A thread's slot is its own row plus the helper
    /// rows under it, so a dragged row crosses a neighbour with helpers in one go. Kept out
    /// of observation like the frames below: every row reports its height as the list lays
    /// out, and only a drag ever reads them, so a report must not re-run the list.
    @State private var rowHeights = RowHeights()
    /// Where the Projects header sits in the list, measured as the list lays out: a
    /// project drag lands its row right under that header, which sits below the task
    /// rows whenever Tasks lead. Kept out of observation like the heights.
    @State private var projectsHeaderTop = HeaderTop()
    /// The list's frame in the window, for a settling row's glide: it is clipped to the
    /// list and heads for its edge when its new place is out of view. Kept out of
    /// observation the way a row's frame is: resizing updates it, only a settle reads it.
    @State private var listFrame = FrameHolder()
    /// Every open thread row's frame in the list, by thread id, for the one drag gesture
    /// below to find the row under the pointer at the grab. Kept out of observation like
    /// the heights: the rows report as they lay out, only a grab reads them.
    @State private var rowFrames = RowFrames()
    /// The grabbed row's peers and their slot heights, taken once at the grab and again
    /// after each swap, so a pointer move never rebuilds the list to find them.
    @State private var dragPeers: DragPeers?
    /// The built list, kept while its inputs stand (see `SidebarItemCache`): a render
    /// that changed no thread, project or setting hands back the same items.
    @State private var itemCache = SidebarItemCache()
    /// While the list scrolls its rows take no hover and no clicks, the way the timeline's
    /// do: a click cannot land on a moving row anyway, and skipping the hover states keeps
    /// a scroll at one layout pass per frame.
    @State private var isListScrolling = false
    /// Settles `isListScrolling` back to false 150 ms after the last scroll movement, so
    /// wheel ticks (which report no scroll phase) re-arm the freeze instead of flickering it.
    @State private var scrollSettle: Task<Void, Never>?

    private var query: String {
        search.trimmed
    }

    /// The list's own coordinate space: the rows report their frames in it and the drag
    /// gesture reads its locations in it, whatever the scroll position.
    private nonisolated static let listSpace = "sidebar-list"

    var body: some View {
        // Where every thread sits, worked out once per pass: the grouping and the list below
        // are rebuilt only when this changes, not on every field change of every thread.
        let placements = threadPlacements
        let helpers = helpersByParent(placements: placements)
        VStack(alignment: .leading, spacing: 0) {
            if !inPopover {
                HStack {
                    Spacer(minLength: Chrome.trafficLightLeading + Chrome.trafficLightsWidth + Chrome.trafficLightClearance)
                    SidebarToggleButton()
                }
                .padding(.trailing, Chrome.chromeHorizontalPadding)
                .frame(height: Chrome.capsuleHeight)
                .padding(.top, Chrome.chromeTopPadding)
            }

            HStack(spacing: 6) {
                if inPopover {
                    SidebarSearchField(
                        text: $search,
                        prompt: Chrome.localized("Search threads"),
                        onSubmit: {
                            if let first = searchResults(helpers: helpers).first?.threads.first {
                                model.selectedThreadID = first.id
                            }
                        },
                        onMove: { moveSearchSelection(by: $0, helpers: helpers) }
                    )
                } else {
                    ChromeIconButton(symbol: "plus.circle", prominent: true, help: Chrome.localized("New thread") + ShortcutStore.hint(for: .newThread)) {
                        model.newThread()
                    }
                    ChromeIconButton(symbol: "magnifyingglass", prominent: true, help: "Search threads") {
                        model.isCommandPalettePresented = true
                    }
                }
                ChromeIconButton(symbol: "bell", isActive: model.settings.sidebarActivityView, prominent: true,
                                 help: Chrome.localized(model.settings.sidebarActivityView ? "Turn off activity view" : "Turn on activity view") + ShortcutStore.hint(for: .toggleActivityView)) {
                    withAnimation(Chrome.panelSlide) { model.settings.sidebarActivityView.toggle() }
                }
                .accessibilityLabel(Text("Activity view"))
                .accessibilityValue(Text(verbatim: Chrome.localized(model.settings.sidebarActivityView ? "On" : "Off")))
                if !inPopover {
                    Spacer(minLength: Chrome.trafficLightClearance)
                }
            }
            .padding(.leading, inPopover ? Chrome.listInset : Chrome.listInset + Chrome.rowHorizontalPadding + (Chrome.iconSize - Chrome.capsuleHeight) / 2)
            .padding(.trailing, Chrome.listInset)
            .padding(.top, inPopover ? 12 : 0)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if query.isEmpty {
                            // One list for both layouts: a thread keeps its row when the layout changes, so the
                            // row grows or shrinks and slides to its new place instead of being replaced.
                            ForEach(listItems(placements: placements, helpers: helpers)) { item in
                                itemView(item)
                                    .transition(rowTransition(item))
                            }
                        } else {
                            searchList(helpers: helpers)
                        }
                    }
                    .allowsHitTesting(!isListScrolling)
                    // Adding or deleting a thread opens and closes its space with the same motion as every other row.
                    .animation(Chrome.panelSlide, value: model.threads.count)
                    .animation(Chrome.panelSlide, value: model.projects.map(\.isExpanded))
                    .animation(Chrome.panelSlide, value: model.settings.settledCollapsed)
                    .animation(Chrome.panelSlide, value: model.settings.sidebarSectionOrder)
                    .padding(.horizontal, Chrome.listInset)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .coordinateSpace(name: Self.listSpace)
                    .pointerStyle(drag.id != nil || projectDrag.id != nil ? .grabActive : nil)
                    // One drag gesture for the whole list, ahead of every row's own click: the
                    // row under the pointer at the grab is the one that moves (a settled or
                    // helper row reports no frame, so a drag from one goes nowhere), and a
                    // plain click still reaches the row. Off while searching: nothing to reorder.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
                            .onChanged { value in
                                if !model.settings.sidebarActivityView,
                                   let id = projectDrag.id ?? projectFrames.thread(at: value.startLocation) {
                                    projectDragChanged(id, translation: value.translation.height)
                                } else if let id = drag.id ?? rowFrames.thread(at: value.startLocation) {
                                    dragChanged(id, translation: value.translation.height)
                                }
                            }
                            .onEnded { _ in dragEnded(); projectDragEnded() },
                        isEnabled: query.isEmpty
                    )
                }
                .scrollIndicators(.never)
                .onGeometryChange(for: CGRect.self, of: Self.windowFrame) { listFrame.note($0) }
                .onScrollPhaseChange { _, phase in
                    if phase == .idle {
                        scrollSettle?.cancel()
                        isListScrolling = false
                    } else {
                        noteListScroll()
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
                    if old != new { noteListScroll() }
                }
                // A thread that has just moved to another project is brought into view, so the
                // list shows where it landed instead of only closing up where it was.
                .onChange(of: model.sidebarRevealThreadID) { _, reveal in
                    guard let reveal else { return }
                    model.sidebarRevealThreadID = nil
                    guard let thread = model.thread(reveal) else { return }
                    withAnimation(Chrome.panelSlide) {
                        proxy.scrollTo(SidebarItem.id(for: thread), anchor: .center)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(title: "Settings", action: { WindowManager.shared.showSettings() }) {
                    SidebarIconBadge { SidebarSymbol("gear", scale: 1.15) }
                        .overlay(alignment: .topTrailing) {
                            if UpdateChecker.shared.updateAvailable {
                                UpdateAvailableDot()
                            }
                        }
                }
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { if !inPopover { WindowDragArea() } }
        // Read only in the popover: the list itself has no reason to re-render on selection.
        .onChange(of: inPopover ? model.selectedThreadID : nil) { if inPopover { dismiss?() } }
        .onChange(of: menuRequests.rename) { _, thread in
            guard let thread else { return }
            menuRequests.rename = nil
            renameText = thread.title
            renaming = thread
        }
        .onChange(of: menuRequests.delete) { _, thread in
            guard let thread else { return }
            menuRequests.delete = nil
            if model.settings.confirmBeforeDeleting {
                pendingDeletionID = thread.id
            } else {
                model.delete(thread.id)
            }
        }
        // The shortcut's question lands on the thread's own row.
        .onChange(of: model.archiveRequest) { _, request in
            guard let request, model.thread(request.threadID) != nil else { return }
            model.archiveRequest = nil
            pendingArchiveID = request.threadID
        }
    }

    /// The delete question, asked in a popover on the row itself rather than a sheet over
    /// the window. Clicking away or pressing Escape keeps the thread.
    ///
    /// The binding is built on the thread's id alone, and the confirmed delete does not run
    /// while the popover is up: the item closes the popover and the delete waits for its
    /// content to have gone (see `confirmDeletion`). Before, the delete ran a turn after
    /// the close, which could be while the popover was still going: it removed the row the
    /// popover hangs on, and in the Threads popover the whole list with it (the delete
    /// selects a neighbour, which dismisses the list); the popover's dismissal then read
    /// this binding on a view already torn down and crashed in the getter.
    private func deletePopover<Row: View>(for thread: ChatThread, on row: Row) -> some View {
        let threadID = thread.id
        return row.chromePopover(
            isPresented: Binding(
                get: { pendingDeletionID == threadID },
                set: { if !$0, pendingDeletionID == threadID { pendingDeletionID = nil } }
            ),
            arrowEdge: .trailing
        ) {
            DeleteThreadPopover(thread: model.thread(threadID) ?? thread) { removeWorktree in
                confirmDeletion(of: threadID, removeWorktree: removeWorktree)
            }
            .onAppear { isDeletePopoverShown = true }
            .onDisappear {
                isDeletePopoverShown = false
                carryOutConfirmedDeletion()
            }
        }
    }

    /// The rename field, asked in a popover on the row itself like the delete question.
    /// Clicking away keeps the thread's title.
    private func renamePopover<Row: View>(for thread: ChatThread, on row: Row) -> some View {
        let threadID = thread.id
        return row.chromePopover(
            isPresented: Binding(
                get: { renaming?.id == threadID },
                set: { if !$0 { renaming = nil } }
            ),
            arrowEdge: .bottom
        ) {
            RenameThreadPopover(title: renameText, onRename: { model.rename(threadID, to: $0); renaming = nil }, onCancel: { renaming = nil })
                .presentedChrome()
        }
    }

    /// The popover's answer. Its item has closed the popover (through the binding above)
    /// and calls here a turn later, so the popover may be on its way out or already gone:
    /// the delete runs now if it is gone, and when it goes otherwise. Clicking away
    /// instead confirms nothing.
    private func confirmDeletion(of id: UUID, removeWorktree: Bool) {
        confirmedDeletion = ConfirmedDeletion(threadID: id, removeWorktree: removeWorktree)
        pendingDeletionID = nil
        pendingArchiveID = nil
        if !isDeletePopoverShown { carryOutConfirmedDeletion() }
    }

    /// The shortcut's question on a row: archive, which Return answers, or delete. The
    /// delete goes the delete popover's way (see `confirmDeletion`), so the row the
    /// question hangs on is gone only once the popover is.
    private func archivePopover<Row: View>(for thread: ChatThread, on row: Row) -> some View {
        let threadID = thread.id
        return row.chromePopover(
            isPresented: Binding(
                get: { pendingArchiveID == threadID },
                set: { if !$0, pendingArchiveID == threadID { pendingArchiveID = nil } }
            ),
            arrowEdge: .trailing
        ) {
            ArchiveThreadPopover(
                thread: model.thread(threadID) ?? thread,
                onArchive: {
                    pendingArchiveID = nil
                    withAnimation(Chrome.panelSlide) { model.archive(threadID) }
                },
                onDelete: { confirmDeletion(of: threadID, removeWorktree: false) },
                onDismiss: { pendingArchiveID = nil }
            )
            .onAppear { isDeletePopoverShown = true }
            .onDisappear {
                isDeletePopoverShown = false
                carryOutConfirmedDeletion()
            }
        }
    }



    /// Runs the delete the popover confirmed, once the popover has closed and a turn
    /// later: the model changes outside the view update that removed the presentation,
    /// and the rows it takes away are no longer anchoring anything. A popover closed by a
    /// click away has nothing confirmed and does nothing here.
    private func carryOutConfirmedDeletion() {
        guard let confirmed = confirmedDeletion else { return }
        confirmedDeletion = nil
        let model = model
        Task { @MainActor in
            model.delete(confirmed.threadID, removeWorktree: confirmed.removeWorktree)
        }
    }

    private struct ConfirmedDeletion {
        let threadID: UUID
        let removeWorktree: Bool
    }

    /// How a row enters and leaves the list. A settled thread's row, the Settled header and
    /// the gaps ride the list's own motion: they change in the same pass the space opens and
    /// the count updates, so none of them waits out the handover delay that covers a reopen's
    /// ghost. Every other row keeps that delay.
    private func rowTransition(_ item: SidebarItem) -> AnyTransition {
        switch item.kind {
        case .thread(let thread, _, _, _, _):
            return thread.isSettled ? .opacity : .sidebarRow
        case .settledHeader(_, _), .gap(_):
            return .opacity
        default:
            return .sidebarRow
        }
    }

    @ViewBuilder
    private func itemView(_ item: SidebarItem) -> some View {
        let connector = ThreadRowMetrics.connector(
            showsProjectIcon: model.settings.sidebarActivityView && model.settings.activityThreadStyle == .icon
        )
        switch item.kind {
        case .gap(let height):
            Color.clear.frame(height: height)
        case .section(let isProjects):
            sectionHeader(isProjects: isProjects)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.listSpace)) }) { frame in
                    rowHeights.note(item.id, frame.height)
                    if isProjects { projectsHeaderTop.note(frame.minY) }
                }
        case .empty(let title):
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Chrome.rowHorizontalPadding).padding(.vertical, 8)
        case .project(let project, let count):
            ProjectRow(snapshot: project, count: count)
                .offset(y: projectDrag.id == project.id ? projectDrag.visualOffset : 0)
                .zIndex(projectDrag.id == project.id ? 1 : 0)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.listSpace)) }) { frame in
                    projectFrames.note(project.id, frame)
                    rowHeights.note(item.id, frame.height)
                }
                .onDisappear { projectFrames.forget(project.id) }
        case .showMore(let projectID):
            Button {
                withAnimation(Chrome.panelSlide) { model.showMoreProjectThreads(projectID) }
            } label: {
                Text("Show more conversations")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(Text("Show up to 5 more conversations"))
            .accessibilityLabel(Text("Show up to 5 more conversations"))
            .padding(.leading, connector.lineX)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .header(let title, let isFirst):
            ActivityHeader(title: title, isFirst: isFirst)
        case .settledHeader(let count, let isFirst):
            SettledHeader(count: count, isFirst: isFirst)
                .padding(.leading, item.isNested ? ThreadRowMetrics.folderIndent : 0)
        case .thread(let thread, let projectName, let projectIcon, let peers, let hasHelpers):
            reorderableRow(thread, projectName: projectName, projectIcon: projectIcon, peers: peers, hasHelpers: hasHelpers, isNested: item.isNested)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.listSpace)) }) { frame in
                    rowHeights.note(item.id, frame.height)
                    // A settled row keeps its place among the settled; there is nothing to reorder.
                    if !thread.isSettled { rowFrames.note(thread.id, frame) }
                }
                // A row that has left the list (scrolled out, settled, deleted) is not there to grab.
                .onDisappear { rowFrames.forget(thread.id) }
        case .helper(let thread, let isLast):
            archivePopover(for: thread, on: deletePopover(for: thread, on: SidebarHelperRow(
                snapshot: thread,
                isLast: isLast,
                connector: connector,
                menuRequests: menuRequests,
                onFold: { fold(thread.parentThreadID) },
                onRename: {
                    // The live record: the item's snapshot does not follow a title change.
                    let live = model.thread(thread.id) ?? thread
                    renameText = live.title
                    renaming = live
                },
                onDelete: {
                    if model.settings.confirmBeforeDeleting {
                        pendingDeletionID = thread.id
                    } else {
                        model.delete(thread.id)
                    }
                }
            ).equatable()))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights.note(item.id, $0) }
            .modifier(RidesWithDraggedParent(parentID: thread.parentThreadID, drag: drag))
        case .headCards(let parent, let heads):
            HeadCardsRow(
                parentSnapshot: parent,
                headSnapshots: heads,
                rowWidth: model.sidebar.width - 2 * Chrome.listInset,
                connector: connector,
                menuRequests: menuRequests,
                onFold: { fold(parent.id) }
            )
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights.note(item.id, $0) }
            .modifier(RidesWithDraggedParent(parentID: parent.id, drag: drag))
        case .helperStub(let parent, let helpers):
            HelperStubRow(parentSnapshot: parent, helperSnapshots: helpers, connector: connector) { fold(parent.id) }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights.note(item.id, $0) }
                .modifier(RidesWithDraggedParent(parentID: parent.id, drag: drag))
        }
    }

    /// Where every thread sits in the list (see `ThreadPlacement`): the key the grouping and
    /// the list below are kept under. Kept while a cheap fingerprint of the threads stands,
    /// so an unrelated re-render (selection, hover) does not rebuild placements for
    /// hundreds of threads.
    @State private var placementCache = PlacementCache()
    private var threadPlacements: [ThreadPlacement] {
        placementCache.placements(for: model.threads)
    }

    /// A scroll movement (re)arms the list's scroll freeze: rows take no hover or clicks
    /// for 150 ms after the last movement, covering wheel ticks, which report no phase.
    private func noteListScroll() {
        // The list's whole body -- placements, grouping, the row diff -- is what a write to
        // this flag re-evaluates, and scroll geometry reports every wheel tick: set it once
        // per scroll, not once per frame of one. The settle task still re-arms on every
        // movement, so the freeze lifts 150 ms after the last one, as before.
        if !isListScrolling { isListScrolling = true }
        scrollSettle?.cancel()
        scrollSettle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, isListScrolling else { return }
            isListScrolling = false
        }
    }

    /// Every helper by the thread it hangs under, worked out once for the whole list. Asking
    /// the model per row walked the library once per row, so a long list did that work for
    /// every row in it; the rows are handed their own helpers instead. Kept while the
    /// placements stand: a render that moved no thread reuses the last grouping.
    private func helpersByParent(placements: [ThreadPlacement]) -> [UUID: [ChatThread]] {
        itemCache.helpers(for: placements) {
            var grouped: [UUID: [ChatThread]] = [:]
            // Heads count while they are still in the lead's panel too (see
            // `AppModel.helpers(of:)`).
            for thread in model.threads where !thread.isArchived && thread.hydra?.nativeCanonicalID == nil
                && (!thread.isInPanel || thread.isHydraHead) {
                guard let parentID = thread.parentThreadID else { continue }
                grouped[parentID, default: []].append(thread)
            }
            // Newest first, like the threads around them (see `AppModel.helpers(of:)`).
            return grouped.mapValues { $0.sorted { $0.createdAt > $1.createdAt } }
        }
    }

    /// The list in the current layout, built only when something that places a row has
    /// changed: where the threads sit (`ThreadPlacement`), the projects, which threads need
    /// attention (they head the activity layout), the layout flag or the settled fold. A
    /// title or a head's progress note reaches its row through the model's per-thread cell
    /// (see `SidebarThreadRow.thread`) without the list being built again.
    private func listItems(placements: [ThreadPlacement], helpers: [UUID: [ChatThread]]) -> [SidebarItem] {
        let activity = model.settings.sidebarActivityView
        let tasks = activity ? model.activityThreads : (model.settings.tasksCollapsed ? [] : model.standaloneTasks)
        let attention = Set(tasks.filter { needsAttention($0) }.map(\.id))
        let autoHidesIdleHeads = model.settings.hydraAutoHidesIdleHeads
        let parentsShowingHeads = autoHidesIdleHeads
            ? Set(helpers.compactMap { parent, heads in hasRunningHead(heads) ? parent : nil })
            : []
        let key = SidebarItemCache.Key(
            placements: placements,
            projects: model.projects,
            projectThreadLimits: model.projectThreadLimits,
            attention: attention,
            activityView: activity,
            activityThreadStyle: model.settings.activityThreadStyle,
            settledCollapsed: model.settings.settledCollapsed,
            autoHidesIdleHeads: autoHidesIdleHeads,
            parentsShowingHeads: parentsShowingHeads,
            projectsCollapsed: model.settings.projectsCollapsed,
            tasksCollapsed: model.settings.tasksCollapsed,
            sectionOrder: model.settings.sidebarSectionOrder,
            draggingProject: projectDrag.id,
            today: activity ? Calendar.current.startOfDay(for: MinuteClock.shared.now) : nil
        )
        return itemCache.items(for: key) {
            if activity {
                return taskItems(tasks, helpers: helpers, attention: attention, activity: true)
            }
            var projectsSection = [SidebarItem(id: "section-projects", kind: .section(true))]
            if !model.settings.projectsCollapsed {
                projectsSection += projectItems(helpers: helpers)
                if model.projects.isEmpty { projectsSection.append(SidebarItem(id: "empty-projects", kind: .empty("No projects yet"))) }
            }
            var tasksSection = [SidebarItem(id: "section-tasks", kind: .section(false))]
            if !model.settings.tasksCollapsed {
                let rows = taskItems(tasks, helpers: helpers, attention: attention)
                tasksSection += rows.isEmpty ? [SidebarItem(id: "empty-tasks", kind: .empty("No tasks yet"))] : rows
            }
            return model.settings.sidebarSectionOrder == .projectsFirst
                ? projectsSection + tasksSection
                : tasksSection + projectsSection
        }
    }

    /// Whether any of these heads is still running. Read through the model rather than the
    /// snapshot, so a head that has just finished is not counted by a stale copy.
    private func hasRunningHead(_ heads: [ChatThread]) -> Bool {
        heads.contains { (model.thread($0.id) ?? $0).hydra?.status == .running }
    }

    /// The helpers under a thread: one small row each, or a single line naming them while
    /// they are folded away.
    private func helperItems(under thread: ChatThread, helpers: [ChatThread], isNested: Bool = false) -> [SidebarItem] {
        // A settled thread is one small line; what it spawned comes back when it reopens.
        guard !thread.isSettled, !helpers.isEmpty else { return [] }
        if thread.foldsHelpers {
            return [SidebarItem(id: "helpers-\(thread.id)", kind: .helperStub(parent: thread, helpers: helpers), isNested: isNested)]
        }
        let plain = helpers.filter { !$0.isHydraHead }
        let heads = Self.orderedHeads(helpers.filter(\.isHydraHead))
        let showsHeads = !heads.isEmpty && !(model.settings.hydraAutoHidesIdleHeads && !hasRunningHead(heads))
        var items = plain.map { helper in
            SidebarItem(id: helper.id.uuidString, kind: .helper(helper, isLast: helper.id == plain.last?.id && !showsHeads), isNested: isNested)
        }
        if showsHeads {
            items.append(SidebarItem(id: "heads-\(thread.id)", kind: .headCards(parent: thread, heads: heads), isNested: isNested))
        }
        return items
    }

    /// Hydra heads in card order: running heads first, newest `createdAt` first among
    /// them, then finished heads, newest first.
    fileprivate static func orderedHeads(_ heads: [ChatThread]) -> [ChatThread] {
        heads.sorted { lhs, rhs in
            let lhsRunning = lhs.hydra?.status == .running
            let rhsRunning = rhs.hydra?.status == .running
            if lhsRunning != rhsRunning { return lhsRunning }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func fold(_ parentID: UUID?) {
        guard let parentID else { return }
        withAnimation(Chrome.panelSlide) { model.toggleHelpersFold(parentID) }
    }

    private nonisolated static func windowFrame(_ proxy: GeometryProxy) -> CGRect {
        proxy.frame(in: .named(GenieAnimator.coordinateSpace))
    }

    private func sectionHeader(isProjects: Bool) -> some View {
        SidebarSectionHeader(
            title: isProjects ? "Projects" : "Tasks",
            isCollapsed: Binding(
                get: { isProjects ? model.settings.projectsCollapsed : model.settings.tasksCollapsed },
                set: { collapsed in
                    if isProjects { model.settings.projectsCollapsed = collapsed }
                    else { model.settings.tasksCollapsed = collapsed }
                }
            ),
            isPresentingAccessory: isProjects && isAddingProject
        ) {
            Button {
                if isProjects { isAddingProject = true }
                else { model.newThread(affiliation: .standalone) }
            } label: { RowAccessoryIcon("plus") }
            .buttonStyle(.plain)
            .help(Text(verbatim: Chrome.localized(isProjects ? "Add project" : "New task")))
            .accessibilityLabel(Text(verbatim: Chrome.localized(isProjects ? "Add project" : "New task")))
            .chromePopover(isPresented: Binding(get: { isProjects && isAddingProject }, set: { isAddingProject = $0 }), arrowEdge: .bottom) {
                PopoverMenu {
                    PopoverItem("Choose a folder…", symbol: "folder") { isAddingProject = false; addProject() }
                    PopoverItem("Clone from GitHub…", symbol: "arrow.down.to.line") {
                        isAddingProject = false
                        GitHubClonePanel.shared.present(model: model)
                    }
                }
            }
        }
    }

    private func projectDragChanged(_ id: UUID, translation: CGFloat) {
        if projectDrag.id != id {
            guard let expandedTop = projectFrames.frame(of: id)?.minY,
                  let index = model.projects.firstIndex(where: { $0.id == id }) else { return }
            let collapsedTop = (projectsHeaderTop.value ?? Self.listTopInset) + (rowHeights.values["section-projects"] ?? Chrome.rowHeight) + 1 + model.projects.prefix(index).reduce(CGFloat.zero) {
                $0 + (rowHeights.values["project-\($1.id)"] ?? Chrome.rowHeight) + 1
            } + CGFloat(index) * (Chrome.groupGap + 1)
            var grab = RowDrag<UUID>(id: id)
            // Compensate for the rows above disappearing without moving the grip.
            grab.settled = collapsedTop - expandedTop
            withAnimation(Chrome.panelSlide) { projectDrag = grab }
            projectDragPeers = DragPeers((model.projects.map(\.id), nil), heights: projectSlotHeights)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { projectDrag.translation = translation }

        guard let snapshot = projectDragPeers else { return }
        let moved = projectDrag.settle(order: snapshot.order, heights: snapshot.heights, fallbackHeight: Chrome.rowHeight + Chrome.groupGap + 2) { neighbour, placeAfter in
            withAnimation(Chrome.panelSlide) {
                model.moveProject(id, to: neighbour, placeAfter: placeAfter)
            }
        }
        if moved {
            projectDragPeers = DragPeers((model.projects.map(\.id), nil), heights: projectSlotHeights)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func projectDragEnded() {
        guard projectDrag.id != nil else { return }
        projectDragPeers = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { projectDrag = RowDrag() }
    }

    private func projectSlotHeights(for order: [UUID]) -> [UUID: CGFloat] {
        var heights: [UUID: CGFloat] = [:]
        for id in order {
            heights[id] = (rowHeights.values["project-\(id)"] ?? Chrome.rowHeight) + 1 + Chrome.groupGap + 1
        }
        return heights
    }

    // MARK: Adding projects

    /// New projects join from here: a folder picker, one project per folder, then a
    /// thread in the last one added. Adding persists through the model.
    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = Chrome.localized("Add project")
        panel.message = Chrome.localized("Choose a folder for your agents to work in.")
        guard panel.runModal() == .OK else { return }
        var added: Project?
        for url in panel.urls { added = model.addProject(at: url) }
        if let added { model.newThread(in: added) }
    }

    // MARK: Project layout

    private func projectItems(helpers: [UUID: [ChatThread]]) -> [SidebarItem] {
        var items: [SidebarItem] = []
        for (index, project) in model.projects.enumerated() {
            if index > 0 {
                items.append(SidebarItem(id: "gap-\(project.id)", kind: .gap(Chrome.groupGap)))
            }
            let page = model.projectThreadPage(in: project)
            // Count root conversations; the helpers under one belong to the same page slot.
            items.append(SidebarItem(id: "project-\(project.id)", kind: .project(project, count: page.totalCount)))
            guard project.isExpanded, projectDrag.id == nil else { continue }
            func appendSettledHeader() {
                if page.threads.contains(where: { !$0.isSettled }) {
                    items.append(SidebarItem(id: "settled-gap-\(project.id)", kind: .gap(ThreadRowMetrics.settledGap)))
                }
                items.append(SidebarItem(id: "settled-header-\(project.id)", kind: .settledHeader(count: page.settledCount, isFirst: false), isNested: true))
            }
            var reachedSettled = false
            for thread in page.threads {
                if thread.isSettled, !reachedSettled {
                    reachedSettled = true
                    appendSettledHeader()
                }
                let own = helpers[thread.id] ?? []
                items.append(SidebarItem(
                    id: SidebarItem.id(for: thread),
                    kind: .thread(thread, projectName: nil, projectIcon: nil, peers: nil, hasHelpers: !thread.isSettled && !own.isEmpty),
                    isNested: true
                ))
                items.append(contentsOf: helperItems(under: thread, helpers: own, isNested: true))
            }
            if page.showsSettledHeader, !reachedSettled { appendSettledHeader() }
            if page.hasMore {
                items.append(SidebarItem(id: "show-more-\(project.id)", kind: .showMore(project.id)))
            }
        }
        return items
    }

    // MARK: Task layout

    private func taskItems(_ tasks: [ChatThread], helpers: [UUID: [ChatThread]], attention: Set<UUID>, activity: Bool = false) -> [SidebarItem] {
        var items: [SidebarItem] = []
        for section in ThreadOrganization.taskSections(tasks, attention: attention) {
            switch section.kind {
            case .attention:
                items.append(SidebarItem(id: "attention", kind: .header("Needs attention", isFirst: items.isEmpty)))
            case .pinned:
                items.append(SidebarItem(id: "day-Pinned", kind: .header("Pinned", isFirst: items.isEmpty)))
            case .day(let day):
                if activity {
                    items.append(SidebarItem(id: "day-\(day.timeIntervalSince1970)", kind: .header(Self.dayTitle(for: day), isFirst: items.isEmpty)))
                }
            case .settled:
                items.append(SidebarItem(id: "settled", kind: .settledHeader(count: section.threads.count, isFirst: items.isEmpty)))
                if model.settings.settledCollapsed { continue }
            }
            let peers = section.kind == .settled ? nil : section.threads.map(\.id)
            for thread in section.threads {
                let own = helpers[thread.id] ?? []
                let project = model.project(thread.projectID)
                let compact = activity && model.settings.activityThreadStyle == .icon
                let name = project?.name ?? Chrome.localized(thread.projectID == nil ? "Task" : "Missing project")
                items.append(SidebarItem(
                    id: SidebarItem.id(for: thread),
                    kind: .thread(thread, projectName: activity && !compact ? name : nil, projectIcon: compact ? (project?.icon ?? .symbol("folder")) : nil, peers: peers, hasHelpers: !thread.isSettled && !own.isEmpty)
                ))
                items += helperItems(under: thread, helpers: own)
            }
        }
        return items
    }

    private static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return Chrome.localized("Today") }
        if calendar.isDateInYesterday(date) { return Chrome.localized("Yesterday") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day ?? 0
        if days >= 0 && days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    private func needsAttention(_ thread: ChatThread) -> Bool {
        guard let runtime = model.existingRuntime(for: thread.id) else { return false }
        return runtime.pendingInteractionStatus != nil
    }

    // MARK: Search

    @ViewBuilder
    private func searchList(helpers: [UUID: [ChatThread]]) -> some View {
        let results = searchResults(helpers: helpers)
        if results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No results")
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText.opacity(0.92))
                Text("Try a thread title or a project name.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
        } else {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 {
                    Color.clear.frame(height: Chrome.groupGap)
                }
                if let project = result.project { ProjectRow(snapshot: project, count: result.count, togglesExpansion: false) }
                else { ActivityHeader(title: "Tasks", isFirst: index == 0) }
                // Keyed like the main list, so a thread settled from here changes rows too.
                ForEach(result.threads, id: \.sidebarItemID) { thread in
                    threadRow(thread, projectName: nil, projectIcon: nil, hasHelpers: !thread.isSettled && !(helpers[thread.id] ?? []).isEmpty, isNested: true)
                }
            }
        }
    }

    /// Up and down in the search field walk the results without leaving the keyboard; the
    /// row highlights exactly as a clicked one does.
    private func moveSearchSelection(by offset: Int, helpers: [UUID: [ChatThread]]) {
        guard !query.isEmpty else { return }
        let results = searchResults(helpers: helpers).flatMap(\.threads)
        guard !results.isEmpty else { return }
        guard let current = model.selectedThreadID,
              let index = results.firstIndex(where: { $0.id == current }) else {
            model.selectedThreadID = (offset < 0 ? results.last : results.first)?.id
            return
        }
        let next = min(max(index + offset, 0), results.count - 1)
        model.selectedThreadID = results[next].id
    }

    /// The projects and threads matching the query, kept for the query and library they
    /// were found in: the field's submit, arrows and list all ask, and only a keystroke or
    /// a thread change looks again. Titles are matched lowercased, from a table the cache
    /// keeps per thread, so a keystroke lowercases the query once and nothing else.
    private func searchResults(helpers: [UUID: [ChatThread]]) -> [SidebarSearchResult] {
        let key = SidebarItemCache.SearchKey(threads: model.threads, projects: model.projects, query: query)
        return itemCache.search(for: key) { titles in
            let needle = query.lowercased()
            let projectResults = model.projects.compactMap { project -> SidebarSearchResult? in
                let all = model.threads(in: project).flatMap { [$0] + (helpers[$0.id] ?? []) }
                let threads = project.name.lowercased().contains(needle)
                    ? all
                    : all.filter { titles[$0.id]?.contains(needle) ?? $0.title.lowercased().contains(needle) }
                return threads.isEmpty ? nil : SidebarSearchResult(project: project, threads: threads, count: all.count)
            }
            let tasks = model.standaloneTasks.filter { titles[$0.id]?.contains(needle) ?? $0.title.lowercased().contains(needle) }
            return projectResults + (tasks.isEmpty ? [] : [SidebarSearchResult(project: nil, threads: tasks, count: tasks.count)])
        }
    }

    // MARK: Rows

    /// Drag a row up or down the list and it moves live: within its project in the project
    /// layout, within its group in the activity layout. The list's one gesture drives it
    /// (see `body`), ahead of the row's own click, so a drag never selects the thread on
    /// release; a plain click still does. The row only lifts and follows here.
    private func reorderableRow(_ thread: ChatThread, projectName: String?, projectIcon: ProjectIcon?, peers: [UUID]?, hasHelpers: Bool, isNested: Bool = false) -> some View {
        let isDragged = drag.id == thread.id
        return threadRow(thread, projectName: projectName, projectIcon: projectIcon, hasHelpers: hasHelpers, isDragged: isDragged, isNested: isNested)
            .offset(y: isDragged ? drag.visualOffset : 0)
            .zIndex(isDragged ? 1 : 0)
    }

    // MARK: Reorder

    /// Neighbours sliding out of the grabbed row's way.
    private static let slide = Animation.spring(response: 0.28, dampingFraction: 0.82)

    /// The pointer has moved `translation` since the grab. The grabbed row follows it
    /// exactly and `RowDrag` swaps it past every neighbour whose centre it has crossed.
    private func dragChanged(_ id: UUID, translation: CGFloat) {
        if drag.id != id {
            drag = RowDrag(id: id)
            // Taken once at the grab: the peers and their slots stand until a swap.
            dragPeers = DragPeers(peers(of: id), heights: slotHeights)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag.translation = translation }

        guard let snapshot = dragPeers else { return }
        let (order, group) = (snapshot.order, snapshot.group)
        let moved = drag.settle(order: order, heights: snapshot.heights, fallbackHeight: Chrome.rowHeight + 1) { neighbour, placeAfter in
            // The neighbour slides and the grabbed row's slot moves in the same animation
            // as its compensation, so it stays put under the pointer while the list flows
            // around it.
            withAnimation(Self.slide) {
                if let group {
                    model.moveInActivity(id, to: neighbour, placeAfter: placeAfter, among: group)
                } else {
                    model.moveThread(id, to: neighbour, placeAfter: placeAfter)
                }
            }
        }
        if moved {
            // The row's peers as the list stands now, not as it stood at the grab: every
            // swap reorders them. The slots are by id and stand.
            dragPeers = DragPeers(peers(of: id), heights: slotHeights)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func dragEnded() {
        guard drag.id != nil else { return }
        dragPeers = nil
        // The offset animates from wherever the pointer let go to the row's slot, so the
        // row settles instead of snapping.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { drag = RowDrag() }
    }

    /// The threads a row can be reordered among, in their current order: its activity group
    /// (returned as `group` too, for the move) or its project's top-level threads.
    private func peers(of id: UUID) -> (order: [UUID], group: [UUID]?) {
        guard let thread = model.thread(id) else { return ([], nil) }
        if model.settings.sidebarActivityView || thread.projectID == nil {
            let placements = threadPlacements
            for item in listItems(placements: placements, helpers: helpersByParent(placements: placements)) {
                if case .thread(let candidate, _, _, let peers, _) = item.kind, candidate.id == id, let peers {
                    return (peers, peers)
                }
            }
            return ([], nil)
        }
        guard let project = model.project(thread.projectID) else { return ([], nil) }
        return (model.projectThreadPage(in: project).threads.filter { !$0.isSettled }.map(\.id), nil)
    }

    /// Each peer's slot: its row, the helper rows or folded line under it, and the list's
    /// spacing after each.
    private func slotHeights(for order: [UUID]) -> [UUID: CGFloat] {
        let grouped = helpersByParent(placements: threadPlacements)
        var heights: [UUID: CGFloat] = [:]
        for id in order {
            var height = (rowHeights.values[id.uuidString] ?? Chrome.rowHeight) + 1
            let helpers = grouped[id] ?? []
            if !helpers.isEmpty {
                if model.thread(id)?.foldsHelpers == true {
                    height += (rowHeights.values["helpers-\(id)"] ?? ThreadRowMetrics.helperHeight) + 1
                } else {
                    for helper in helpers where !helper.isHydraHead {
                        height += (rowHeights.values[helper.id.uuidString] ?? ThreadRowMetrics.helperHeight) + 1
                    }
                    let headCount = model.settings.hydraAutoHidesIdleHeads && !hasRunningHead(helpers.filter(\.isHydraHead))
                        ? 0
                        : helpers.count(where: \.isHydraHead)
                    if headCount > 0 {
                        let rows = (headCount + 5) / 6
                        height += (rowHeights.values["heads-\(id)"] ?? ThreadRowMetrics.headCardHeight(rows: rows)) + 1
                    }
                }
            }
            heights[id] = height
        }
        return heights
    }

    /// What a drag reuses between pointer moves: the grabbed row's peers in their order,
    /// the group they form in the activity layout, and each peer's slot height.
    private struct DragPeers {
        let order: [UUID]
        let group: [UUID]?
        let heights: [UUID: CGFloat]

        init(_ peers: (order: [UUID], group: [UUID]?), heights: ([UUID]) -> [UUID: CGFloat]) {
            order = peers.order
            group = peers.group
            self.heights = heights(peers.order)
        }
    }

    private func threadRow(_ thread: ChatThread, projectName: String?, projectIcon: ProjectIcon?, hasHelpers: Bool, isDragged: Bool = false, isNested: Bool = false) -> some View {
        // A thread with helpers under it gets the fold button; a settled one shows none.
        // `.equatable()` skips the parent's re-evaluation for rows whose value inputs did
        // not change; the row still observes the model's per-thread cells inside its body.
        return archivePopover(for: thread, on: renamePopover(for: thread, on: deletePopover(for: thread, on: SidebarThreadRow(
            snapshot: thread,
            projectName: projectName,
            projectIcon: projectIcon,
            tag: nil,
            menuRequests: menuRequests,
            isDragged: isDragged,
            // The popover is another window: no glide can cross into the main one from it.
            listFrame: inPopover ? nil : listFrame,
            onToggleFold: hasHelpers ? { fold(thread.id) } : nil,
            onRename: {
                // The live record: the item's snapshot does not follow a title change.
                let live = model.thread(thread.id) ?? thread
                renameText = live.title
                renaming = live
            },
            onDelete: {
                if model.settings.confirmBeforeDeleting {
                    pendingDeletionID = thread.id
                } else {
                    model.delete(thread.id)
                }
            }
        ).equatable())))
    }
}

struct SidebarToggleButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ChromeCircleButton(symbol: "sidebar.left", help: Chrome.localized("Toggle sidebar") + ShortcutStore.hint(for: .toggleSidebar)) {
            model.sidebar.toggle()
        }
    }
}

/// The shortcut's question: the thread by name, with Delete beside Archive under it.
/// Return archives and Escape asks nothing. Archive takes focus as the popover opens,
/// which makes the popover key; when that is late or lost and the keys land on the chat
/// window behind it instead, the monitor answers them, so Return never goes on to the
/// composer.
private struct ArchiveThreadPopover: View {
    let thread: ChatThread
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        PopoverMenu {
            VStack(alignment: .leading, spacing: 9) {
                Text("Archive \(Text(verbatim: "\u{201C}\(thread.title)\u{201D}").fontWeight(.semibold))?")
                    .font(.ui(.callout))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(action: onDelete) {
                        Text("Delete").foregroundStyle(.red)
                    }
                    .buttonStyle(.glass)
                    .help("Remove the thread and its history")
                    Button("Archive", action: onArchive)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .focusable()
                        .focused($isFocused)
                        .focusEffectDisabled()
                        .help("Move it to Archived (Return)")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .frame(width: 272)
        .onAppear {
            isFocused = true
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window is ThreadWindow,
                      event.modifierFlags.intersection(KeyChord.allowedModifiers).isEmpty else { return event }
                switch event.keyCode {
                case 36, 76: onArchive() // Return, keypad Enter
                case 53: onDismiss() // Escape
                default: return event
                }
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }
}

/// What the delete popover asks: the thread by name, what stays, and the destructive choice
/// as a red row like the ellipsis menu's, with a second one for a thread's worktree.
private struct DeleteThreadPopover: View {
    let thread: ChatThread
    let onDelete: (_ removeWorktree: Bool) -> Void

    var body: some View {
        PopoverMenu {
            PopoverSectionHeader("Delete this thread?")
            PopoverNote("“\(thread.title)” and its history will be removed. Files in your project stay as they are.")
            PopoverDivider()
            PopoverItem("Delete thread", symbol: "trash", isDestructive: true) { onDelete(false) }
            if thread.worktreePath != nil {
                PopoverItem("Delete thread and worktree", symbol: "trash", isDestructive: true) { onDelete(true) }
            }
        }
        .frame(width: 280)
    }
}

/// What the rename popover asks: the title field and the choice, on the row itself
/// like the delete question. Clicking away keeps the thread's title.
private struct RenameThreadPopover: View {
    let title: String
    let onRename: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(title: String, onRename: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.onRename = onRename
        self.onCancel = onCancel
        _text = State(initialValue: title)
    }

    var body: some View {
        ChromeTextInputPopover(
            title: "Rename thread", prompt: "Title", submitTitle: "Rename", text: $text,
            onSubmit: { onRename(text) }, onCancel: onCancel
        )
    }
}

/// One entry of the sidebar list. Thread entries use the thread's id in both layouts, and a
/// settled thread's row is an entry of its own: the open row leaves and the settled one
/// arrives as the list makes room for it; a reopen's ghost glides between the two.
private struct SidebarItem: Identifiable {
    enum Kind {
        case gap(CGFloat)
        case section(Bool)
        case empty(String)
        /// A project, with its root conversation count when folded.
        case project(Project, count: Int)
        case showMore(UUID)
        case header(String, isFirst: Bool)
        /// The Settled section's header: the title, how many settled threads it holds,
        /// and whether they are folded away. The collapsed flag lives in settings.
        case settledHeader(count: Int, isFirst: Bool)
        /// A thread, with its project's name in the activity layout, the threads it can be
        /// reordered among, and whether it has helpers to fold away.
        case thread(ChatThread, projectName: String?, projectIcon: ProjectIcon?, peers: [UUID]?, hasHelpers: Bool)
        /// A helper under its parent thread; the last one ends the connector.
        case helper(ChatThread, isLast: Bool)
        /// The parent's Hydra heads as glyph cards, ending the connector.
        case headCards(parent: ChatThread, heads: [ChatThread])
        /// A parent's folded helpers, as one line that unfolds them.
        case helperStub(parent: ChatThread, helpers: [ChatThread])
    }

    let id: String
    let kind: Kind
    var isNested: Bool = false

    static func id(for thread: ChatThread) -> String {
        thread.sidebarItemID
    }
}

private extension ChatThread {
    var sidebarItemID: String {
        isSettled ? "settled-\(id.uuidString)" : id.uuidString
    }
}

private extension AnyTransition {
    /// A row leaves at once and arrives once its neighbours have mostly made room, so rows moving past
    /// each other never draw over one another. These two fades are deliberately quick and
    /// not the settle flight: on a settle or reopen the ghost is the motion, and the
    /// departing row has to be gone under it at once rather than linger as a fading
    /// remnant while the list closes up.
    static var sidebarRow: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.18).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.06))
        )
    }
}

/// Hover state belongs to each header, so moving across it does not rebuild the list.
private struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    @Binding var isCollapsed: Bool
    var isPresentingAccessory: Bool
    @ViewBuilder var accessory: Accessory
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(Chrome.panelSlide) { isCollapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.symbol(.caption2))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: Chrome.symbolSize, height: Chrome.symbolSize)
                    .accessibilityHidden(true)
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Chrome.secondaryText)
            .padding(.leading, Chrome.rowHorizontalPadding)
            .padding(.trailing, Chrome.rowHorizontalPadding + 20)
            .frame(height: Chrome.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Chrome.localized(title)))
        .accessibilityValue(Text(verbatim: Chrome.localized(isCollapsed ? "Collapsed" : "Expanded")))
        .overlay(alignment: .trailing) {
            if isHovering || isPresentingAccessory {
                accessory.padding(.trailing, 6)
            }
        }
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .padding(.top, 8)
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    /// The project as the list last built it; `project` below is the live record.
    let snapshot: Project
    /// The row reads its own project through the model's per-project cell, so a change to
    /// it re-renders this row alone and a change to any other project does not reach it.
    /// The snapshot is the fallback for a project that has just been removed.
    private var project: Project { model.project(snapshot.id) ?? snapshot }
    /// What a folded project shows: its threads and the helpers under them, counted by the
    /// list once for every row rather than here, per row, over the whole library.
    let count: Int
    var togglesExpansion = true

    @State private var isMenuPresented = false
    @State private var isChoosingIcon = false

    var body: some View {
        // The global switch in Settings activates every project at once; only a project
        // explicitly switched here keeps its own choice, and shows dimmed while off.
        let isActive = model.settings.isProjectActive(project.id)
        SidebarRow(
            title: project.name,
            accessoryWidth: 40,
            action: {
                guard togglesExpansion else { return }
                withAnimation(Chrome.panelSlide) {
                    model.updateProject(project.id) { $0.isExpanded.toggle() }
                }
            },
            icon: {
                SidebarIconBadge {
                    if let icon = project.icon {
                        ProjectIconMark(icon: icon, size: 12)
                    } else {
                        SidebarSymbol("folder")
                    }
                }
            },
            accessory: { hovering in
                if hovering || isMenuPresented {
                    HStack(spacing: 0) {
                        RowActionsButton(actions: actions(isActive: isActive), isPresented: $isMenuPresented)
                        Button {
                            model.newThread(in: project)
                        } label: {
                            RowAccessoryIcon("plus")
                        }
                        .buttonStyle(.plain)
                        .help("New thread in \(project.name)")
                    }
                } else if !project.isExpanded, count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.ui(.subheadline).monospacedDigit())
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.trailing, 4)
                }
            }
        )
        .opacity(isActive ? 1 : 0.55)
        .chromePopover(isPresented: $isChoosingIcon, arrowEdge: .trailing) {
            ProjectIconPicker(icon: Binding(get: { model.project(snapshot.id)?.icon }, set: { icon in
                model.updateProject(snapshot.id) { $0.icon = icon }
            }))
        }
        // Snapshots only: the menu builder must not capture the row, so the AppKit menu it
        // builds cannot pin the row's state storage (and its responder with it) after dismiss.
        .contextMenu { [project, model, choosingIcon = $isChoosingIcon] in
            Button("Edit project icon…") { choosingIcon.wrappedValue = true }
            Divider()
            let projectSnapshot = project
            let modelSnapshot = model
            let activeSnapshot = modelSnapshot.settings.isProjectActive(projectSnapshot.id)
            let overrideSnapshot = modelSnapshot.settings.hasProjectActivationOverride(for: projectSnapshot.id)
            RowActionMenuButtons(actions: Self.contextMenuActions(
                project: projectSnapshot,
                isActive: activeSnapshot,
                hasOverride: overrideSnapshot,
                model: modelSnapshot
            ))
            // The pair that new chats in this project start on. The menu shows only when
            // there is a pair to choose. Value snapshots only, as above.
            let pairsSnapshot = modelSnapshot.hydraPickerPairs.map { pair in
                ProjectPairChoice(id: pair.id, title: HydraPairSummary.title(pair, registry: modelSnapshot.providers))
            }
            if !pairsSnapshot.isEmpty {
                Divider()
                Menu {
                    ProjectPairMenuItems(projectID: projectSnapshot.id, selectedID: projectSnapshot.hydraPairID, pairs: pairsSnapshot, model: modelSnapshot)
                } label: {
                    Label("Start new chats on", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
    }

    /// The context menu's items, built from value snapshots with weak model captures: the
    /// AppKit menu outlives the right-click, so its callbacks must not retain the row.
    /// (The ellipsis popover keeps `actions(isActive:)`; it is not an AppKit menu.)
    private static func contextMenuActions(project: Project, isActive: Bool, hasOverride: Bool, model: AppModel) -> [RowAction] {
        let projectID = project.id
        var items = [
            RowAction(title: "New thread", symbol: "plus.circle") { [weak model, project] in
                guard let model else { return }
                model.newThread(in: project)
            },
            RowAction(title: "New thread in worktree", symbol: "square.stack.3d.up") { [weak model, project] in
                guard let model else { return }
                model.newThread(in: project, workspace: .worktree)
            },
            RowAction(title: "Reveal in Finder", symbol: "folder", startsGroup: true) { [weak model, path = project.path] in
                guard model != nil else { return }
                Workspace.revealInFinder(path)
            },
            RowAction(title: "Remove project", symbol: "trash", isDestructive: true, startsGroup: true) { [weak model, project] in
                guard let model else { return }
                model.removeProject(project)
            },
        ]
        items.append(RowAction(
            title: isActive ? "Deactivate project" : "Activate project",
            symbol: "power",
            startsGroup: true
        ) { [weak model, projectID, isActive] in
            guard let model else { return }
            model.settings.setProjectActive(!isActive, for: projectID)
        })
        if hasOverride {
            items.append(RowAction(title: "Follow global setting", symbol: "arrow.uturn.backward") { [weak model, projectID] in
                guard let model else { return }
                model.settings.clearProjectActivationOverride(for: projectID)
            })
        }
        return items
    }

    private func actions(isActive: Bool) -> [RowAction] {
        var items = [
            RowAction(title: "New thread", symbol: "plus.circle") { model.newThread(in: project) },
            RowAction(title: "New thread in worktree", symbol: "square.stack.3d.up") {
                model.newThread(in: project, workspace: .worktree)
            },
            RowAction(title: "Reveal in Finder", symbol: "folder", startsGroup: true) { Workspace.revealInFinder(project.path) },
            RowAction(title: "Remove project", symbol: "trash", isDestructive: true, startsGroup: true) {
                model.removeProject(project)
            },
        ]
        items.append(RowAction(
            title: isActive ? "Deactivate project" : "Activate project",
            symbol: "power",
            startsGroup: true
        ) {
            model.settings.setProjectActive(!isActive, for: project.id)
        })
        if model.settings.hasProjectActivationOverride(for: project.id) {
            items.append(RowAction(title: "Follow global setting", symbol: "arrow.uturn.backward") {
                model.settings.clearProjectActivationOverride(for: project.id)
            })
        }
        return items
    }
}

/// One pair as the submenu shows it: its id and its title.
private struct ProjectPairChoice: Identifiable {
    let id: UUID
    let title: String
}

/// The items of the project row's pair submenu: one per pair the picker offers, plus one
/// that removes the rule. A check mark shows the current choice. The view is a value and
/// holds the model it draws, so the callbacks capture it directly; there is no cycle.
private struct ProjectPairMenuItems: View {
    let projectID: UUID
    let selectedID: UUID?
    let pairs: [ProjectPairChoice]
    let model: AppModel

    var body: some View {
        Button { [projectID] in
            model.setHydraPair(nil, forProject: projectID)
        } label: {
            if selectedID == nil {
                Label("The chat's last pair", systemImage: "checkmark")
            } else {
                Text("The chat's last pair")
            }
        }
        Divider()
        ForEach(pairs) { pair in
            Button { [projectID, pairID = pair.id] in
                model.setHydraPair(pairID, forProject: projectID)
            } label: {
                if selectedID == pair.id {
                    Label(Chrome.localized(pair.title), systemImage: "checkmark")
                } else {
                    Text(verbatim: Chrome.localized(pair.title))
                }
            }
        }
    }
}

private enum ThreadRowMetrics {
    /// Indentation for a project's settled section header.
    static let folderIndent: CGFloat = 12
    static let detailedVerticalPadding: CGFloat = 7
    /// A two-line activity row: title, project line and their padding.
    static let detailedHeight: CGFloat = 48
    /// A helper's row under its parent: one small line, in either layout.
    static let helperHeight: CGFloat = 24
    /// A settled thread's row: one small grey line, in either layout.
    static let settledHeight: CGFloat = 24
    /// The step between a project's last open thread and its settled ones.
    static let settledGap: CGFloat = 4
    /// Where the check sits: at the front of a settled row, and beside the ellipsis at the
    /// trailing end of an open one. The settled title starts past the check.
    static let settledCheckInset: CGFloat = 6
    static let openCheckInset: CGFloat = 26
    /// Where the fold button sits on a thread with helpers: past the ellipsis and the check
    /// (or the archive button) at the trailing end.
    static let foldInset: CGFloat = 46
    /// Share the title's leading geometry with its child connector. The spine starts
    /// directly below the first title character, then leaves room for a rounded elbow.
    static let titleGap: CGFloat = 8
    static let inlineProjectIconSize: CGFloat = 12
    static let titleItemGap: CGFloat = 6

    struct Connector: Equatable {
        let lineX: CGFloat
        var width: CGFloat { lineX + 16 }
    }

    static func connector(showsProjectIcon: Bool) -> Connector {
        let projectIconInset = showsProjectIcon ? inlineProjectIconSize + titleItemGap : 0
        return Connector(lineX: Chrome.rowHorizontalPadding + Chrome.iconSize + titleGap + projectIconInset)
    }
    /// A head's mark is the size of the project icon that leads a thread title, so one
    /// mark size reads down the whole sidebar.
    static let headGlyphSize: CGFloat = 14
    /// A head glyph plus the gap a card row keeps at its tightest.
    static let headGlyphPitch: CGFloat = 22
    /// The room a glyph's outcome badge takes past its frame: HydraGlyph rides the disc
    /// `0.3 × its diameter` out, a shade under 3 pt at this glyph size. A card row keeps
    /// it clear on its trailing side, so a badge never eats the card's own padding.
    static let headBadgeOverhang: CGFloat = 3
    /// Between a head card's glyph rows, and its horizontal padding. Vertical padding
    /// comes from the shared helper height, so opening one row adds no extra space.
    static let headRowGap: CGFloat = 6
    static let headCardPadding: CGFloat = 6
    static let headCardVerticalPadding = (helperHeight - headGlyphSize) / 2
    /// A head card's height for `rows` rows of glyphs: the rows, the gaps between them
    /// and the padding. The card reports its own height as it lays out; this stands in
    /// until the first measurement lands.
    static func headCardHeight(rows: Int) -> CGFloat {
        let rows = max(1, rows)
        return helperHeight + CGFloat(rows - 1) * (headGlyphSize + headRowGap)
    }
}

/// A helper under the thread it was spawned from: one small line, joined to its parent by a
/// connector that runs down the rows and ends at the last. The connector folds the
/// helpers away; the folded line (HelperStubRow) unfolds them.
private struct SidebarHelperRow: View, Equatable {
    @Environment(AppModel.self) private var model
    /// The helper as the list last built it; `thread` below is the live record.
    let snapshot: ChatThread
    /// The row reads its own thread through the model's per-thread cell, so a change to it
    /// re-renders this row alone and a change to any other thread does not reach it. The
    /// snapshot is the fallback for a thread that has just been deleted.
    private var thread: ChatThread { model.thread(snapshot.id) ?? snapshot }
    /// The last helper under its parent: the connector ends at this row.
    let isLast: Bool
    let connector: ThreadRowMetrics.Connector
    /// Carries rename/delete intents out of the AppKit menu without retaining row state.
    /// Held strongly: the box is the list's, not the row's, so holding it pins no row
    /// state, and a weak one could go nil under a menu still on screen.
    let menuRequests: SidebarMenuRequests
    let onFold: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isMenuPresented = false

    var body: some View {
        // Through the thread's own cell: a selection change re-renders the two rows it
        // touches, not every row in the list.
        let isSelected = model.isSelected(thread.id)
        let waitingStatus = isSelected ? nil : model.existingRuntime(for: thread.id)?.pendingInteractionStatus
        let showsActions = isHovering || isMenuPresented
        // A helper goes out of sight the moment its parent's ghost takes off, so it never
        // lingers under the rows closing up.
        let isHidden = RowGlideAnimator.shared.isHiding(thread.parentThreadID ?? thread.id)
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        HStack(spacing: 0) {
            HelperConnector(geometry: connector, endsHere: isLast, action: onFold)
                .frame(width: connector.width, height: ThreadRowMetrics.helperHeight)
            Button {
                model.selectedThreadID = thread.id
            } label: {
                HStack(spacing: 6) {
                    // A head keeps its glyph, so the team reads at a glance under its lead,
                    // at the same size the card draws it.
                    if let head = thread.hydra {
                        HydraGlyph(persona: head.persona, size: ThreadRowMetrics.headGlyphSize, status: head.status)
                    }
                    ThreadBadge(thread: thread)
                    Text(verbatim: thread.title)
                        .font(.ui(.callout, weight: isSelected || thread.hasUnread ? .medium : .regular))
                        .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 0.96 : 0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let waitingStatus { ThreadWaitingBadge(status: waitingStatus) }
                }
                .padding(.leading, 6)
                .padding(.trailing, Chrome.rowHorizontalPadding + (showsActions ? 26 : waitingStatus == nil ? 18 : 0))
                .frame(height: ThreadRowMetrics.helperHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape
                        .fill(isSelected ? Chrome.overlay(0.12) : (isHovering ? Chrome.overlay(0.06) : Color.clear))
                        .animation(Chrome.hover, value: isSelected)
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                Group {
                    if showsActions {
                        RowActionsButton(actions: makeActions(), isPresented: $isMenuPresented)
                    }
                }
                .padding(.trailing, 6)
            }
            .onHover { hovering in
                withAnimation(Chrome.hover) { isHovering = hovering }
                if hovering { model.warmDocuments([thread.id]) }
            }
            // Snapshots only: the menu builder must not capture the row, so the AppKit menu
            // it builds cannot pin the row's state storage (and its responder with it).
            .contextMenu { [thread, model, menuRequests] in
                let threadSnapshot = thread
                let modelSnapshot = model
                let requestsSnapshot = menuRequests
                let settleFirstSnapshot = !threadSnapshot.isHelper && modelSnapshot.settings.threadFinishAction == .settle
                RowActionMenuButtons(actions: ThreadActions.makeContextMenu(
                    model: modelSnapshot,
                    thread: threadSnapshot,
                    settleFirst: settleFirstSnapshot,
                    requests: requestsSnapshot
                ))
            }
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        }
        .opacity(isHidden ? 0 : 1)
    }

    static func == (lhs: SidebarHelperRow, rhs: SidebarHelperRow) -> Bool {
        lhs.snapshot.id == rhs.snapshot.id
            && lhs.snapshot.title == rhs.snapshot.title
            && lhs.snapshot.updatedAt == rhs.snapshot.updatedAt
            && lhs.snapshot.isPinned == rhs.snapshot.isPinned
            && lhs.snapshot.isSettled == rhs.snapshot.isSettled
            && lhs.isLast == rhs.isLast
            && lhs.connector == rhs.connector
    }

    private func makeActions() -> [RowAction] {
        ThreadActions.make(model: model, thread: thread, onRename: onRename, onDelete: onDelete)
    }
}

private struct HeadCardsRow: View {
    @Environment(AppModel.self) private var model
    let parentSnapshot: ChatThread
    let headSnapshots: [ChatThread]
    let rowWidth: CGFloat
    let connector: ThreadRowMetrics.Connector
    let menuRequests: SidebarMenuRequests
    let onFold: () -> Void

    @State private var hoveredID: UUID?
    /// The card shows the first twelve faces and keeps the rest behind the chevron: a
    /// long-running chat's team must not push the card half the sidebar tall.
    @State private var showsAllHeads = false

    var body: some View {
        let heads = SidebarView.orderedHeads(headSnapshots.map { model.thread($0.id) ?? $0 })
        let capped = heads.count > 12
        let visible = showsAllHeads ? heads : Array(heads.prefix(12))
        // The glyphs' room: the row's width less the connector's column, the equal
        // padding on both sides, and the last mark's outcome badge. A last glyph
        // needs its own size, not a whole pitch. Both sidebar hosts use the model's
        // fixed width, so the first layout already has the right row count.
        let cardInner = rowWidth - connector.width - 2 * ThreadRowMetrics.headCardPadding
        let usable = cardInner - ThreadRowMetrics.headBadgeOverhang
        let perRow = max(1, Int((usable + ThreadRowMetrics.headGlyphPitch - ThreadRowMetrics.headGlyphSize) / ThreadRowMetrics.headGlyphPitch))
        // The marks share the card's inner width: a row stretches its gaps past the
        // tightest one until the last mark's badge sits on the card's padding, so the
        // room left of the first mark and right of the last one come out the same. A
        // short last row keeps the step of the rows above it.
        let tightGap = ThreadRowMetrics.headGlyphPitch - ThreadRowMetrics.headGlyphSize
        let rowGap = perRow > 1
            ? max(tightGap, (usable - CGFloat(perRow) * ThreadRowMetrics.headGlyphSize) / CGFloat(perRow - 1))
            : tightGap
        let rows = Self.chunk(visible, by: perRow)
        let cardRows = rows.count + (capped ? 1 : 0)
        HStack(spacing: 0) {
            HelperConnector(geometry: connector, endsHere: true, action: onFold)
                .frame(
                    width: connector.width,
                    height: ThreadRowMetrics.headCardHeight(rows: cardRows)
                )
            VStack(alignment: .leading, spacing: ThreadRowMetrics.headRowGap) {
                ForEach(rows, id: \.first?.id) { row in
                    HStack(spacing: rowGap) {
                        ForEach(row, id: \.id) { head in
                            if let info = head.hydra {
                                Button {
                                    model.selectedThreadID = head.id
                                } label: {
                                    HydraGlyph(persona: info.persona, size: ThreadRowMetrics.headGlyphSize, isRunning: info.status == .running, status: info.status)
                                        .background {
                                            if model.isSelected(head.id) {
                                                Circle().fill(Chrome.overlay(0.14)).padding(-3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .scaleEffect(hoveredID == head.id ? 1.18 : 1)
                                .animation(Chrome.hover, value: hoveredID == head.id)
                                .onHover { hovering in
                                    withAnimation(Chrome.hover) { hoveredID = hovering ? head.id : (hoveredID == head.id ? nil : hoveredID) }
                                    if hovering { model.warmDocuments([head.id]) }
                                }
                                .help(Text(verbatim: "\(info.persona.name) · \(info.task)"))
                                // Snapshots only: the menu builder must not capture the row, so the AppKit menu
                                // it builds cannot pin the row's state storage (and its responder with it).
                                .contextMenu { [head, model, menuRequests] in
                                    let threadSnapshot = head
                                    let modelSnapshot = model
                                    let requestsSnapshot = menuRequests
                                    RowActionMenuButtons(actions: ThreadActions.makeContextMenu(
                                        model: modelSnapshot,
                                        thread: threadSnapshot,
                                        settleFirst: false,
                                        requests: requestsSnapshot
                                    ))
                                }
                                .accessibilityLabel(Text("\(info.persona.name), \(info.task)"))
                                .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                    // The last mark's badge rides past its frame: the row trails it so the
                    // card's padding stays whole on that side.
                    .padding(.trailing, ThreadRowMetrics.headBadgeOverhang)
                }
                if capped {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { showsAllHeads.toggle() }
                    } label: {
                        Image(systemName: showsAllHeads ? "chevron.up" : "chevron.down").font(.symbol(.caption2, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(width: ThreadRowMetrics.headGlyphSize, height: ThreadRowMetrics.headGlyphSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: showsAllHeads ? Chrome.localized("Show fewer heads") : String(format: Chrome.localized("Show all %d heads"), heads.count)))
                }
            }
            .padding(.horizontal, ThreadRowMetrics.headCardPadding)
            .padding(.vertical, ThreadRowMetrics.headCardVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ThreadRowMetrics.headCardHeight(rows: cardRows), alignment: .top)
            .animation(.snappy(duration: 0.18), value: cardRows)
        }
        // A helper goes out of sight the moment its parent's ghost takes off, so it never
        // lingers under the rows closing up.
        .opacity(RowGlideAnimator.shared.isHiding(parentSnapshot.id) ? 0 : 1)
        .animation(Chrome.panelSlide, value: heads.map(\.id))
    }

    /// The heads in rows of `size`, in the order given; the last row takes the rest.
    private static func chunk(_ heads: [ChatThread], by size: Int) -> [[ChatThread]] {
        stride(from: 0, to: heads.count, by: size).map { Array(heads[$0 ..< min($0 + size, heads.count)]) }
    }
}

/// A parent's folded helpers as one small line: the connector's stub, a chevron and their
/// count, with a pulse when any of them is still working. Clicking it unfolds them.
private struct HelperStubRow: View {
    @Environment(AppModel.self) private var model
    /// The parent as the list last built it; `parent` below is the live record.
    let parentSnapshot: ChatThread
    /// Handed in by the list, which groups every helper once per pass; the body reads each
    /// one's live record through the model's per-thread cell.
    let helperSnapshots: [ChatThread]
    let connector: ThreadRowMetrics.Connector
    let action: () -> Void

    @State private var isHovering = false

    /// The row reads its parent through the model's per-thread cell, so a change to it
    /// re-renders this row alone and a change to any other thread does not reach it. The
    /// snapshot is the fallback for a thread that has just been deleted.
    private var parent: ChatThread { model.thread(parentSnapshot.id) ?? parentSnapshot }

    var body: some View {
        // Each helper's live record, read once per render through its own cell.
        let helpers = helperSnapshots.map { model.thread($0.id) ?? $0 }
        let count = helpers.count
        let working = helpers.contains { helper in
            let runtime = model.existingRuntime(for: helper.id)
            return runtime?.isRunning == true || runtime?.hasNativeWork == true || runtime?.isHydraMerging == true || !(runtime?.backgroundTasks.isEmpty ?? true)
        }
        // A team of heads is called that; merges alone stay "helpers".
        let isHeads = helpers.allSatisfy(\.isHydraHead)
        // A helper goes out of sight the moment its parent's ghost takes off, so it never
        // lingers under the rows closing up.
        let isHidden = RowGlideAnimator.shared.isHiding(parentSnapshot.id)
        Button(action: action) {
            HStack(spacing: 0) {
                HelperConnectorShape(lineX: connector.lineX, endsHere: true)
                    .stroke(HelperConnector.color(hovering: isHovering), style: HelperConnector.style)
                    .frame(width: connector.width, height: ThreadRowMetrics.helperHeight)
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(verbatim: count == 1 ? Chrome.localized(isHeads ? "1 head" : "1 helper") : String(format: Chrome.localized(isHeads ? "%d heads" : "%d helpers"), count))
                        .font(.ui(.subheadline))
                    Spacer(minLength: 4)
                    if working {
                        MiniSpinner(cellSize: 2.4)
                            .padding(.trailing, 4)
                    }
                }
                .foregroundStyle(isHovering ? Chrome.primaryText : Chrome.secondaryText.opacity(0.85))
                .padding(.leading, 6)
                .padding(.trailing, Chrome.rowHorizontalPadding)
                .frame(height: ThreadRowMetrics.helperHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: count == 1 ? Chrome.localized(isHeads ? "Show the head" : "Show the helper") : String(format: Chrome.localized(isHeads ? "Show %d heads" : "Show %d helpers"), count)))
        .accessibilityLabel(Text(verbatim: count == 1 ? Chrome.localized(isHeads ? "1 folded head" : "1 folded helper") : String(format: Chrome.localized(isHeads ? "%d folded heads" : "%d folded helpers"), count)))
        .opacity(isHidden ? 0 : 1)
    }
}

/// A helper row or the folded line under a thread being dragged moves with it, lifted the
/// same way, so the thread and its helpers travel as one block.
private struct RidesWithDraggedParent: ViewModifier {
    let parentID: UUID?
    let drag: RowDrag<UUID>

    func body(content: Content) -> some View {
        let rides = parentID != nil && drag.id == parentID
        content
            .offset(y: rides ? drag.visualOffset : 0)
            .zIndex(rides ? 1 : 0)
    }
}

/// A quiet tree branch under the parent's title. The rounded elbow meets the first
/// helper's centre; a card with several rows keeps that same junction. The whole column
/// folds the helpers away.
private struct HelperConnector: View {
    let geometry: ThreadRowMetrics.Connector
    let endsHere: Bool
    let action: () -> Void

    @State private var isHovering = false

    static let style = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)

    static func color(hovering: Bool) -> Color {
        Chrome.secondaryText.opacity(hovering ? 0.75 : 0.35)
    }

    var body: some View {
        Button(action: action) {
            HelperConnectorShape(lineX: geometry.lineX, endsHere: endsHere)
                .stroke(Self.color(hovering: isHovering), style: Self.style)
                .animation(Chrome.hover, value: isHovering)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Hide helpers")
        .accessibilityLabel(Text("Hide helpers"))
    }
}

private struct HelperConnectorShape: Shape {
    let lineX: CGFloat
    let endsHere: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + lineX
        let junctionY = rect.minY + ThreadRowMetrics.helperHeight / 2
        let endX = rect.maxX - 2
        let radius: CGFloat = 4
        // Cover the list's 1 pt inter-row gap so successive helper branches share one
        // continuous spine. Only the final row turns the spine into its elbow.
        path.move(to: CGPoint(x: x, y: rect.minY - 1))
        if !endsHere {
            path.addLine(to: CGPoint(x: x, y: rect.maxY + 1))
            path.move(to: CGPoint(x: x, y: junctionY - radius))
        } else {
            path.addLine(to: CGPoint(x: x, y: junctionY - radius))
        }
        path.addQuadCurve(
            to: CGPoint(x: x + radius, y: junctionY),
            control: CGPoint(x: x, y: junctionY)
        )
        path.addLine(to: CGPoint(x: endX, y: junctionY))
        return path
    }
}

/// A thread in either sidebar layout. In the project layout it is one line with the thread's badge; in
/// the activity layout the project it belongs to shows underneath. It is the same row in both, so
/// switching layouts animates its height and contents rather than swapping one row for another.
/// Settled, it is one small grey line with a green check at the front in either layout: a row of its
/// own that the open row's ghost glides down to (see RowGlideAnimator).
private struct SidebarThreadRow: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    /// The thread as the list last built it; `thread` below is the live record.
    let snapshot: ChatThread
    /// The row reads its own thread through the model's per-thread cell, so a change to it
    /// re-renders this row alone and a change to any other thread does not reach it. The
    /// snapshot is the fallback for a thread that has just been deleted.
    private var thread: ChatThread { model.thread(snapshot.id) ?? snapshot }
    /// The project shown under the title in the activity layout; nil in the project layout.
    let projectName: String?
    /// The project's mark in the icon style: the folder or the picked emoji or symbol, in
    /// the slot in front of the title. Nil in the project-name style and the project layout.
    let projectIcon: ProjectIcon?
    var tag: String? = nil
    /// Carries rename/delete intents out of the AppKit menu without retaining row state.
    /// Held strongly: the box is the list's, not the row's, so holding it pins no row
    /// state, and a weak one could go nil under a menu still on screen.
    let menuRequests: SidebarMenuRequests
    /// Lifted and following the pointer in a reorder.
    var isDragged = false
    /// The list's frame in the window, for the glide; nil where no glide can show.
    var listFrame: FrameHolder?
    /// Folds the helpers under this thread away or brings them back; nil when it has none.
    var onToggleFold: (() -> Void)?
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isMenuPresented = false
    /// The check was just clicked: it pops green as the row takes off.
    @State private var isSettling = false
    @State private var windowFrame = FrameHolder()
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        // Through the thread's own cell (see `AppModel.isSelected`): a selection change
        // re-renders the row that lost it and the row that gained it, no other. The
        // runtime read below is this thread's alone; `existingRuntime` observes nothing
        // of the model, and the runtime's fields are observed per runtime.
        let isSelected = model.isSelected(thread.id)
        let waitingStatus = isSelected ? nil : model.existingRuntime(for: thread.id)?.pendingInteractionStatus
        let isSettled = thread.isSettled
        let isDetailed = projectName != nil && !isSettled
        let showsActions = (isHovering || isMenuPresented) && !isDragged
        let showsFold = showsActions && onToggleFold != nil
        let showsTime = !showsActions && waitingStatus == nil && !isDetailed && !isSettled
        let trailingClearance = waitingStatus != nil && !showsActions && !isSettling ? 0
            : Self.trailingClearance(isSettled: isSettled, isDetailed: isDetailed, showsActions: showsActions || isSettling, showsFold: showsFold)
        let settles = model.settings.threadFinishAction == .settle
        // The check shows at the trailing end while the thread is open (beside the ellipsis,
        // on hover) and sits at the front once it has settled.
        let showsCheck = isSettled || (settles && (showsActions || isSettling))
        // While the row's ghost is in the air the row itself stays out of sight, and shows
        // again just as the ghost lands on it.
        let isHidden = RowGlideAnimator.shared.isHiding(thread.id)
        // Read here, in the body, so the row follows the merge as it moves from stage to stage.
        let mergeStage = Self.mergeStage(of: model.existingRuntime(for: thread.id))
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button {
            model.selectedThreadID = thread.id
        } label: {
            ThreadRowFace(
                thread: thread,
                projectName: projectName,
                projectIcon: projectIcon,
                isSelected: isSelected,
                trailingClearance: trailingClearance,
                showsTime: showsTime,
                tag: tag,
                waitingStatus: waitingStatus,
                mergeStage: mergeStage
            ) {
                ThreadBadge(thread: thread)
            }
            .background {
                // Only the fill animates with selection; the row's place is never animated from here.
                shape
                    .fill(thread.isPinned && !isSelected ? Chrome.danger.opacity(0.10) : Chrome.overlay(Self.fill(isSelected: isSelected, isHovering: isHovering)))
                    .animation(Chrome.hover, value: isSelected)
            }
            .overlay {
                if thread.isPinned && isSelected {
                    shape.fill(Chrome.danger.opacity(0.06))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: isSettled ? .leading : .trailing) {
            if showsCheck {
                SettleCheck(isSettled: isSettled, isPopping: isSettling) {
                    if isSettled { reopen() } else { settle() }
                }
                .padding(.leading, isSettled ? ThreadRowMetrics.settledCheckInset : 0)
                .padding(.trailing, isSettled ? 0 : ThreadRowMetrics.openCheckInset)
            }
        }
        .overlay(alignment: .trailing) {
            Group {
                if showsActions {
                    HStack(spacing: 0) {
                        if !settles, !isSettled {
                            Button {
                                archiveWithGenie()
                            } label: {
                                RowAccessoryIcon("archivebox")
                            }
                            .buttonStyle(.plain)
                            .help("Archive thread")
                        }
                        RowActionsButton(actions: makeActions(), isPresented: $isMenuPresented)
                    }
                }
            }
            .padding(.trailing, 6)
        }
        // The helpers under the thread fold away and come back from here, as they do from the
        // connector beside them. The button sits before the check (or the archive) and the ellipsis.
        .overlay(alignment: .trailing) {
            if showsFold, let onToggleFold {
                let folded = thread.foldsHelpers
                Button(action: onToggleFold) {
                    RowAccessoryIcon(folded ? "chevron.right" : "chevron.down")
                }
                .buttonStyle(.plain)
                .padding(.trailing, ThreadRowMetrics.foldInset)
                .help(Text(verbatim: folded ? Chrome.localized("Show helpers") : Chrome.localized("Hide helpers")))
                .accessibilityLabel(Text(verbatim: folded ? Chrome.localized("Show helpers") : Chrome.localized("Hide helpers")))
            }
        }
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
            // The pointer resting on a row usually means a click is coming: decode its history now.
            if hovering { model.warmDocuments([thread.id]) }
        }
        .onGeometryChange(for: CGRect.self, of: Self.windowFrame) { frame in
            // Scrolling moves every row every frame: the frame is tracked only while a
            // settle or reopen can need it — while this row is dragged, under the pointer
            // (a settle starts from the row under it), or while a glide is in the air (the
            // arriving row reports where the ghost lands). `glides` is read in the event
            // closure, not the body, so it observes nothing.
            guard isDragged || isHovering || !RowGlideAnimator.shared.glides.isEmpty else { return }
            windowFrame.note(frame)
            // A row that has just arrived where a ghost of it is headed tells the ghost where to land.
            RowGlideAnimator.shared.land(threadID: thread.id, settled: snapshot.isSettled, at: frame)
        }
        .opacity(isHidden ? 0 : 1)
        // Hiding is instant, since the ghost takes over the row's frame in the same pass;
        // showing eases in over the 0.12 s handover window in which the ghost still covers
        // the row (see `RowGlideAnimator`).
        .animation(isHidden ? nil : .easeOut(duration: 0.12), value: isHidden)
        // Lifted: a touch larger with a shadow, over an opaque fill so the rows sliding
        // underneath never show through. The queue's rows lift the same way.
        .background {
            if isDragged {
                shape
                    .fill(Chrome.overlay(0.12))
                    .shadow(color: .black.opacity(performanceMode ? 0 : 0.28), radius: performanceMode ? 0 : 10, y: performanceMode ? 0 : 4)
            }
        }
        .scaleEffect(isDragged ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
        // Snapshots only: the menu builder must not capture the row (its frames, its settle
        // handlers), so the AppKit menu it builds cannot pin row state after dismiss. Settle
        // and reopen go through finishRequest, which the row takes up with its glide below.
        .contextMenu { [thread, model, menuRequests] in
            let threadSnapshot = thread
            let modelSnapshot = model
            let requestsSnapshot = menuRequests
            let settleFirstSnapshot = !threadSnapshot.isHelper && modelSnapshot.settings.threadFinishAction == .settle
            RowActionMenuButtons(actions: ThreadActions.makeContextMenu(
                model: modelSnapshot,
                thread: threadSnapshot,
                settleFirst: settleFirstSnapshot,
                requests: requestsSnapshot
            ))
        }
        // A settle or reopen asked for from the menu, the shortcut or the palette lands here,
        // so it looks the same as a click on the check.
        .onChange(of: model.finishRequest) { _, request in
            guard let request, request.threadID == thread.id, request.reopens == isSettled else { return }
            model.finishRequest = nil
            if request.reopens { reopen() } else { settle() }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityValue(Text(verbatim: isSettled ? Chrome.localized("Settled") : ""))
    }

    private static func fill(isSelected: Bool, isHovering: Bool) -> Double {
        if isSelected { return 0.12 }
        return isHovering ? 0.06 : 0
    }

    /// Value inputs only: closures and the frame holder are ignored, so the parent's
    /// re-evaluation skips rows whose thread did not change. Live state still reaches the
    /// body through the model's per-thread cells.
    static func == (lhs: SidebarThreadRow, rhs: SidebarThreadRow) -> Bool {
        lhs.snapshot.id == rhs.snapshot.id
            && lhs.snapshot.title == rhs.snapshot.title
            && lhs.snapshot.updatedAt == rhs.snapshot.updatedAt
            && lhs.snapshot.isPinned == rhs.snapshot.isPinned
            && lhs.snapshot.isSettled == rhs.snapshot.isSettled
            && lhs.projectName == rhs.projectName && lhs.projectIcon == rhs.projectIcon && lhs.tag == rhs.tag
            && lhs.isDragged == rhs.isDragged
            && (lhs.onToggleFold != nil) == (rhs.onToggleFold != nil)
    }

    /// Clearance for overlaid buttons. The time and waiting badge participate in the
    /// face's layout and reserve only their actual width.
    private static func trailingClearance(isSettled: Bool, isDetailed: Bool, showsActions: Bool, showsFold: Bool = false) -> CGFloat {
        if showsActions { return (isSettled ? 30 : 52) + (showsFold ? 20 : 0) }
        return isDetailed || isSettled ? 18 : 0
    }

    /// Built when the ellipsis shows or the context menu opens, never on a plain render.
    private func makeActions() -> [RowAction] {
        ThreadActions.make(model: model, thread: thread, onRename: onRename, onDelete: onDelete, onSettle: settle, onReopen: reopen)
    }

    private nonisolated static func windowFrame(_ proxy: GeometryProxy) -> CGRect {
        proxy.frame(in: .named(GenieAnimator.coordinateSpace))
    }

    // MARK: Settling

    /// The row's exit on a settle: the check pops and the thread changes in the same pass, so
    /// the space closes, the rows below make room and the Settled header moves as one
    /// motion. The row itself leaves on the list's removal fade (see `AnyTransition.sidebarRow`).
    private func settle() {
        guard !isSettling, !thread.isSettled else { return }
        if model.settings.settleSound { SettleChime.play() }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { isSettling = true }
        withAnimation(Chrome.panelSlide) { model.settle(thread.id, sounds: false) }
    }

    private func reopen() {
        guard thread.isSettled else { return }
        glide()
        model.reopenAnimated(thread.id)
    }

    /// Sends the row's ghost on its way: from this row's frame, looking like this row, to
    /// where the thread's other row will be (or the list's edge, when that is out of view),
    /// looking like that one. Launched just before the thread changes, so the new row can
    /// report its frame to the ghost as it arrives. Only reopening flies; settling leaves
    /// the row in place (see `settle`).
    private func glide() {
        guard let listFrame else { return }
        let from = windowFrame.frame
        let bounds = listFrame.frame
        let isSelected = model.selectedThreadID == thread.id
        // The thread as its reopened row will show it.
        var arriving = thread
        arriving.isSettled = false
        let arrivalHeight = projectName != nil ? ThreadRowMetrics.detailedHeight : Chrome.rowHeight
        let fallback = CGRect(
            x: from.minX,
            y: bounds.minY - arrivalHeight,
            width: from.width,
            height: arrivalHeight
        )
        let animator = RowGlideAnimator.shared
        let badge = ThreadGhostBadge(thread: thread, runtime: model.existingRuntime(for: thread.id))
        // The faces leave the same room at the trailing end as the rows they stand in for: the
        // departing row is hovered, with its buttons out; the arriving one shows its status.
        let departureClearance = Self.trailingClearance(isSettled: thread.isSettled, isDetailed: projectName != nil, showsActions: true)
        let arrivalClearance = Self.trailingClearance(isSettled: false, isDetailed: projectName != nil, showsActions: false)
        guard let departure = animator.render(
            ThreadRowFace(thread: thread, projectName: projectName, projectIcon: projectIcon, isSelected: isSelected, trailingClearance: departureClearance) { badge },
            size: from.size, colorScheme: colorScheme
        ), let arrival = animator.render(
            ThreadRowFace(thread: arriving, projectName: projectName, projectIcon: projectIcon, isSelected: isSelected, trailingClearance: arrivalClearance, showsTime: projectName == nil) { badge },
            size: CGSize(width: from.width, height: arrivalHeight), colorScheme: colorScheme
        ) else { return }
        animator.launch(
            threadID: thread.id,
            from: from,
            fallback: fallback,
            bounds: bounds,
            departure: departure,
            arrival: arrival,
            departureFill: Self.fill(isSelected: isSelected, isHovering: isHovering),
            arrivalFill: Self.fill(isSelected: isSelected, isHovering: false)
        )
    }

    /// What the team's merge is doing, with an ellipsis, while it runs; nil otherwise.
    static func mergeStage(of runtime: ThreadRuntime?) -> String? {
        guard let runtime, runtime.isHydraMerging else { return nil }
        return MergeStageText.localized(runtime.hydraMergeStage ?? "Merging") + "\u{2026}"
    }

    // MARK: Archiving

    private func archiveWithGenie() {
        let isSelected = model.selectedThreadID == thread.id
        // The ghost mirrors the row's label — same text, badge, padding and
        // translucent fill — so the row hands over to it without a visible change.
        let fill = Chrome.overlay(isSelected ? 0.12 : 0.06)
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        let badge = ThreadGhostBadge(thread: thread, runtime: model.existingRuntime(for: thread.id))
        GenieAnimator.shared.launch(frame: windowFrame.frame, colorScheme: colorScheme) {
            ThreadRowFace(thread: thread, projectName: projectName, projectIcon: projectIcon, isSelected: isSelected, trailingClearance: 52) { badge }
                .background { shape.fill(fill) }
        }
        withAnimation(Chrome.panelSlide) { model.archive(thread.id) }
    }
}

/// What a thread row shows: the badge, title and project line while the thread is open, one
/// small grey title with room for the check once it has settled. The live row and its ghosts
/// draw the same face, so a ghost takes over from the row without a visible change.
private struct ThreadRowFace<Badge: View>: View {
    let thread: ChatThread
    /// The project under the title in the activity layout; nil in the project layout.
    let projectName: String?
    var projectIcon: ProjectIcon? = nil
    let isSelected: Bool
    /// The room left at the trailing end for the row's overlaid buttons.
    let trailingClearance: CGFloat
    var showsTime = false
    var tag: String? = nil
    /// Background requests stay legible in either sidebar layout, beside the title.
    var waitingStatus: ThreadActivityStatus? = nil
    /// What the team's merge is doing, shown in the project line's place while it runs.
    var mergeStage: String? = nil
    /// The badge at the front of an open row in the project layout.
    @ViewBuilder let badge: Badge

    var body: some View {
        let isSettled = thread.isSettled
        let isDetailed = projectName != nil && !isSettled
        HStack(spacing: ThreadRowMetrics.titleGap) {
            Group {
                if !isSettled {
                    badge
                } else {
                    Color.clear
                }
            }
            .frame(width: Chrome.iconSize)
            .transition(.opacity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: ThreadRowMetrics.titleItemGap) {
                    if isSettled { badge }
                    if let projectIcon, !isDetailed, !isSettled {
                        ProjectIconMark(icon: projectIcon, size: ThreadRowMetrics.inlineProjectIconSize)
                            .frame(width: ThreadRowMetrics.inlineProjectIconSize)
                    }
                    Text(verbatim: thread.title)
                        .font(.ui(size: isSettled ? 12 : 13, weight: thread.hasUnread || (!isSettled && isSelected) ? .medium : .regular))
                        .foregroundStyle(Chrome.primaryText.opacity(Self.titleOpacity(isSettled: isSettled, isSelected: isSelected)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if thread.isPinned {
                        SidebarSymbol("pin.fill", scale: 0.9)
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
                if let projectName, !isSettled {
                    HStack(spacing: 4) {
                        Image(systemName: thread.worktreePath == nil ? "folder" : "arrow.triangle.branch").font(.symbol(.footnote))
                        Text(verbatim: mergeStage ?? projectName)
                            .font(.ui(.callout))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Chrome.secondaryText)
                    .transition(.opacity)
                }
            }
            Spacer(minLength: showsTime ? 0 : 4)
            if let waitingStatus { ThreadWaitingBadge(status: waitingStatus) }
            else if showsTime {
                Group {
                    if let tag {
                        Text(verbatim: tag).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 90)
                            .help(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    } else { RelativeTimeLabel(date: thread.updatedAt).fixedSize(horizontal: true, vertical: false) }
                }
            }
        }
        .padding(.leading, Chrome.rowHorizontalPadding)
        .padding(.trailing, Chrome.rowHorizontalPadding + trailingClearance)
        .padding(.vertical, isDetailed ? ThreadRowMetrics.detailedVerticalPadding : 0)
        .frame(minHeight: isSettled ? ThreadRowMetrics.settledHeight : Chrome.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A settled title is grey; selected, it comes up a little so the selection reads.
    private static func titleOpacity(isSettled: Bool, isSelected: Bool) -> Double {
        if isSettled { return isSelected ? 0.75 : 0.55 }
        return isSelected ? 1 : 0.92
    }
}

/// The badge as a ghost carries it: the same marks as ThreadBadge, from a snapshot of the
/// runtime, with the spinner held still because a ghost is an image and cannot animate.
private struct ThreadGhostBadge: View {
    let thread: ChatThread
    let status: ThreadActivityStatus

    init(thread: ChatThread, runtime: ThreadRuntime?) {
        self.thread = thread
        status = threadActivityStatus(thread, runtime: runtime)
    }

    var body: some View {
        ThreadStatusMark(status: status, isStill: true)
    }
}

/// The check on a thread row. Open, it shows on hover at the trailing end and settles the
/// thread; settled, it is the green mark at the front of the row, and clicking it reopens
/// the thread. Hovering a settled one outlines it, the way a box about to be unticked would.
private struct SettleCheck: View {
    let isSettled: Bool
    /// Just clicked: filled green and popped, while the thread is about to settle.
    let isPopping: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let isDone = isSettled || isPopping
        let filled = isPopping || (isSettled && !isHovering)
        Button(action: action) {
            Image(systemName: filled ? "checkmark.circle.fill" : "checkmark.circle")
                .font(Chrome.inlineIconFont)
                .foregroundStyle(isDone || isHovering ? Chrome.success.opacity(isSettled && !isHovering ? 0.8 : 1) : Chrome.secondaryText)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20, height: 20)
                .contentShape(.rect)
                .scaleEffect(isPopping ? 1.35 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: isSettled ? Chrome.localized("Reopen thread") : Chrome.localized("Settle thread")))
        .accessibilityLabel(Text(verbatim: isSettled ? Chrome.localized("Reopen thread") : Chrome.localized("Settle thread")))
    }
}

private struct ThreadBadge: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread

    var body: some View {
        let runtime = model.existingRuntime(for: thread.id)
        let mergeStage = SidebarThreadRow.mergeStage(of: runtime)
        let backgroundCount = runtime?.backgroundTasks.count ?? 0
        let runningHelp = mergeStage ?? runtime?.nativeWorkDescription ?? (runtime?.isRunning != true && backgroundCount > 0 ? (backgroundCount == 1 ? Chrome.localized("Waiting on a background task") : String(format: Chrome.localized("Waiting on %lld background tasks"), backgroundCount)) : nil)
        ThreadStatusMark(status: threadActivityStatus(thread, runtime: runtime), runningHelp: runningHelp)
    }
}

/// Carries sidebar context-menu intents outside any row's @State. An AppKit context menu
/// outlives the right-click that opened it, so its callbacks must never retain a row's
/// state storage: menu -> closure -> row state -> view node -> menu responder is the back
/// edge that pinned ContextMenuResponder/NSMenu pairs after dismiss. Menu actions post a
/// value-type request here; the list takes it up. The rows and the menu hold this box
/// strongly: it belongs to the list, so nothing of a row hangs off it, and there is no
/// cycle back to the menu. Owned by the list's @State, touched on the main thread only.
@Observable
private final class SidebarMenuRequests {
    var rename: ChatThread?
    var delete: ChatThread?
}

/// What a thread row offers from its ellipsis popover and its context menu, in both sidebar layouts.
@MainActor
private enum ThreadActions {
    static func make(
        model: AppModel,
        thread: ChatThread,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSettle: (() -> Void)? = nil,
        onReopen: (() -> Void)? = nil
    ) -> [RowAction] {
        var items = [RowAction(title: "Rename", symbol: "pencil") { onRename() }]
        // A helper keeps its place under its parent, and a settled thread its place at the
        // bottom; pinning would pull either out of it.
        if !thread.isHelper, !thread.isSettled {
            items.append(RowAction(title: thread.isPinned ? "Unpin" : "Pin", symbol: thread.isPinned ? "pin.slash" : "pin") {
                withAnimation(Chrome.panelSlide) {
                    model.updateThread(thread.id) { $0.isPinned.toggle() }
                }
            })
        }
        // Forwarding starts a new thread that continues this one, at the same place in
        // the list rather than under the settle/archive group.
        items.append(RowAction(title: "Forward to new thread", symbol: "arrowshape.turn.up.right") {
            Task { await model.forwardThread(thread.id) }
        })
        if let path = thread.worktreePath {
            items.append(RowAction(title: "Reveal worktree in Finder", symbol: "folder") { Workspace.revealInFinder(path) })
        }
        // A helper has no place of its own to settle into: it only archives, with its parent
        // or on its own. A thread offers both, the one Settings chose first.
        let settleFirst = !thread.isHelper && model.settings.threadFinishAction == .settle
        let archive = RowAction(title: "Archive", symbol: "archivebox", startsGroup: !settleFirst) {
            withAnimation(Chrome.panelSlide) { model.archive(thread.id) }
        }
        if thread.isHelper {
            items.append(archive)
        } else {
            let settle = RowAction(
                title: thread.isSettled ? "Reopen" : "Settle",
                symbol: thread.isSettled ? "arrow.uturn.backward" : "checkmark.circle",
                startsGroup: settleFirst
            ) {
                // The row's own handlers fly the ghost; without them the thread just moves.
                if thread.isSettled {
                    if let onReopen { onReopen() } else { model.reopenAnimated(thread.id) }
                } else if let onSettle {
                    onSettle()
                } else {
                    model.settleAnimated(thread.id)
                }
            }
            items += settleFirst ? [settle, archive] : [archive, settle]
        }
        items.append(RowAction(title: "Delete…", symbol: "trash", isDestructive: true) { onDelete() })
        return items
    }

    /// The context menu's items, built from value snapshots with weak captures: the AppKit
    /// menu outlives the right-click, so its callbacks must not retain the row, its frames,
    /// or its settle handlers. Rename and delete post to `requests`; the list takes them up. Settle and reopen post a finish request, which the row takes up with
    /// its pop and glide, the way the shortcut's and palette's do. Everything else touches
    /// only the model. (The ellipsis popover keeps `make`; it is not an AppKit menu.)
    static func makeContextMenu(
        model: AppModel,
        thread: ChatThread,
        settleFirst: Bool,
        requests: SidebarMenuRequests
    ) -> [RowAction] {
        let threadID = thread.id
        var items = [RowAction(title: "Rename", symbol: "pencil") { [weak model, requests, thread] in
            guard model != nil else { return }
            requests.rename = thread
        }]
        // A helper keeps its place under its parent, and a settled thread its place at the
        // bottom; pinning would pull either out of it.
        if !thread.isHelper, !thread.isSettled {
            let isPinned = thread.isPinned
            items.append(RowAction(title: isPinned ? "Unpin" : "Pin", symbol: isPinned ? "pin.slash" : "pin") { [weak model, threadID] in
                guard let model else { return }
                withAnimation(Chrome.panelSlide) {
                    model.updateThread(threadID) { $0.isPinned.toggle() }
                }
            })
        }
        // Forwarding starts a new thread that continues this one, at the same place in
        // the list rather than under the settle/archive group.
        items.append(RowAction(title: "Forward to new thread", symbol: "arrowshape.turn.up.right") { [weak model, threadID] in
            guard let model else { return }
            Task { await model.forwardThread(threadID) }
        })
        if let path = thread.worktreePath {
            items.append(RowAction(title: "Reveal worktree in Finder", symbol: "folder") { [weak model, path] in
                guard model != nil else { return }
                Workspace.revealInFinder(path)
            })
        }
        // A helper has no place of its own to settle into: it only archives, with its parent
        // or on its own. A thread offers both, the one Settings chose first.
        let archive = RowAction(title: "Archive", symbol: "archivebox", startsGroup: !settleFirst) { [weak model, threadID] in
            guard let model else { return }
            withAnimation(Chrome.panelSlide) { model.archive(threadID) }
        }
        if thread.isHelper {
            items.append(archive)
        } else {
            let isSettled = thread.isSettled
            let settle = RowAction(
                title: isSettled ? "Reopen" : "Settle",
                symbol: isSettled ? "arrow.uturn.backward" : "checkmark.circle",
                startsGroup: settleFirst
            ) { [weak model, threadID, isSettled] in
                guard let model else { return }
                model.finishRequest = AppModel.FinishRequest(threadID: threadID, reopens: isSettled)
            }
            items += settleFirst ? [settle, archive] : [archive, settle]
        }
        items.append(RowAction(title: "Delete…", symbol: "trash", isDestructive: true) { [weak model, requests, thread] in
            guard model != nil else { return }
            requests.delete = thread
        })
        return items
    }
}

private struct ActivityHeader: View {
    let title: String
    let isFirst: Bool

    var body: some View {
        Text(verbatim: Chrome.localized(title))
            .font(.ui(.callout, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, Chrome.rowHorizontalPadding)
            .padding(.top, isFirst ? 2 : 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Settled section's header: a disclosure chevron, the title and its count. Clicking
/// it folds the settled threads away or brings them back, with the sidebar's motion. The
/// choice persists in settings, so the section stays as left across relaunch.
private struct SettledHeader: View {
    @Environment(AppModel.self) private var model
    let count: Int
    let isFirst: Bool

    var body: some View {
        let collapsed = model.settings.settledCollapsed
        Button {
            withAnimation(Chrome.panelSlide) {
                model.settings.settledCollapsed.toggle()
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "chevron.right").font(.symbol(.caption2, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .animation(Chrome.panelSlide, value: collapsed)
                Text(verbatim: Chrome.localized("Settled"))
                    .font(.ui(.callout, weight: .semibold))
                // Update the digits without a separate roll while the whole header moves.
                // Keep the inherited layout animation so the count travels with the title.
                Text(verbatim: "\(count)")
                    .font(.ui(.callout))
                    .monospacedDigit()
                    .opacity(0.8)
                    .fixedSize()
                    .contentTransition(.identity)
                Spacer(minLength: 4)
            }
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, Chrome.rowHorizontalPadding)
            .padding(.top, isFirst ? 2 : 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .animation(Chrome.panelSlide, value: isFirst)
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: collapsed ? Chrome.localized("Show settled threads") : Chrome.localized("Hide settled threads")))
        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Settled, %d threads"), count)))
        .accessibilityValue(Text(verbatim: collapsed ? Chrome.localized("Collapsed") : Chrome.localized("Expanded")))
        .accessibilityAddTraits(.isButton)
    }
}

@MainActor
private func threadActivityStatus(_ thread: ChatThread, runtime: ThreadRuntime?) -> ThreadActivityStatus {
    ThreadActivityStatus.resolve(
        lastStatus: thread.unreadStatus ?? thread.lastStatus,
        hasUnread: thread.hasUnread,
        needsApproval: !(runtime?.approvals.isEmpty ?? true),
        needsAnswer: !(runtime?.questions.isEmpty ?? true),
        isWorking: runtime?.isRunning == true || runtime?.hasNativeWork == true || runtime?.isHydraMerging == true || runtime?.hasWorkingHelpers == true || !(runtime?.backgroundTasks.isEmpty ?? true) || runtime?.isWaitingForLimit == true
    )
}

/// A row's latest frame, kept out of SwiftUI's observation: scrolling updates it on every frame,
/// and only an archive tap ever reads it. Writes skip when unchanged, so a resize frame
/// that moved nothing in the row costs nothing.
private final class FrameHolder {
    var frame: CGRect = .zero

    func note(_ frame: CGRect) {
        guard frame != self.frame else { return }
        self.frame = frame
    }
}

/// Every row's measured height, kept out of observation for the same reason: the list writes
/// one on every layout pass, and only a drag reads them. Unchanged reports are skipped,
/// so a width-only pass never touches the table.
private final class RowHeights {
    var values: [String: CGFloat] = [:]

    func note(_ id: String, _ height: CGFloat) {
        guard values[id] != height else { return }
        values[id] = height
    }
}

/// The Projects header's top in the list, kept out of observation like the heights: the
/// header reports as it lays out, and only a project drag reads it. Nil until the list has
/// laid the header out once.
private final class HeaderTop {
    var value: CGFloat?

    func note(_ top: CGFloat) {
        guard value != top else { return }
        value = top
    }
}

/// Every open thread row's frame in the list's space, kept out of observation like the
/// heights: the rows write as they lay out, and only the grab of a drag reads them.
private final class RowFrames {
    private var frames: [UUID: CGRect] = [:]

    func frame(of id: UUID) -> CGRect? { frames[id] }

    func note(_ id: UUID, _ frame: CGRect) {
        guard frames[id] != frame else { return }
        frames[id] = frame
    }

    func forget(_ id: UUID) {
        frames[id] = nil
    }

    /// The thread whose row is under `point`, if an open one is.
    func thread(at point: CGPoint) -> UUID? {
        frames.first { $0.value.contains(point) }?.key
    }
}

/// One project's search hits: the threads matching, and how many it has in all.
private struct SidebarSearchResult {
    var id: String { project?.id.uuidString ?? "tasks" }
    let project: Project?
    let threads: [ChatThread]
    let count: Int
}

/// The sidebar's `threadPlacements`, kept while a cheap fingerprint of the threads stands:
/// a selection change or hover re-renders the list without rebuilding placements for
/// hundreds of threads. The fingerprint covers every field `ThreadPlacement` reads, so a
/// placement change always rebuilds.
private final class PlacementCache {
    private struct Fingerprint: Equatable {
        let id: UUID
        let projectID: UUID?
        let parentThreadID: UUID?
        let isArchived: Bool
        let isInPanel: Bool
        let isSettled: Bool
        let settledAt: Date?
        let isPinned: Bool
        let sortOrder: Double?
        let activityOrder: Double?
        let activityOrderDay: Date?
        let createdAt: Date
        let updatedAt: Date
        let foldsHelpers: Bool
        let isHydraHead: Bool
        let hydraIndex: Int?
        let hasUnread: Bool

        init(_ thread: ChatThread) {
            id = thread.id
            projectID = thread.projectID
            parentThreadID = thread.parentThreadID
            isArchived = thread.isArchived
            isInPanel = thread.isInPanel
            isSettled = thread.isSettled
            settledAt = thread.settledAt
            isPinned = thread.isPinned
            sortOrder = thread.sortOrder
            activityOrder = thread.activityOrder
            activityOrderDay = thread.activityOrderDay
            createdAt = thread.createdAt
            updatedAt = thread.updatedAt
            foldsHelpers = thread.foldsHelpers
            isHydraHead = thread.isHydraHead
            hydraIndex = thread.hydra?.index
            hasUnread = thread.hasUnread
        }
    }

    private var fingerprint: [Fingerprint]?
    private var cached: [ThreadPlacement] = []

    func placements(for threads: [ChatThread]) -> [ThreadPlacement] {
        let next = threads.map(Fingerprint.init)
        if next == fingerprint { return cached }
        fingerprint = next
        cached = threads.map(ThreadPlacement.init)
        return cached
    }
}

/// The fields that decide where a thread sits in the list and how its group is ordered:
/// which project or parent it is under, whether it is shown at all, settled, pinned or
/// folded, and the dates and orders the sorts read. A title, an unread flag or a head's
/// progress note changes none of them, so those never rebuild the list; the rows read
/// them through the model's per-thread cells instead.
private struct ThreadPlacement: Equatable {
    let id: UUID
    let projectID: UUID?
    let parentThreadID: UUID?
    let isArchived: Bool
    let isInPanel: Bool
    let isSettled: Bool
    let settledAt: Date?
    let isPinned: Bool
    let sortOrder: Double?
    /// The activity layout's own order within a day (see `placed`).
    let activityOrder: Double?
    let activityOrderDay: Date?
    let createdAt: Date
    let updatedAt: Date
    let foldsHelpers: Bool
    let isHydraHead: Bool
    let hydraIndex: Int?
    let hasUnread: Bool

    init(_ thread: ChatThread) {
        id = thread.id
        projectID = thread.projectID
        parentThreadID = thread.parentThreadID
        isArchived = thread.isArchived
        isInPanel = thread.isInPanel
        isSettled = thread.isSettled
        settledAt = thread.settledAt
        isPinned = thread.isPinned
        sortOrder = thread.sortOrder
        activityOrder = thread.activityOrder
        activityOrderDay = thread.activityOrderDay
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
        foldsHelpers = thread.foldsHelpers
        isHydraHead = thread.isHydraHead
        hydraIndex = thread.hydra?.index
        hasUnread = thread.hasUnread
    }
}

/// The sidebar's built list, kept while its inputs stand, the way `TimelineBlockCache`
/// keeps a chat's blocks. The key holds each thread's placement (not the thread: a title
/// or a progress note is the row's to pick up) and the project array itself, so a render
/// that moved nothing costs one pass of comparisons and no filter or sort, and one that
/// did rebuilds exactly once. Owned by the list's @State, main thread only.
private final class SidebarItemCache {
    struct Key: Equatable {
        var placements: [ThreadPlacement]
        var projects: [Project]
        var projectThreadLimits: [UUID: Int]
        /// The threads heading the activity layout under "Needs attention".
        var attention: Set<UUID>
        var activityView: Bool
        var activityThreadStyle: ActivityThreadStyle
        var settledCollapsed: Bool
        /// The sidebar's head-card option, and the parents that still draw a card under it.
        var autoHidesIdleHeads: Bool
        var parentsShowingHeads: Set<UUID>
        var projectsCollapsed: Bool
        var tasksCollapsed: Bool
        var sectionOrder: SidebarSectionOrder
        var draggingProject: UUID?
        var today: Date?
    }

    struct SearchKey: Equatable {
        var threads: [ChatThread]
        var projects: [Project]
        var query: String
    }

    private var key: Key?
    private var built: [SidebarItem] = []
    private var helpersFor: [ThreadPlacement]?
    private var helpers: [UUID: [ChatThread]] = [:]
    private var searchKey: SearchKey?
    private var found: [SidebarSearchResult] = []
    /// Each thread's title lowercased once, for the search to match against; a thread
    /// keeps its entry until its title changes.
    private var titlesFor: [ChatThread]?
    private var titles: [UUID: String] = [:]

    func items(for wanted: Key, build: () -> [SidebarItem]) -> [SidebarItem] {
        if wanted == key { return built }
        built = build()
        key = wanted
        return built
    }

    /// The helper grouping, kept while the placements stand; `group` runs only when they changed.
    func helpers(for placements: [ThreadPlacement], group: () -> [UUID: [ChatThread]]) -> [UUID: [ChatThread]] {
        if placements == helpersFor { return helpers }
        helpers = group()
        helpersFor = placements
        return helpers
    }

    func search(for wanted: SearchKey, find: ([UUID: String]) -> [SidebarSearchResult]) -> [SidebarSearchResult] {
        if wanted == searchKey { return found }
        found = find(lowercasedTitles(for: wanted.threads))
        searchKey = wanted
        return found
    }

    private func lowercasedTitles(for threads: [ChatThread]) -> [UUID: String] {
        if threads == titlesFor { return titles }
        var next: [UUID: String] = [:]
        next.reserveCapacity(threads.count)
        // Only a title that changed is lowercased again; the rest carry over.
        let previous = titlesFor.map { Dictionary($0.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        for thread in threads {
            if previous[thread.id] == thread.title, let kept = titles[thread.id] {
                next[thread.id] = kept
            } else {
                next[thread.id] = thread.title.lowercased()
            }
        }
        titles = next
        titlesFor = threads
        return titles
    }
}

/// The minute hand behind the sidebar's relative times. One tick for the whole list, read by
/// the time labels and nothing else, so an idle app keeps "3m" truthful without re-rendering
/// the rows around it.
@MainActor
@Observable
final class MinuteClock {
    static let shared = MinuteClock()

    private(set) var now = Date.now

    @ObservationIgnored private var tick: Task<Void, Never>?

    private init() {
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.now = .now
            }
        }
    }
}

/// How long ago a thread was last active, at the trailing end of its row. A view of its own,
/// so the minute's tick re-renders this label alone.
private struct RelativeTimeLabel: View {
    let date: Date

    var body: some View {
        Text(verbatim: RelativeTime.short(date, now: MinuteClock.shared.now))
            .font(.ui(.subheadline).monospacedDigit())
            .foregroundStyle(Chrome.secondaryText.opacity(0.8))
            .padding(.trailing, 4)
    }
}
