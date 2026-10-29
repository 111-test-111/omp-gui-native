import AppKit
import SwiftUI

struct ThreadTimeline: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(WindowLiveResize.self) private var liveResize
    @Environment(\.reserveSlideLeading) private var reserveSlideLeading
    @Environment(\.reserveSlideOffset) private var reserveSlideOffset
    @Environment(\.filePreviewAction) private var filePreviewAction
    @Environment(\.openURL) private var inheritedOpenURL
    @Environment(\.chatMathPreparation) private var mathPreparation
    let runtime: ThreadRuntime
    let scrollChrome: ChromeScrollModel
    let scrollState: TimelineScrollState
    let projectName: String?
    /// The folder the thread works in, for tool rows that resolve paths. Read once by the
    /// chat and handed down as a value, so rows never look the thread up themselves.
    let workingDirectory: String?
    /// Whether the thread's provider can rewind a conversation, for the revert controls.
    let supportsRewind: Bool
    /// Full chat-column height, so the rail stays centred when the composer
    /// or queue tab grows.
    let columnHeight: CGFloat
    /// Whether the rail is shown at all; a panel docked on the left takes its edge.
    var showsMinimap = true
    /// The main chat masks its own scroll view. Panels leave this false and keep
    /// `.chromeEdgeFade`.
    var usesTimelineTopFade = false
    /// Main chats put the empty prompt above their centred composer; helper panels keep it here.
    var showsNewThreadPrompt = true

    /// The chat re-renders whenever its thread changes (a title, the effort, a mode); the
    /// timeline only follows when what it was handed changed.
    nonisolated static func == (lhs: ThreadTimeline, rhs: ThreadTimeline) -> Bool {
        lhs.runtime === rhs.runtime
            && lhs.scrollChrome === rhs.scrollChrome
            && lhs.scrollState === rhs.scrollState
            && lhs.projectName == rhs.projectName
            && lhs.workingDirectory == rhs.workingDirectory
            && lhs.supportsRewind == rhs.supportsRewind
            && lhs.columnHeight == rhs.columnHeight
            && lhs.showsMinimap == rhs.showsMinimap
            && lhs.usesTimelineTopFade == rhs.usesTimelineTopFade
            && lhs.showsNewThreadPrompt == rhs.showsNewThreadPrompt
    }

    /// Everything the scroll view and the rows report while the reader scrolls: which blocks
    /// are on screen and whether the timeline follows new text. It lives in an object rather
    /// than in view state on purpose. Rows write to it as they cross the viewport's edges and
    /// the scroll view writes to it as content grows, and only the rail reads it, so none of
    /// that ever re-runs this body. The one thing it tells the body is the rare request to
    /// check its own layout (`repairLayout`).
    @State private var tracking = TimelineScrollTracking()
    /// The scroll position stays view state, never a property of an observable object. A
    /// `scrollTo` request is consumed by the scroll view writing the resolved position back
    /// through the binding; on an observable, that write's `willSet` re-ran this body while
    /// the property still held the pending request, so the scroll view enqueued it again,
    /// without end. `@State` applies the write first and re-renders after.
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var viewportHeight: CGFloat = 0
    /// The scroll view's width, for the stepped layout width during a live resize.
    @State private var paneWidth: CGFloat = 0
    /// While the window is being dragged the content wraps to a width that moves in
    /// steps this wide, so rows re-measure a few times over a drag instead of every
    /// frame; the exact width lands when the drag ends.
    private static let resizeStep: CGFloat = 12
    private var layoutWidth: CGFloat? {
        // Sidebar motion now holds the entire native chat host at its final
        // width. Applying another predicted delta here would rewrap it twice.
        let dragging = liveResize.isActive || model.sidebar.isDragging || runtime.isTerminalResizing || liveResize.isPreviewResizing
        guard dragging, paneWidth > 0 else { return nil }
        return min(760 + 40, (paneWidth / Self.resizeStep).rounded(.down) * Self.resizeStep)
    }
    /// Which edge stays put when the content's height changes. At the conversation's end
    /// it is the bottom, so streaming text and the working line grow in place. Once the
    /// reader has scrolled up it is the top: a row expanded mid-thread then pushes what
    /// follows down and stays under the pointer, instead of the whole timeline lurching
    /// up by the expansion's height to keep the far-off bottom edge fixed.
    @State private var anchorsBottomOnGrowth = true
    /// Older history is about to be loaded above the viewport; that growth keeps the
    /// bottom fixed whatever the reader is doing, so the messages in view stay put.
    @State private var historyLoadPending = false
    /// Where the lazy window begins: the id of its oldest block. The window runs from that
    /// block to the end, so a block appended at the end never evicts an older row from the
    /// stack; only loading history or a jump moves the start. Nil until the thread anchors,
    /// when the newest `firstPaint` blocks are the window.
    @State private var windowStartID: String?
    /// The blocks the stack builds, by identity; the rest of the window stands in as exact
    /// spacers of their measured heights. Nil builds the whole window: before anything is
    /// measured, after the width changed, and as the last repair of a blank viewport.
    @State private var mountedWindow: MountedWindow?
    @State private var measurements = TimelineMeasurements()
    /// The runtime's unattended-turn token as this view last saw it (see
    /// `ThreadRuntime.autoStartedTurnToken`). Nil until the first turn this view sees
    /// start, so a view that appears mid-conversation reads its next turn as a send.
    @State private var seenAutoStartedTurnToken: Int?
    /// Changes to rebuild the mounted stack from scratch: the second repair for a viewport
    /// the stack has built nothing for (see `repairLayout`).
    @State private var stackGeneration = 0
    /// The rows' disclosure callbacks, made once for the timeline's life.
    @State private var revealBox = TimelineRevealBox()
    /// The blocks as last built. This body re-runs for plenty of reasons the conversation
    /// knows nothing about (the reader starting or ending a scroll, the column resizing, a
    /// setting elsewhere), and partitioning every entry into blocks again each time is work
    /// the stack throws straight away. It lives in an object, so reusing a build is not a
    /// state write.
    private var blockCache: TimelineBlockCache { TimelineBlockCache.cache(for: runtime.threadID) }

    var body: some View {
        let entries = runtime.entries
        // Nothing here reads an entry's content: the cache keys on identities and kinds,
        // so a streaming row redraws itself and never brings this body with it.
        // Every unarchived head, in the panel or not: a finished head that has already left
        // the panel for the sidebar (auto-clear, or Clear finished heads) keeps its pill
        // until its batch reports, so the list is not the panel's.
        let team = model.helpers(of: runtime.threadID).filter(\.isHydraHead)
        let finished = HydraHeadsWorkingRow.finishedHeads(in: team).sorted { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        let since = runtime.isRunning ? runtime.turnStartedAt : nil
        let earlier = since.map { cut in finished.filter { ($0.finishedAt ?? .distantPast) < cut } } ?? []
        let later = finished.filter { head in !earlier.contains { $0.index == head.index } }
        let completed = blockCache.completions(heads: model.children(of: runtime.threadID).compactMap(\.hydra),
            entries: entries, revision: runtime.entriesStructureRevision, turns: runtime.turns)
        let linked = Set(completed.values.flatMap { $0 })
        let pills = HeadPills(earlier: earlier.map(\.index).filter { !linked.contains($0) },
                              later: later.map(\.index).filter { !linked.contains($0) }, byTurn: completed)
        // A backgrounded command still running after the turn ended: kept out of the cache,
        // so the row comes and goes with the list.
        let nativeWaiting = runtime.backgroundTasks.isEmpty
            ? runtime.nativeWorkDescription.map { [$0] } ?? [] : runtime.backgroundTasks
        let waiting = !runtime.isRunning && !runtime.isHydraMerging ? nativeWaiting : []
        let blocks = DisplayBlock.addingBackgroundTasks(waiting, to: blockCache.blocks(
            for: entries,
            showReasoning: model.settings.showReasoning, isRunning: runtime.isRunning,
            hydraMergeID: runtime.isHydraMerging ? (runtime.hydraMergeNoteID ?? "hydra-merging") : nil,
            pills: pills
        ))
        // Every head the chat ever sent out, not only those still in the panel: a head that
        // finished and left for the sidebar is still named in the prose above, and keeps its
        // glyph and colour there rather than falling back to plain text as it clears. With
        // Hydra on, the whole roster besides: the lead names its heads in the prose before
        // the block that sends them out, so a name is drawn as its head from the first
        // frame rather than as plain text until the spawn lands.
        let headThreads = model.children(of: runtime.threadID).filter(\.isHydraHead)
        let hydraMentionPersonas = blockCache.mentionPersonas(
            for: headThreads,
            roster: model.thread(runtime.threadID).map(model.hydraIsOn) ?? false
        )
        // A head's name in the prose leads to its own chat. A reused name points at the
        // newest head, so the oldest heads lose: iterate oldest first and let each write
        // over the last.
        let hydraMentionTargets = Self.mentionTargets(for: headThreads)
        // A history still being read off the main thread is not an empty thread: the
        // prompt for a new one would flash for the frames before it lands. Its newest
        // turns land first and show while the older ones are read.
        if runtime.thread?.hydra?.kind == .native && blocks.isEmpty {
            VStack(spacing: 12) {
                if runtime.nativeAgentHistoryLoading { ProgressView().controlSize(.small) }
                Text(verbatim: runtime.nativeAgentHistoryIssue ?? Chrome.localized(runtime.nativeAgentHistoryLoading
                    ? "Loading OMP worker history…" : "OMP has not saved any worker messages yet."))
                    .font(.chat(.body))
                    .foregroundStyle(Chrome.secondaryText)
                    .textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if runtime.isLoadingHistory && blocks.isEmpty {
            Color.clear
        } else if blocks.isEmpty && !runtime.isRunning {
            // A forwarded thread starts empty too, but it is not a new one: it explains
            // where it came from before the reader picks anything.
            Group {
                if let continuation = runtime.continuation {
                    continuationStart(continuation)
                } else if showsNewThreadPrompt {
                    NewThreadPrompt(threadID: runtime.threadID, projectName: projectName)
                } else {
                    Color.clear
                }
            }
            .onAppear {
                scrollChrome.update(travel: 0)
                if scrollState.showsJumpButton { scrollState.showsJumpButton = false }
            }
        } else {
            timeline(blocks, hydraMentionPersonas: hydraMentionPersonas, hydraMentionTargets: hydraMentionTargets)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let issue = runtime.nativeAgentHistoryIssue {
                        Text(verbatim: issue).font(.chat(.callout)).foregroundStyle(Chrome.warning)
                            .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Chrome.overlay(0.04))
                    }
                }
        }
    }

    /// Every head by its persona name, oldest first so a reused name lands on the newest head.
    private static func mentionTargets(for heads: [ChatThread]) -> [String: HydraMentionTarget] {
        var targets: [String: HydraMentionTarget] = [:]
        for head in heads.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let info = head.hydra else { continue }
            targets[info.persona.name] = HydraMentionTarget(threadID: head.id, task: info.task, status: info.status)
        }
        return targets
    }

    /// What an empty forwarded thread shows before its first message: the source it
    /// continues, the choice still to make, and the way back to the original. Never the
    /// carried-over context itself, and never any of the source's transcript.
    private func continuationStart(_ continuation: ThreadContinuation) -> some View {
        VStack(spacing: 10) {
            ContinuationSourceLabel(sourceTitle: continuation.sourceTitle)
                .font(.chat(size: 15, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
            Text("Choose a model or Hydra pair below, then send a message to continue.")
                .font(.chat(size: 13))
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if continuation.isTruncated {
                Text("Context carried over; some messages were shortened or omitted.")
                    .font(.chat(size: 12))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The source may have been deleted since; the view still explains the
            // continuation and the button is left out.
            if model.thread(continuation.sourceThreadID) != nil {
                Button("Open original chat") {
                    model.selectedThreadID = continuation.sourceThreadID
                }
                .buttonStyle(.plain)
                .font(.chat(size: 13))
                .foregroundStyle(Chrome.accent)
                .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timeline(_ blocks: [DisplayBlock], hydraMentionPersonas: [HydraPersona], hydraMentionTargets: [String: HydraMentionTarget]) -> some View {
        // The window is anchored on identity rather than a fixed suffix, so a block
        // appended at the end never pushes one out the front in the same pass. Older
        // history still loads on demand; only this start moves.
        let startIndex = windowStartIndex(in: blocks)
        let hidden = startIndex
        let range = mountedWindow?.range(in: blocks, start: startIndex) ?? startIndex..<blocks.count
        let visible = Array(blocks[range])
        let topSpace = measurements.height(of: blocks[startIndex..<range.lowerBound])
        let bottomSpace = measurements.height(of: blocks[range.upperBound..<blocks.count])
        measurements.noteArrivals(blocks.map(\.id), questions: runtime.questions.map(\.id))
        // The turns a row may offer to revert. Read here, once, so a turn record changing
        // (checkpoints, diffs, anchors) re-runs this body alone; rows get a plain flag that
        // only changes when their own answer does.
        let rewindable: Set<UUID>
        if supportsRewind && runtime.canBranchConversation {
            rewindable = Set(runtime.turns.lazy.filter { $0.nativeUserText != nil || $0.nativeUserEntryID != nil }.map(\.id))
        } else {
            rewindable = []
        }
        // The rail floats over the timeline's leading gutter instead of taking layout
        // space, so the conversation stays centered exactly like the composer.
        // Ticks centre in the full column height, so the queue tab opening never moves them.
        return ZStack(alignment: .leading) {
            timelineScroll(blocks: blocks, visible: visible, hidden: hidden, topSpace: topSpace, bottomSpace: bottomSpace, rewindable: rewindable)
            // The rail fades with the slide of the panel that takes its edge.
            ZStack {
                if showsMinimap, blocks.count(where: \.hasUserMessage) > 1 {
                    // The rail starts under the title bar: nothing of it, not its hover
                    // tracking nor its scrub gesture, may sit over the window buttons and
                    // the chrome row at the top of the column.
                    TimelineMinimapColumn(
                        blocks: blocks,
                        tracking: tracking,
                        centerHeight: max(0, columnHeight - WindowChrome.titlebarHeight),
                        onNavigate: { id, animated in jump(to: id, in: blocks, animated: animated) }
                    )
                    .equatable()
                    .frame(width: 30)
                    .frame(maxHeight: .infinity)
                    .padding(.top, WindowChrome.titlebarHeight)
                    // The hover card reaches over the conversation instead of being painted under it.
                    .transition(.opacity)
                }
            }
            // The rail fades with the slide of the panel that takes its edge. Held mid-resize:
            // a fresh slide every frame lagged the whole chat behind the window.
            .animation(liveResize.isReshaping ? nil : Chrome.panelSlide, value: showsMinimap)
            // The rail belongs to the column's leading edge, not to the conversation that
            // re-centres beside a docked panel: the padding the slide adds is cancelled
            // without animation, the way the slide itself adds it, and the glide that
            // carries the rows is cancelled in step with them.
            .offset(x: -reserveSlideLeading)
            .animation(nil, value: reserveSlideLeading)
            .offset(x: -reserveSlideOffset)
        }
        .environment(\.hydraMentionPersonas, hydraMentionPersonas)
        .environment(\.hydraMentionTargets, hydraMentionTargets)
        .environment(\.filePreviewContext, workingDirectory.map {
            FilePreviewContext(threadID: runtime.threadID, workingDirectory: $0)
        })
        // A head's name opens that head's chat. File links keep the originating
        // runtime's directory even in a Hydra child timeline.
        .environment(\.openURL, OpenURLAction { url in
            if let headID = HydraMentionTarget.threadID(in: url) {
                model.selectedThreadID = headID
                return .handled
            }
            let context = workingDirectory.map { FilePreviewContext(threadID: runtime.threadID, workingDirectory: $0) }
            if filePreviewAction(url, context: context) { return .handled }
            if url.isHTTPWebLink {
                inheritedOpenURL(url)
                return .handled
            }
            return .systemAction
        })
    }

    /// Jump the timeline to a minimap block. A target above the loaded
    /// window first loads history down to it, then scrolls once layout
    /// exists. Jumping away from the latest unpins the follow behavior, so
    /// streaming text never yanks the reader back down.
    private func jump(to id: String, in blocks: [DisplayBlock], animated: Bool) {
        tracking.noteUserNavigation()
        let far = id == blocks.last?.id && tracking.distanceFromBottom > Self.farJump(viewportHeight)
        let previousWindow = mountedWindow
        var needsExpand = false
        if let index = blocks.firstIndex(where: { $0.id == id }) {
            let firstVisible = windowStartIndex(in: blocks)
            if index < firstVisible {
                windowStartID = blocks[index].id
                needsExpand = true
                historyLoadPending = true
            }
            tracking.isPinnedToBottom = (id == blocks.last?.id)
            anchorsBottomOnGrowth = tracking.isPinnedToBottom || needsExpand
        }
        if let index = blocks.firstIndex(where: { $0.id == id }), !tracking.isPinnedToBottom {
            // Unknown intervening rows must measure before they can become spacers.
            mountedWindow = MountedWindow(measurements.window(around: index, in: blocks, start: windowStartIndex(in: blocks), viewport: viewportHeight), in: blocks)
            needsExpand = true
        } else { mountTail(in: blocks) }
        needsExpand = needsExpand || mountedWindow != previousWindow
        let generation = tracking.navigationGeneration
        let scroll = { @MainActor in
            guard generation == tracking.navigationGeneration else { return }
            position.scrollTo(id: id, anchor: .top)
        }
        if animated && !far {
            if needsExpand {
                DispatchQueue.main.async { withAnimation(.smooth(duration: 0.35)) { scroll() } }
            } else {
                withAnimation(.smooth(duration: 0.35)) { scroll() }
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            if needsExpand {
                DispatchQueue.main.async { withTransaction(transaction) { scroll() } }
            } else {
                withTransaction(transaction) { scroll() }
            }
        }
    }

    /// Puts a reader at the end back on it, unanimated, on the next run-loop turn. One snap
    /// per turn, checked when it runs, so geometry that keeps changing cannot queue a scroll
    /// per change.
    private func scheduleBottomSnap() {
        guard tracking.placementToken == nil, !tracking.bottomSnapPending else { return }
        tracking.bottomSnapPending = true
        let generation = tracking.navigationGeneration
        DispatchQueue.main.async {
            tracking.bottomSnapPending = false
            guard tracking.placementToken == nil, generation == tracking.navigationGeneration, tracking.allowsLayoutCorrection, abs(tracking.distanceFromBottom) > 1 else { return }
            withTransaction(Self.unanimated) { position.scrollTo(edge: .bottom) }
        }
    }

    /// Brings more older blocks into the window: one page, or up to `count`. The bottom
    /// stays held while they land above the viewport, so what the reader is looking at
    /// does not move.
    private func loadEarlier(in blocks: [DisplayBlock], to count: Int? = nil) {
        guard !historyLoadPending else { return }
        let start = windowStartIndex(in: blocks)
        // `count` is how many of the newest blocks to keep; with no count, one more page
        // of older ones. The start only ever moves back, never forward: an append is not
        // a reason to hide a row that was visible a frame ago.
        let target = count.map { max(0, blocks.count - $0) } ?? max(0, start - TimelineWindow.page)
        guard target < start else { return }
        historyLoadPending = true
        anchorsBottomOnGrowth = true
        windowStartID = blocks[target].id
        // The new page has never been measured, so it is built; the blocks the reader is
        // on stay as they are rather than the whole window being built again.
        if let window = mountedWindow {
            mountedWindow = MountedWindow(lowerID: blocks[target].id, upperID: window.upperID)
        }
    }

    /// Makes the stack reach the conversation's end for a reader being taken there. Close
    /// by, the window just stretches to the end; far up, it jumps to the newest blocks
    /// alone, rather than building every block in between.
    private func mountTail(in blocks: [DisplayBlock]) {
        guard let window = mountedWindow, window.upperID != nil, !blocks.isEmpty else { return }
        if tracking.distanceFromBottom > Self.farJump(viewportHeight) {
            mountedWindow = MountedWindow(measurements.tail(of: blocks, start: windowStartIndex(in: blocks), viewport: viewportHeight), in: blocks)
        } else {
            mountedWindow = MountedWindow(lowerID: window.lowerID, upperID: nil)
        }
    }

    /// Past this distance from the end, a trip there lands at once: a glide would pass over
    /// blocks the stack holds only as spacers.
    private static func farJump(_ viewportHeight: CGFloat) -> CGFloat {
        max(1200, viewportHeight * 2)
    }

    /// The index of the first block the lazy window keeps. Anchored on identity, a block
    /// appended at the end leaves it where it was. A start whose block has left the
    /// conversation falls back to the newest `firstPaint` blocks.
    private func windowStartIndex(in blocks: [DisplayBlock]) -> Int {
        if let windowStartID, let index = blocks.firstIndex(where: { $0.id == windowStartID }) {
            return index
        }
        return max(0, blocks.count - TimelineWindow.firstPaint)
    }

    /// A scroll that lands at once, for following growth the reader is already looking at.
    private static var unanimated: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    /// Parses every finished reply's markdown off the main thread, so rows scrolling into
    /// view for the first time never parse on the frame. Cached texts are skipped.
    private func warmMarkdown() async {
        var texts: [String] = []
        for entry in runtime.entries.reversed() {
            guard case .assistant(let message) = entry.item.content, !message.isStreaming else { continue }
            texts.append(message.text)
            if texts.count == MarkdownView.warmCandidateLimit { break }
        }
        guard !texts.isEmpty else { return }
        try? await MarkdownView.warm(texts)
    }

    /// How a block arrives and leaves. It arrives softly, like everything in the app, and
    /// leaves at once: a row that lingered while it faded kept its height in the lazy
    /// stack a beat longer. A finished turn's block gets no transition at all: it comes
    /// back into the window when older history loads, and a fade over a block that can run
    /// to thousands of points is a whole-layer composite the renderer may draw as nothing.
    /// A turn that is only starting is a prompt and the working line: it arrives like a row.
    /// A work group past a few rows is the same kind of layer, so it gets none either; a
    /// small one still fades in.
    private static func transition(for block: DisplayBlock) -> AnyTransition {
        if case .turn(_, _, _, .some(_), _, _, _) = block { return .identity }
        if case .group(.work(_, let entries), _, _) = block, entries.count > softAppearLimit { return .identity }
        return rowTransition
    }

    /// The most rows a work group may hold and still arrive with the soft appear.
    private static let softAppearLimit = 8

    /// A row's own arrival and departure, inside a turn's block as in the stack.
    static let rowTransition: AnyTransition = .asymmetric(
        insertion: .modifier(active: SoftAppearModifier(isVisible: false), identity: SoftAppearModifier(isVisible: true))
            .animation(.softAppear),
        removal: .identity
    )

    /// One block row, built outside the stack because the view builder timed the
    /// compiler out on the row's modifier chain.
    private func row(_ block: DisplayBlock, rewindable: Set<UUID>) -> some View {
        let canRewind = block.turnID.map { rewindable.contains($0) } ?? false
        let context = RowContext(
            workingDirectory: workingDirectory,
            canRewind: canRewind
        )
        return DisplayBlockView(block: block, runtime: runtime, context: context)
            .equatable()
            .environment(\.timelineBlockID, block.id)
            .environment(\.timelineLiveAppearance, measurements.liveIDs.contains(block.id) && !measurements.materializedIDs.contains(block.id))
            .id(block.id)
            .onScrollVisibilityChange(threshold: 0.001) { isVisible in
                tracking.setVisible(block.id, isVisible)
            }
            .onDisappear { tracking.setVisible(block.id, false) }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("timelineContent")) }) { frame in
                measurements.record(block.id, frame: frame)
            }
            .transition(measurements.liveIDs.contains(block.id) && !measurements.materializedIDs.contains(block.id) ? Self.transition(for: block) : .identity)
            .onAppear { measurements.materializedIDs.insert(block.id) }
    }

    private func timelineScroll(blocks: [DisplayBlock], visible: [DisplayBlock], hidden: Int, topSpace: CGFloat, bottomSpace: CGFloat, rewindable: Set<UUID>) -> some View {
        // What the stack renders last: the newest question badge, or the newest block.
        // Its change is something arriving at the end of the conversation.
        let lastEntryID = runtime.questions.last.map { "question-" + $0.id } ?? visible.last?.id
        // The outline the rail resolves against, kept in step with what is laid out. Rows
        // coming and going is when the stack can lose its place; a look a beat from now
        // costs nothing and catches it whether or not any row says so.
        if tracking.setOutline(blocks.map { ($0.id, $0.hasUserMessage) }) {
            tracking.armBlankWatch()
            // A new block at the end under a reader held there: the stack is told where
            // the viewport is, since the block may have landed below rows it built for
            // the viewport before, with the older rows still on screen above the fold.
            if tracking.isPinnedToBottom, !tracking.isArriving { tracking.armViewportRefresh() }
        }
        // This evaluation's own state behind the rows' disclosure callbacks.
        revealBox.presentation = TimelinePresentationStore.entry(for: runtime.threadID)
        revealBox.disclosure = anchorDisclosure
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                // A forwarded thread keeps saying where it came from, once, at the head of
                // the conversation and outside the folds.
                if let continuation = runtime.continuation {
                    ContinuationSourceLabel(sourceTitle: continuation.sourceTitle)
                        .font(.chat(size: 12, weight: .medium))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.bottom, TimelineMetrics.rowSpacing)
                }
                if hidden > 0 {
                    // Older history loads itself as the reader nears the top, a page at a
                    // time, so scrolling back never stops at a button; the pill is still
                    // there to tap for anyone who gets to it first.
                    Button {
                        loadEarlier(in: blocks)
                    } label: {
                        Label("Show \(hidden) earlier messages", systemImage: "chevron.up")
                            .font(.chat(.callout))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.quaternary.opacity(0.5), in: Capsule(style: .continuous))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, TimelineMetrics.rowSpacing)
                    .onScrollVisibilityChange(threshold: 0.1) { isVisible in
                        if isVisible { loadEarlier(in: blocks) }
                    }
                }
                // Eager, not lazy: rows of varying height at the visible edge sent a lazy
                // stack pinned to the bottom into a placement loop that never returned to
                // the run loop (release hangs of 16 s to 20 min, all in the lazy item
                // phases). The window keeps the eager stack bounded instead.
                VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
                    if topSpace > 0 { Color.clear.frame(height: max(0, topSpace - TimelineMetrics.rowSpacing)) }
                    ForEach(visible) { block in
                        row(block, rewindable: rewindable)
                    }
                    if bottomSpace > 0 { Color.clear.frame(height: max(0, bottomSpace - TimelineMetrics.rowSpacing)) }
                    // The agent's questions end the conversation as badges until they are answered.
                    ForEach(runtime.questions) { request in
                        QuestionBadgeRow(request: request, runtime: runtime)
                            .id("question-" + request.instanceID.uuidString)
                            .transition(measurements.liveQuestions.contains(request.id) ? .softAppear : .identity)
                    }
                }
                .id(stackGeneration)
                .modifier(ScrollFreeze(tracking: tracking))
            }
            // Disclosure anchors use these frames to keep the reader's place as
            // a tool, group or turn changes height.
            .coordinateSpace(name: "timelineContent")
            .environment(\.revealTimelineEnd, revealBox)
            // The same column as the composer, so messages line up with its edges.
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(width: layoutWidth, alignment: .leading)
            .padding(.top, Chrome.contentTopInset)
            .padding(.bottom, 18)
            // A short conversation still fills the pane, with its messages resting at the bottom.
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
            // Inside the content, so viewport repair and disclosure anchoring can find
            // the native scroll view without changing its position to discover it.
            .background(alignment: .top) {
                ScrollViewProbe(
                    usesTimelineTopFade: usesTimelineTopFade,
                    onResolve: { tracking.probe = $0 },
                    onWheel: { tracking.noteWheelInput() }
                )
                    .frame(width: 0, height: 0)
            }
        }
        .id(runtime.threadID)
        .background {
            let thread = model.thread(runtime.threadID)
            ThreadResultReadProbe(
                model: model, threadID: runtime.threadID,
                revision: thread?.unreadRevision, hasUnread: thread?.hasUnread == true,
                canRead: !runtime.isLoadingHistory && !runtime.isRunning
                    && !runtime.isHydraMerging && !runtime.hasWorkingHelpers
                    && !runtime.hasNativeWork && runtime.backgroundTasks.isEmpty && !runtime.isWaitingForLimit
                    && (thread?.lastAttentionTurnID == nil
                        || runtime.turns.contains { $0.id == thread?.lastAttentionTurnID && $0.status != .running })
            )
        }

        // Torn down mid-scroll (a thread switch, a panel closed): the freeze lifts with it,
        // so the app never goes on hearing this timeline as scrolling.
        .onDisappear {
            capturePresentation(threadID: runtime.threadID)
            tracking.placementTask?.cancel()
            tracking.placementToken = nil
            tracking.endActivity()
        }
        // The thread opens at its end and stays there while its rows measure in.
        .onAppear { tracking.holdEnd(for: 1.5) }
        .coordinateSpace(name: "timelineViewport")
        .scrollIndicators(.never)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(anchorsBottomOnGrowth ? .bottom : .top, for: .sizeChanges)
        // One value per frame, and only when it moved: `onGeometryChange` fires solely
        // on change, and the settle below runs once when the resize ends. The height is
        // quantized like `layoutWidth`: the body reads it (the short-thread filler, the
        // jump tolerance), so an unquantized write re-evaluated the whole timeline on
        // every frame of a resize drag, and a step of `resizeStep` is invisible there.
        .onGeometryChange(for: CGFloat.self, of: Self.visibleHeight) { height in
            let stepped = (height / Self.resizeStep).rounded(.down) * Self.resizeStep
            if stepped != viewportHeight { viewportHeight = stepped }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
            paneWidth = $0
        }
        .onChange(of: [TypeScale.shared.ui, TypeScale.shared.content, TypeScale.shared.code, AppFont.revision]) {
            measurements.frames.removeAll()
            mountedWindow = nil
            tracking.armViewportRefresh()
        }
        .onChange(of: layoutWidth ?? min(800, paneWidth)) { _, width in
            measurements.invalidate(width: width)
            mountedWindow = nil
        }
        // No animation inside the timeline while the window is being dragged; a spring
        // restarted every frame is what made rows lag behind the window and land somewhere else.
        .transaction { transaction in if liveResize.isReshaping { transaction.animation = nil } }
        .onChange(of: liveResize.isReshaping) { _, active in
            guard !active else { return }
            settleAfterResize()
        }
        .onScrollPhaseChange { _, phase in
            // Inertia and animated navigation still move rows under the pointer. The
            // movement watch restores hit-testing 150ms after the last moving frame.
            tracking.notePhase(phase)
            if phase == .interacting || phase == .decelerating || phase == .animating {
                noteScrollMovement()
            }
            // What was put off for the scroll runs now that it is over: a repair the blank
            // watch asked for, a refresh the drift asked for.
            if phase == .idle {
                if tracking.repairSkippedWhileScrolling {
                    tracking.repairSkippedWhileScrolling = false
                    tracking.armBlankWatch()
                }
                if tracking.refreshSkippedWhileScrolling {
                    tracking.refreshSkippedWhileScrolling = false
                    tracking.armViewportRefresh()
                }
            }
        }
        .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init(geometry:)) { old, new in
            scrollChrome.update(travel: new.travel)
            tracking.noteGeometry(offset: new.offset, distanceFromBottom: new.distanceFromBottom, travel: new.travel)
            // After every branch below has had its say on the pin.
            defer { updateJumpButton() }
            let wheelInput = tracking.hasRecentWheelInput
            if !wheelInput && !tracking.isUserScrolling &&
                (new.contentHeight != old.contentHeight || new.containerHeight != old.containerHeight ||
                 (tracking.placementToken != nil && new.offset != old.offset)) {
                mathPreparation?.noteGeometryChange()
            }
            // Only scroll input or an active scroll phase freezes the rows; layout
            // following new text under a resting reader does not.
            if new.offset != old.offset,
               tracking.isUserScrolling || tracking.isCoasting || wheelInput {
                noteScrollMovement()
            }
            // An anchor's offset can lag behind a content-size change during layout or an
            // animation. That mismatch alone is not the reader scrolling: it used to
            // unpin a growing reply before the bottom anchor caught up. Require an actual
            // scroll phase or wheel input in this scroll view. Wheel ticks still count
            // when text grows in the same frame, and never borrow another pane's input.
            let anchorMove = anchorsBottomOnGrowth ? new.contentHeight - old.contentHeight : 0
            let readerMoved = abs((new.offset - old.offset) - anchorMove) > 1
            if readerMoved, tracking.isUserScrolling || tracking.isCoasting || wheelInput {
                tracking.noteReaderMovement()
            }
            let scrolled = tracking.isUserScrolling
                || (wheelInput && readerMoved
                    && new.containerHeight == old.containerHeight && !tracking.isCoasting)
            guard tracking.placementToken == nil else { return }
            updateMountedWindow(in: blocks, offset: new.offset, height: new.containerHeight)
            let atRest = tracking.allowsLayoutCorrection
            if atRest, !scrolled {
                // The content changed shape under a resting reader and an anchor moved the
                // offset to follow: a turn folded, rows arrived or left, history landed
                // above. Growth the bottom anchor follows keeps the viewport over the row
                // that grew. Other changes can carry it over stale offscreen spacers;
                // accumulated drift asks for layout to be checked in place.
                let shrink = max(0, old.contentHeight - new.contentHeight)
                let drift = anchorsBottomOnGrowth
                    ? abs((new.offset - old.offset) - (new.contentHeight - old.contentHeight))
                    : abs(new.offset - old.offset)
                if tracking.noteDrift(shrink + drift, tolerance: Self.jumpTolerance(viewportHeight)) {
                    tracking.armViewportRefresh()
                }
                if shrink > 1 {
                    // Whatever the rows report, the layout gets checked a beat from now.
                    tracking.armBlankWatch()
                }
            } else if scrolled {
                // The reader's own scrolling tells the stack where the viewport is.
                tracking.resetDrift()
            }
            if new.distanceFromBottom < -1, atRest, new.contentHeight != old.contentHeight || new.containerHeight != old.containerHeight {
                // Only when the content or the container changed shape in this very frame: a
                // wheel bounce past the end moves only the offset and plays out on its own.
                // Past the end of the conversation, showing nothing: the content shrank under
                // the offset. A finished turn folds its whole transcript into one block, and
                // with the reader's place anchored at the top that left the viewport hanging
                // in empty space until they came back to the thread. Never a valid place to
                // be, whether or not the reader was following, so it snaps to the end.
                // Deferred, like every scroll out of this handler: a scrollPosition write
                // here is applied mid-update, and the applied scroll re-enters the handler
                // in the same display pass — an uncapped loop that keeps dirtying the
                // window until AppKit's display-cycle watchdog kills the app.
                scheduleBottomSnap()
            } else if historyLoadPending, new.contentHeight > old.contentHeight {
                // The history landed above the viewport with the bottom held; growth
                // anchors by the reader's position again from here.
                historyLoadPending = false
                let pinned = tracking.isPinnedToBottom || new.distanceFromBottom < 48
                if pinned != anchorsBottomOnGrowth { anchorsBottomOnGrowth = pinned }
                // A thread whose first rows fit the pane had nothing to scroll, and the
                // bottom anchor has no offset to hold when the history makes it tall:
                // the viewport stayed at the top of the newly tall content, on the oldest
                // rows. A reader at the end is put back on the end.
                if tracking.isPinnedToBottom, new.distanceFromBottom > 1 {
                    scheduleBottomSnap()
                }
            } else if scrolled {
                // Only the reader's own scrolling decides whether the timeline follows new text.
                // Guarded, so measuring the scroll position never touches anything a body reads.
                let pinned = new.distanceFromBottom < 48
                if pinned != tracking.isPinnedToBottom { tracking.isPinnedToBottom = pinned }
                if pinned != anchorsBottomOnGrowth { anchorsBottomOnGrowth = pinned }
            } else if (tracking.isPinnedToBottom || old.distanceFromBottom < 48), atRest, abs(new.distanceFromBottom) > 1,
                      new.contentHeight != old.contentHeight || new.containerHeight != old.containerHeight {
                // Pinned, at rest, and not at the end: the content grew or reflowed to a new
                // width, the chat box took height, or the scroll view lost its place (rows
                // measured after it anchored, a thread opened mid-animation) and is showing
                // empty space past the conversation. The end is where the reader is; the
                // timeline snaps back to it, never slides, so a new row lands in place and
                // fades in on its own. (Mid-resize this waits for the settle below: the
                // anchor already holds the bottom edge each frame.) A reader at the end whose pin
                // flag went stale is caught by the end they held last frame.
                guard !liveResize.isActive else { return }
                tracking.isPinnedToBottom = true
                anchorsBottomOnGrowth = true
                scheduleBottomSnap()
            }
        }
        .task(id: ObjectIdentifier(scrollState)) {
            if let lastReply = runtime.entries.reversed().first(where: {
                if case .assistant(let message) = $0.item.content { return !message.isStreaming }
                return false
            }), case .assistant(let message) = lastReply.item.content {
                MathRendering.prewarm(message.text, pointSize: TypeScale.shared.content(13))
            }
            // Restart after ChatView replaces its scroll state on a thread switch.
            // Yield past that reset before restoring this timeline.
            await Task.yield()
            guard !Task.isCancelled else { return }
            if restorePresentation(in: blocks) {
                await warmMarkdown()
                mathPreparation?.historyWindowDidPrepare()
                return
            }
            // The first frame shows only the newest few blocks, so a thread opens at once;
            // the rest of the initial window lands a beat later, above the viewport, while
            // the reader is already looking at the end.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // The window lands above the viewport over the next frames: still arriving.
            tracking.holdEnd(for: 1.0)
            loadEarlier(in: blocks, to: TimelineWindow.initial)
            // A thread that opened on nothing (its first rows never laid out where the
            // bottom anchor put the viewport) is caught a beat from now.
            tracking.armBlankWatch()
            await warmMarkdown()
            mathPreparation?.historyWindowDidPrepare()
            // The window opened whole, so every block could measure. Once the thread has
            // settled the stack narrows to the blocks around the viewport, rather than on
            // the reader's first scrolled frame.
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, !tracking.isUserScrolling else { return }
            updateMountedWindow(in: blocks, offset: tracking.offset, height: viewportHeight)
        }
        .onChange(of: tracking.checkRequest) {
            // A coast whose end phase was never delivered is cleared by the phase watch,
            // which asks for this check: the app hears that scroll end here (a no-op when
            // nothing changed).
            tracking.reportActivity(timeline: runtime.threadID)
            repairLayout()
        }
        .onChange(of: FrontMonitor.shared.revision) {
            // The reader is back: the app came to the front or this timeline's window was
            // uncovered. Whatever the conversation did unseen, the timeline checks itself
            // now. Another window coming on screen, a popover or a tooltip opening over the
            // chat included, is not the reader coming back to this one.
            guard FrontMonitor.shared.concerns(tracking.probe?.window) else { return }
            tracking.noteReturnToFront()
        }
        .onChange(of: runtime.isRunning) { _, running in
            // Sending a message always brings the reader back to the conversation's end.
            guard running else {
                // The turn's end folds its steps into its answer, in the block the turn has
                // had all along. A reader at the end is put back on the end once that has
                // laid out, and the stack is told where the viewport is either way.
                if tracking.isPinnedToBottom {
                    scheduleBottomSnap()
                }
                tracking.armViewportRefresh()
                tracking.armBlankWatch()
                Task { await warmMarkdown() }
                return
            }
            // Whatever phase the last scroll was left in (a coast whose end never came)
            // is over: the turn's own scroll below must not be read as its continuation.
            tracking.notePhase(.idle)
            let wasAtEnd = tracking.isPinnedToBottom
            // A turn nothing was sent for is not the reader's send: for a reader who scrolled
            // up it is a row arriving like any other, and the jump button tells them about it,
            // the way the `lastEntryID` branch below treats a new row. A send, and any turn
            // for a reader already at the end, still brings them down.
            let unattended = seenAutoStartedTurnToken.map { $0 != runtime.autoStartedTurnToken } ?? false
            seenAutoStartedTurnToken = runtime.autoStartedTurnToken
            if wasAtEnd || !unattended {
                let far = tracking.distanceFromBottom > Self.farJump(viewportHeight)
                mountTail(in: blocks)
                tracking.isPinnedToBottom = true
                anchorsBottomOnGrowth = true
                if wasAtEnd || far {
                    // Already there: the message and the working line appear in place.
                    // From far up it lands at once too (see `farJump`).
                    withTransaction(Self.unanimated) { position.scrollTo(edge: .bottom) }
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
                }
            }
            tracking.armViewportRefresh()
        }
        .onChange(of: tracking.refreshRequest) {
            refreshViewport()
        }
        .onChange(of: runtime.questions.count) { old, new in
            // The badge leaving shrinks the content under a held offset without
            // touching the blocks, so nothing arms the viewport refresh the rows
            // below need: tell the stack where the viewport is now, while the rows
            // above still cover it and no blank watch would fire.
            guard old != 0, new == 0 else { return }
            tracking.armViewportRefresh()
        }
        .onChange(of: scrollState.jumpRequest) {
            tracking.noteUserNavigation()
            tracking.isPinnedToBottom = true
            anchorsBottomOnGrowth = true
            // From far up the end lands at once: the glide would cross blocks the stack
            // holds only as spacers.
            let far = tracking.distanceFromBottom > Self.farJump(viewportHeight)
            mountTail(in: blocks)
            let generation = tracking.navigationGeneration
            DispatchQueue.main.async {
                guard generation == tracking.navigationGeneration else { return }
                if far {
                    withTransaction(Self.unanimated) { position.scrollTo(edge: .bottom) }
                    return
                }
                tracking.animatedNavigation = true
                withAnimation(.smooth(duration: 0.35)) { position.scrollTo(edge: .bottom) }
            }
        }
        .onChange(of: scrollState.areaGrowthRequest) {
            // The composer area took height from the viewport's bottom edge: a reader at the
            // end keeps the end, snapped unanimated as the area grows, and a reader who
            // scrolled up to read is left exactly where they are. Mid-resize this waits for
            // the settle, like the geometry branch above.
            guard !liveResize.isActive, tracking.placementToken == nil else { return }
            guard tracking.isPinnedToBottom || tracking.distanceFromBottom < 48 else { return }
            tracking.isPinnedToBottom = true
            anchorsBottomOnGrowth = true
            guard abs(tracking.distanceFromBottom) > 1 else { return }
            withTransaction(Self.unanimated) { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: lastEntryID) {
            // A message, tool row or turn landing at the end of the conversation brings
            // a reader who was at the end down to it, whatever the stack made of the
            // growth; a reader who scrolled up to read is left there, the jump button
            // says something arrived. A question badge is the one row that fetches
            // anyone: it waits on the reader. History loading itself above the viewport
            // must not yank the reader down, and an active drag is never fought: the
            // next entry, or the geometry branch, catches up once it lets go. Growth
            // inside an existing row stays with the pinned machinery above; this is for
            // new rows only. A reader whose pin flag went stale while they sat at the end
            // is followed by the distance they hold as well.
            guard tracking.placementToken == nil, !historyLoadPending, !tracking.isUserScrolling else { return }
            let isQuestion = lastEntryID?.hasPrefix("question-") == true
            guard tracking.isPinnedToBottom || tracking.distanceFromBottom < 48 || isQuestion else { return }
            // A reader following a long run lets the oldest rows go, above the viewport, so
            // the eager stack stays bounded; they come back as history on the way up.
            if visible.count > TimelineWindow.eagerLimit {
                windowStartID = blocks[blocks.count - TimelineWindow.initial].id
            }
            mountTail(in: blocks)
            tracking.isPinnedToBottom = true
            anchorsBottomOnGrowth = true
            if scrollState.showsJumpButton { scrollState.showsJumpButton = false }
            withTransaction(Self.unanimated) { position.scrollTo(edge: .bottom) }
        }
        .onChange(of: runtime.threadID) { oldID, _ in
            capturePresentation(threadID: oldID)
            tracking.placementTask?.cancel()
            tracking.placementToken = nil
            // A new thread starts with a fresh window on its newest messages, and no
            // block from the old one is on screen any more.
            windowStartID = nil
            mountedWindow = nil
            measurements = TimelineMeasurements()
            anchorsBottomOnGrowth = true
            historyLoadPending = false
            tracking.clearVisible()
        }
    }

    private func capturePresentation(threadID: UUID) {
        let entry = TimelinePresentationStore.entry(for: threadID)
        let ids = measurements.blockIDs
        entry.pinned = tracking.isPinnedToBottom
        entry.windowStartID = windowStartID
        let start = windowStartID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let mounted = mountedWindow?.range(ids: ids, start: start).map { Array(ids[$0]) } ?? ids
        entry.mountedIDs = mounted
        entry.frames = measurements.frames
        entry.width = measurements.width
        entry.fontFingerprint = [TypeScale.shared.ui, TypeScale.shared.content, TypeScale.shared.code, AppFont.revision]
        // Only a block the stack holds has a frame where it is now: a spacer's blocks keep
        // the frames they last laid out at.
        if let id = mounted.first(where: { measurements.viewportFrame($0, offset: tracking.offset).map { $0.maxY > 0 && $0.minY < viewportHeight } ?? false }),
           let frame = measurements.viewportFrame(id, offset: tracking.offset) {
            entry.anchorID = id
            entry.anchorOffset = frame.minY
        }
    }

    private func restorePresentation(in blocks: [DisplayBlock]) -> Bool {
        let entry = TimelinePresentationStore.entry(for: runtime.threadID)
        guard !entry.pinned, let id = entry.anchorID,
              let index = blocks.firstIndex(where: { $0.id == id }) else { return false }
        if measurements.width == entry.width, entry.fontFingerprint == [TypeScale.shared.ui, TypeScale.shared.content, TypeScale.shared.code, AppFont.revision] { measurements.frames = entry.frames }
        let savedIDs = Set(entry.mountedIDs)
        let indices = blocks.indices.filter { savedIDs.contains(blocks[$0].id) }
        let lower = min(index, indices.first ?? index)
        let upper = max(index, indices.last ?? index) + 1
        let savedStart = entry.windowStartID.flatMap { saved in blocks.firstIndex { $0.id == saved } } ?? index
        let start = min(savedStart, lower)
        windowStartID = blocks[start].id
        // Unknown heights must lay out before they can stand in for offscreen rows.
        let unknownBefore = (start..<lower).first { measurements.frames[blocks[$0].id] == nil }
        let unknownAfter = (upper..<blocks.count).last { measurements.frames[blocks[$0].id] == nil }
        mountedWindow = MountedWindow((unknownBefore ?? lower)..<(unknownAfter.map { $0 + 1 } ?? upper), in: blocks)
        keepAnchor(id, offset: entry.anchorOffset, scrollFirst: true)
        return true
    }

    private func anchorDisclosure(_ id: String) {
        guard let frame = measurements.viewportFrame(id, offset: tracking.offset) else { return }
        keepAnchor(id, offset: frame.minY, scrollFirst: false)
    }

    private func keepAnchor(_ id: String, offset: CGFloat, scrollFirst: Bool) {
        tracking.placementTask?.cancel()
        let token = UUID()
        let generation = tracking.navigationGeneration
        tracking.placementToken = token
        tracking.isPinnedToBottom = false
        anchorsBottomOnGrowth = false
        historyLoadPending = false
        tracking.placementTask = Task { @MainActor in
            defer {
                if tracking.placementToken == token { tracking.placementToken = nil }
            }
            await Task.yield()
            guard !Task.isCancelled, generation == tracking.navigationGeneration else { return }
            if scrollFirst {
                withTransaction(Self.unanimated) { position.scrollTo(id: id, anchor: .top) }
            }
            // Keep the header fixed through the disclosure animation and deferred layout.
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled, generation == tracking.navigationGeneration else { return }
                guard let frame = measurements.viewportFrame(id, offset: tracking.offset),
                      let scroll = tracking.probe?.enclosingScrollView else { continue }
                let delta = frame.minY - offset
                if abs(delta) > 0.5 {
                    let clip = scroll.contentView
                    let target = NSRect(origin: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta), size: clip.bounds.size)
                    clip.scroll(to: clip.constrainBoundsRect(target).origin)
                    scroll.reflectScrolledClipView(clip)
                }
            }
            updateJumpButton()
        }
    }

    /// The jump button is for a reader who left the end: unpinned and a real distance up.
    /// It used to follow a one-point marker at the end of the content coming on and off
    /// screen, and a pinned reader's end leaves the screen for a frame whenever a streaming
    /// row grows ahead of the snap that follows it; the marker's "back on screen" landing
    /// before its deferred "gone" write was dropped, and the button stayed up over a
    /// timeline sitting at its end. It is worked out from the pin and the distance instead,
    /// read again when the write lands, and only written when it changes.
    private func updateJumpButton() {
        let tracking = tracking
        let resolve: @MainActor () -> Bool = { !tracking.isPinnedToBottom && tracking.distanceFromBottom >= 48 }
        guard resolve() != scrollState.showsJumpButton else { return }
        scrollState.settleJumpButton(resolve)
    }

    /// Keeps the stack to the blocks around the viewport, the way a virtualized list does:
    /// blocks within `mountMargin` of what is on screen are built, blocks past `keepMargin`
    /// go back to being part of a spacer of their measured height, and everything between
    /// stays as it is, so a reader moving back and forth over a stretch rebuilds nothing.
    /// The stack holds a screenful or two of blocks however long the chat, so a scrolled
    /// frame walks, hit-tests and composites those and not the whole window (an eager stack
    /// of every loaded turn was most of the cost of a scrolled frame on a long chat).
    ///
    /// Runs on every scrolled frame, so it writes view state only when the range moves: a
    /// block crossing a margin, not a pixel of scroll. Positions come from the measured
    /// heights, anchored on the first block the stack holds, whose frame is live: a block
    /// behind a spacer keeps the frame it last laid out at, and loading history above
    /// makes that stale. A block that has never been measured has no height to stand in
    /// for, so it is built once it comes near, and nothing past it is placed until it has.
    private func updateMountedWindow(in blocks: [DisplayBlock], offset: CGFloat, height: CGFloat) {
        guard height > 0, !blocks.isEmpty else { return }
        let start = windowStartIndex(in: blocks)
        guard start < blocks.count else { return }
        let current = mountedWindow?.range(in: blocks, start: start) ?? start..<blocks.count
        guard current.lowerBound < blocks.count,
              let anchorFrame = measurements.frames[blocks[current.lowerBound].id] else { return }
        let spacing = TimelineMetrics.rowSpacing
        var y = anchorFrame.minY
        for index in start..<current.lowerBound {
            guard let rowHeight = measurements.frames[blocks[index].id]?.height else { return }
            y -= rowHeight + spacing
        }
        let top = offset - Chrome.contentTopInset
        let bottom = top + height
        let mountMargin = Self.mountMargin(height)
        let keepMargin = mountMargin * 2.5
        var want: (lower: Int?, upper: Int) = (nil, start)
        var keep: (lower: Int?, upper: Int) = (nil, start)
        for index in start..<blocks.count {
            guard let rowHeight = measurements.frames[blocks[index].id]?.height else {
                // Unmeasured: built once its top comes near; nothing below it can be placed.
                if y <= bottom + mountMargin {
                    if want.lower == nil { want.lower = index }
                    if keep.lower == nil { keep.lower = index }
                    want.upper = index
                    keep.upper = index
                }
                break
            }
            let end = y + rowHeight
            if want.lower == nil, end >= top - mountMargin { want.lower = index }
            if keep.lower == nil, end >= top - keepMargin { keep.lower = index }
            if y <= bottom + mountMargin { want.upper = index }
            if y <= bottom + keepMargin { keep.upper = index } else { break }
            y = end + spacing
        }
        // The viewport is past every block (a short thread, a bounce): nothing to place by.
        guard let wantLower = want.lower else { return }
        var lower = min(wantLower, max(current.lowerBound, keep.lower ?? wantLower))
        var upper = max(want.upper + 1, min(current.upperBound, keep.upper + 1))
        // A reader at the end follows it: whatever lands there is built as it arrives.
        if tracking.isPinnedToBottom { upper = blocks.count }
        // Nothing leaves while the layout is still settling (a thread opening, history
        // landing above, a placement holding a row in place): only exact spacers keep the
        // content where it is, and those need heights that have stopped moving.
        if historyLoadPending || tracking.isArriving || tracking.placementToken != nil {
            lower = min(lower, current.lowerBound)
            upper = max(upper, current.upperBound)
        }
        let proposed = lower..<min(blocks.count, max(lower + 1, upper))
        guard proposed != current else { return }
        let window: MountedWindow? = proposed.lowerBound <= start && proposed.upperBound >= blocks.count
            ? nil : MountedWindow(proposed, in: blocks)
        guard window != mountedWindow else { return }
        withTransaction(Self.unanimated) { mountedWindow = window }
    }

    /// How far beyond the viewport blocks are built ahead of the reader, so a block is
    /// laid out a good way before it scrolls into view rather than on the frame it does.
    private static func mountMargin(_ viewportHeight: CGFloat) -> CGFloat {
        max(600, viewportHeight)
    }

    /// The content just moved under the pointer. Freezes hover and hit-testing on the
    /// rows if they are not already, and (re)arms the watch that lifts the freeze once
    /// no frame has moved for 150ms. The flag, the timestamp and the watch all live on
    /// the tracking object, so noting a frame's movement writes no view state.
    private func noteScrollMovement() {
        tracking.lastMovementAt = CACurrentMediaTime()
        guard !tracking.isReaderScrolling else { return }
        tracking.isReaderScrolling = true
        tracking.reportActivity(timeline: runtime.threadID)
        tracking.settleWatch?.cancel()
        let tracking = tracking
        let timeline = runtime.threadID
        tracking.settleWatch = Task { @MainActor in
            while !Task.isCancelled {
                let remaining = 0.15 - (CACurrentMediaTime() - tracking.lastMovementAt)
                if remaining > 0 {
                    try? await Task.sleep(for: .seconds(remaining))
                    continue
                }
                if tracking.isReaderScrolling { tracking.isReaderScrolling = false }
                tracking.settleWatch = nil
                tracking.reportActivity(timeline: timeline)
                if tracking.repairSkippedWhileScrolling {
                    tracking.repairSkippedWhileScrolling = false
                    tracking.armBlankWatch()
                }
                if tracking.refreshSkippedWhileScrolling {
                    tracking.refreshSkippedWhileScrolling = false
                    tracking.armViewportRefresh()
                }
                return
            }
        }
    }

    /// Puts the viewport back on the conversation when a layout pass has left it showing
    /// nothing. A mounted window can hold stale spacer heights after a turn folds or rows
    /// reflow. This runs on request only: when no row has been on screen for a beat, when a
    /// scroll phase that never settled is cleared, and when the app returns to the front.
    ///
    /// Past the end, or pinned to the end and away from it, the timeline snaps to the end,
    /// as it does on any measured frame. On the conversation but showing nothing, the
    /// mounted window is expanded. Still nothing a beat later, the stack is rebuilt;
    /// still nothing, the timeline goes to the end and stays pinned there. Rows coming
    /// back on screen end the sequence wherever it is, and
    /// a fourth blank in a row is left alone.
    private func repairLayout() {
        guard tracking.placementToken == nil else { return }
        guard viewportHeight > 0 else { return }
        guard tracking.allowsLayoutCorrection else {
            tracking.repairSkippedWhileScrolling = true
            return
        }
        let distance = tracking.distanceFromBottom
        if distance < -1 || (tracking.isPinnedToBottom && abs(distance) > 1) {
            withTransaction(Self.unanimated) { position.scrollTo(edge: .bottom) }
            // Rows on screen: the snap was all there was to do.
            guard tracking.showsNothing, tracking.blankRepairs < 3 else { return }
            tracking.armViewportRefresh()
        } else if tracking.showsNothing {
            switch tracking.blankRepairs {
            case 0:
                // A spacer whose heights went stale can be all the viewport is over: the
                // whole window is built again, and narrows on the next scrolled frame.
                if mountedWindow != nil { mountedWindow = nil }
                refreshViewport()
            case 1:
                stackGeneration += 1
                tracking.armViewportRefresh()
            case 2:
                tracking.isPinnedToBottom = true
                anchorsBottomOnGrowth = true
                withTransaction(Self.unanimated) { position.scrollTo(edge: .bottom) }
                tracking.armViewportRefresh()
            default:
                return
            }
        } else {
            return
        }
        // Blank, and something was just done about it: checked again a beat from now.
        tracking.blankRepairs += 1
        tracking.armBlankWatch()
    }

    /// Drift smaller than this leaves the viewport over rows the mounted window already built:
    /// the working line coming or going, a group collapsing. More can carry it off them.
    private static func jumpTolerance(_ viewportHeight: CGFloat) -> CGFloat {
        max(48, viewportHeight / 4)
    }

    /// One settle when the window stops resizing: bottom-anchored if the reader was at the
    /// end, otherwise the top anchor already held the top-most row each frame. Unanimated,
    /// so no glide restarts per frame mid-drag; the stack is told where the viewport is.
    private func settleAfterResize() {
        guard tracking.allowsLayoutCorrection else {
            tracking.armViewportRefresh()
            return
        }
        if tracking.isPinnedToBottom {
            withTransaction(Self.unanimated) { position.scrollTo(edge: .bottom) }
        } else {
            tracking.armViewportRefresh()
        }
        tracking.armBlankWatch()
    }

    /// Refreshes layout in place. The bounded eager stack already builds every mounted
    /// row, so it needs no synthetic scroll to report the viewport. The old lazy-stack
    /// workaround moved the clip view a point and restored it on a later frame, visibly
    /// making otherwise settled text hop whenever a turn or window refreshed.
    private func refreshViewport() {
        guard tracking.placementToken == nil else { return }
        guard viewportHeight > 0 else { return }
        guard tracking.allowsLayoutCorrection else {
            tracking.refreshSkippedWhileScrolling = true
            return
        }
        tracking.probe?.enclosingScrollView?.documentView?.needsLayout = true
        if tracking.showsNothing, mountedWindow != nil {
            // Stale offscreen spacer heights must be measured again before the window
            // narrows. A visible conversation keeps its current rows and exact offset.
            withTransaction(Self.unanimated) { mountedWindow = nil }
        }
        if tracking.isPinnedToBottom, abs(tracking.distanceFromBottom) > 1 {
            scheduleBottomSnap()
        }
        tracking.armBlankWatch()
    }

    private nonisolated static func visibleHeight(_ proxy: GeometryProxy) -> CGFloat {
        max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom)
    }
}

/// Scroll-driven facts about the timeline, kept out of view state so reporting them never
/// re-renders the conversation. Every write is guarded against no-ops: an observable write
/// notifies its readers whether or not the value moved. It also keeps watch over the
/// layout: which rows are on screen, whether a scroll phase has really ended, and when the
/// timeline should check that it is showing anything at all.
@MainActor
@Observable
final class TimelineScrollTracking: ScrollActivityReporter {
    /// Whether new text keeps the timeline at the conversation's end. No view body reads
    /// it, only the scroll closures, so a pin flip must never be able to re-render the
    /// timeline.
    @ObservationIgnored var isPinnedToBottom = true
    @ObservationIgnored var navigationGeneration = 0
    @ObservationIgnored var placementToken: UUID?
    @ObservationIgnored var placementTask: Task<Void, Never>?
    @ObservationIgnored var animatedNavigation = false
    @ObservationIgnored private var lastWheelInputAt: CFTimeInterval = -.infinity

    /// Wheel scrolling can arrive without a SwiftUI scroll phase. Keep its input long
    /// enough for the deferred geometry callback, rather than guessing from layout.
    var hasRecentWheelInput: Bool { CACurrentMediaTime() - lastWheelInputAt < 0.15 }

    /// Input wins even before SwiftUI reports a moving scroll phase. A wheel's
    /// first tick or a finger-down bounce must not be undone by deferred repair.
    var allowsLayoutCorrection: Bool {
        !isUserScrolling && !isCoasting && !isReaderScrolling && !hasRecentWheelInput
    }

    func noteWheelInput() {
        lastWheelInputAt = CACurrentMediaTime()
        noteUserNavigation()
    }

    func noteUserNavigation() {
        navigationGeneration += 1
        placementTask?.cancel()
        placementToken = nil
        if animatedNavigation, let scrollView {
            animatedNavigation = false
            let clip = scrollView.contentView
            clip.layer?.removeAllAnimations()
            clip.scroll(to: clip.bounds.origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }
    /// True while the reader drags or flicks the timeline. Rows neither hover nor hit-test
    /// then: with the pointer resting over content that slides under it, SwiftUI otherwise
    /// re-hit-tests every row's hover region each frame and the rows flip their hover state
    /// (and animate it) as they pass — a fifth of the main thread's scroll-time work.
    /// Observed on purpose: only the leaf modifier that applies the freeze (`ScrollFreeze`)
    /// reads it, so its flips re-render that node and never the timeline's body.
    var isReaderScrolling = false
    /// Watches for the scroll to settle once movement has been seen, so the freeze lifts
    /// 150ms after the last frame that moved, for wheel and trackpad alike.
    @ObservationIgnored var settleWatch: Task<Void, Never>?
    /// True while the reader drags or flicks the timeline, as opposed to it following new text.
    @ObservationIgnored var isUserScrolling = false
    /// When the content last moved, for lifting the scroll freeze.
    @ObservationIgnored var lastMovementAt: CFTimeInterval = 0
    /// True while a flick coasts or a programmatic scroll animates.
    @ObservationIgnored var isCoasting = false
    /// The message the reader is on, for the rail: the sent message at or above the block
    /// in the middle of what is on screen. Written only when it changes, so the rail
    /// re-renders when the lit tick moves and never else.
    private(set) var activeBlockID: String?
    /// The blocks as laid out, in order, and which of them are sent messages.
    @ObservationIgnored private var outlineIDs: [String] = []
    @ObservationIgnored private var outlineSet: Set<String> = []
    @ObservationIgnored private var userBlockIDs: Set<String> = []
    /// The blocks currently intersecting the viewport, from their own visibility callbacks.
    @ObservationIgnored private var visibleIDs: Set<String> = []
    /// The offset, the distance from the end and the travel from the top as last measured,
    /// for a repair to read without waiting for another frame, and when the offset last moved.
    @ObservationIgnored private(set) var offset: CGFloat = 0
    @ObservationIgnored private(set) var distanceFromBottom: CGFloat = 0
    @ObservationIgnored private(set) var travel: CGFloat = 0
    @ObservationIgnored private var lastOffsetChangeAt: CFTimeInterval = 0
    /// When the offset last moved by more than the anchor's own move (see the timeline's
    /// `readerMoved`): the reader's drag, flick or coast, never content growing under a
    /// held end. What the phase watch below waits to stop.
    @ObservationIgnored private var lastReaderMovementAt: CFTimeInterval = 0
    /// When the phase being watched began, for the ceiling on it.
    @ObservationIgnored private var phaseStartedAt: CFTimeInterval = 0
    @ObservationIgnored private var phaseWatch: Task<Void, Never>?
    /// A repair or a viewport refresh that was skipped mid-scroll, to run once it ends.
    @ObservationIgnored var repairSkippedWhileScrolling = false
    @ObservationIgnored var refreshSkippedWhileScrolling = false
    @ObservationIgnored private var blankWatch: Task<Void, Never>?
    /// How many repairs the current blank has had, so they escalate and then stop. Any
    /// row coming on screen starts the count over.
    @ObservationIgnored var blankRepairs = 0
    /// A bottom snap is queued for the next run-loop turn (`ThreadTimeline.scheduleBottomSnap`).
    @ObservationIgnored var bottomSnapPending = false
    /// Bumped when the timeline should look at its own layout (`ThreadTimeline.repairLayout`).
    private(set) var checkRequest = 0
    /// Bumped when the timeline should refresh its mounted rows' native layout
    /// (`ThreadTimeline.refreshViewport`).
    private(set) var refreshRequest = 0
    /// A view inside the scroll view's content. The current scroll view is found through
    /// it when layout or disclosure anchoring needs it, including after a thread switch.
    @ObservationIgnored weak var probe: NSView?
    @ObservationIgnored private var refreshPending = false
    /// Refreshes come in bursts (one change sets off a few as rows measure); a burst that
    /// never settles is cut off, so a stack that will not build is left alone.
    @ObservationIgnored private var refreshesInBurst = 0
    @ObservationIgnored private var burstStartedAt: CFTimeInterval = 0
    /// How far the offset and the content have moved under the viewport since the stack
    /// last built for where it is.
    @ObservationIgnored private var drift: CGFloat = 0

    /// Rows to show, and none of them on screen.
    var showsNothing: Bool {
        !outlineIDs.isEmpty && visibleIDs.isDisjoint(with: outlineSet)
    }

    /// Returns whether the outline changed.
    @discardableResult
    func setOutline(_ blocks: [(id: String, hasUserMessage: Bool)]) -> Bool {
        let ids = blocks.map(\.id)
        guard ids != outlineIDs else { return false }
        outlineIDs = ids
        outlineSet = Set(ids)
        userBlockIDs = Set(blocks.filter(\.hasUserMessage).map(\.id))
        resolveActive()
        return true
    }

    func setVisible(_ id: String, _ isVisible: Bool) {
        if isVisible {
            guard visibleIDs.insert(id).inserted else { return }
            // Something is on screen: no blank to repair, and the next one starts fresh.
            blankWatch?.cancel()
            blankWatch = nil
            blankRepairs = 0
        } else {
            guard visibleIDs.remove(id) != nil else { return }
            // The last row left the screen. A replacement normally lands within the
            // frame; the watch catches the case where nothing does.
            if showsNothing { armBlankWatch() }
        }
        scheduleResolveActive()
    }

    /// The active block is resolved a beat later and at most ten times a second. Written
    /// from inside a row's visibility callback, every change forced a whole-window layout
    /// in the middle of the scroll frame, and rows cross the edge many times a second.
    @ObservationIgnored private var resolveActiveScheduled = false
    private func scheduleResolveActive() {
        guard !resolveActiveScheduled else { return }
        resolveActiveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.resolveActiveScheduled = false
            self.resolveActive()
        }
    }

    func clearVisible() {
        visibleIDs.removeAll()
        if activeBlockID != nil { activeBlockID = nil }
    }

    /// Until when the timeline is still arriving: a thread just opened, or history just
    /// landed above the viewport. The offset moves on its own in those frames (the initial
    /// anchor, rows measuring in, the window growing), and none of it is the reader
    /// scrolling: the end stays pinned until the layout has settled or a real scroll
    /// phase says otherwise.
    @ObservationIgnored private var arrivingUntil: CFTimeInterval = 0

    var isArriving: Bool { CACurrentMediaTime() < arrivingUntil }

    func holdEnd(for seconds: TimeInterval) {
        arrivingUntil = max(arrivingUntil, CACurrentMediaTime() + seconds)
    }

    /// The reader moved the offset this frame (see the timeline's `readerMoved`).
    func noteReaderMovement() {
        lastReaderMovementAt = CACurrentMediaTime()
    }

    func noteGeometry(offset: CGFloat, distanceFromBottom: CGFloat, travel: CGFloat) {
        if offset != self.offset {
            lastOffsetChangeAt = CACurrentMediaTime()
            self.offset = offset
        }
        if distanceFromBottom != self.distanceFromBottom { self.distanceFromBottom = distanceFromBottom }
        if travel != self.travel { self.travel = travel }
    }

    /// The timeline this object last reported under, so the report can be withdrawn when
    /// the timeline goes: by then the column's `runtime.threadID` may already name the
    /// next thread.
    @ObservationIgnored private var reportedTimeline: UUID?

    /// Tells the app whether this timeline is moving under its reader: the drag or the
    /// wheel (`isReaderScrolling`) and the coast after a flick (`isCoasting`). Motion
    /// elsewhere pauses on it (see `ScrollActivity`).
    func reportActivity(timeline: UUID) {
        if let reported = reportedTimeline, reported != timeline {
            ScrollActivity.shared.setScrolling(false, timeline: reported)
        }
        reportedTimeline = timeline
        ScrollActivity.shared.setScrolling(isScrollingNow, timeline: timeline, reporter: self)
    }

    /// What this timeline reports (see `ScrollActivity`): the drag or wheel, and the coast.
    var isScrollingNow: Bool { isReaderScrolling || isCoasting }

    /// The timeline is gone (a thread switch, a panel closed): whatever it reported is
    /// withdrawn, mid-drag or mid-coast alike, so the app never goes on hearing it scroll.
    func endActivity() {
        lastWheelInputAt = -.infinity
        settleWatch?.cancel()
        settleWatch = nil
        phaseWatch?.cancel()
        phaseWatch = nil
        if isReaderScrolling { isReaderScrolling = false }
        isCoasting = false
        isUserScrolling = false
        if let reported = reportedTimeline {
            ScrollActivity.shared.setScrolling(false, timeline: reported)
        }
    }

    /// A phase's end is not always delivered: content growing under an animated scroll
    /// cuts it short, and the app going to the back mid-flick loses the last event. Left
    /// as reported, the timeline would count itself as moving for good and never snap or
    /// repair again. A coast whose reader has not moved the offset for 400ms is over,
    /// whatever was said (content growing under a held end moves the offset too, and used
    /// to keep a cut-short coast alive for as long as a turn streamed: no snap, no repair,
    /// and a running turn the reader could not see until the thread was reopened); a drag
    /// whose finger has not moved for 2s is taken as lost the same way. Three seconds is
    /// the ceiling on any phase. The layout gets checked once it is over.
    func notePhase(_ phase: ScrollPhase) {
        if phase == .tracking || phase == .interacting { noteUserNavigation() }
        if phase == .idle { animatedNavigation = false }
        isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        isCoasting = phase == .decelerating || phase == .animating
        if isUserScrolling { drift = 0 }
        phaseWatch?.cancel()
        phaseWatch = nil
        guard isCoasting || isUserScrolling else { return }
        let now = CACurrentMediaTime()
        lastOffsetChangeAt = now
        lastReaderMovementAt = now
        phaseStartedAt = now
        let still: CFTimeInterval = phase == .tracking || phase == .interacting ? 2.0 : 0.4
        phaseWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                let now = CACurrentMediaTime()
                guard now - lastReaderMovementAt >= still || now - phaseStartedAt >= 3.0 else { continue }
                isUserScrolling = false
                isCoasting = false
                if let reported = reportedTimeline, !isReaderScrolling {
                    ScrollActivity.shared.setScrolling(false, timeline: reported)
                }
                checkRequest += 1
                return
            }
        }
    }

    /// Looks a beat from now for any row on screen; none, with rows to show, asks the
    /// timeline to repair its layout. Re-armed by every call; a row reporting itself
    /// visible disarms it.
    func armBlankWatch() {
        blankWatch?.cancel()
        blankWatch = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, showsNothing else { return }
            checkRequest += 1
        }
    }

    /// The reader is back in front of the timeline: whatever it did unseen, it checks
    /// itself now, with a full run of repairs available, and the stack is told where the
    /// viewport is whatever the rows report.
    func noteReturnToFront() {
        blankRepairs = 0
        checkRequest += 1
        armBlankWatch()
        armViewportRefresh()
    }

    // MARK: Refreshing viewport layout

    /// Adds a frame's drift; true once it amounts to more than `tolerance`, which starts
    /// the count over.
    func noteDrift(_ amount: CGFloat, tolerance: CGFloat) -> Bool {
        drift += amount
        guard drift > tolerance else { return false }
        drift = 0
        return true
    }

    func resetDrift() {
        drift = 0
    }

    /// Asks the timeline to refresh its mounted rows, once per run-loop turn for however
    /// many asks land in the meantime, and never more than a handful in a row.
    func armViewportRefresh() {
        drift = 0
        guard !refreshPending else { return }
        let now = CACurrentMediaTime()
        if now - burstStartedAt > 2 {
            burstStartedAt = now
            refreshesInBurst = 0
        }
        guard refreshesInBurst < 8 else { return }
        refreshesInBurst += 1
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshPending = false
            refreshRequest += 1
        }
    }

    private var scrollView: NSScrollView? {
        guard let probe, probe.window != nil else { return nil }
        return probe.enclosingScrollView
    }

    /// Takes the block in the middle of the on-screen run — a reply filling the viewport is
    /// that block on its own — and lights the sent message at or above it.
    private func resolveActive() {
        let onScreen = outlineIDs.enumerated().filter { visibleIDs.contains($0.element) }
        guard !onScreen.isEmpty else { return }
        let middle = onScreen[onScreen.count / 2].offset
        let resolved = outlineIDs[...middle].last { userBlockIDs.contains($0) }
        if resolved != activeBlockID { activeBlockID = resolved }
    }
}

/// A continued thread's provenance, compact enough for both the empty first screen and the
/// head of a populated timeline. The source's title and nothing else.
private struct ContinuationSourceLabel: View {
    let sourceTitle: String

    var body: some View {
        Text(verbatim: String(format: Chrome.localized("Continuing from “%@”"), sourceTitle))
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Continuing from %@"), sourceTitle)))
    }
}

/// A view of no size inside the scroll view's content, through which the scroll view is
/// found for layout repair and disclosure anchoring. The main chat also resolves its top fade
/// from here. Panels leave `usesTimelineTopFade` false.
private struct ScrollViewProbe: NSViewRepresentable {
    var usesTimelineTopFade = false
    let onResolve: (NSView) -> Void
    let onWheel: () -> Void

    final class Coordinator {
        var fade: TimelineTopFade?
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.fade = TimelineTopFade()
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let probe = ProbeView(frame: .zero)
        bind(probe, fade: context.coordinator.fade)
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? ProbeView else { return }
        bind(probe, fade: context.coordinator.fade)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        let probe = nsView as? ProbeView
        probe?.removeWheelMonitor()
        coordinator.fade?.detach()
        probe?.fade = nil
    }

    /// The fade shares the probe's resolve. `tracking.probe` is still the caller's closure.
    private func bind(_ probe: ProbeView, fade: TimelineTopFade?) {
        let resolve = onResolve
        probe.fade = fade
        probe.usesTimelineTopFade = usesTimelineTopFade
        probe.onResolve = { view in
            resolve(view)
            (view as? ProbeView)?.syncTopFade()
        }
        probe.onWheel = onWheel
        if probe.window != nil { probe.syncTopFade() }
    }

    private final class ProbeView: NSView {
        var onResolve: (NSView) -> Void = { _ in }
        var onWheel: () -> Void = {}
        var usesTimelineTopFade = false
        var fade: TimelineTopFade?
        private var wheelMonitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        func removeWheelMonitor() {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }

        /// AppKit delivers these view callbacks on the main thread.
        func syncTopFade() {
            let enabled = usesTimelineTopFade
            let candidate = enclosingScrollView
            let fade = self.fade
            MainActor.assumeIsolated {
                guard enabled else {
                    fade?.detach()
                    return
                }
                fade?.attach(to: candidate)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        /// Only a probe: never in the way of a click or a cursor update.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWheelMonitor()
            guard window != nil else {
                let fade = self.fade
                MainActor.assumeIsolated { fade?.detach() }
                return
            }
            onResolve(self)
            let fade = self.fade
            MainActor.assumeIsolated { fade?.relayout() }
            // AppKit local monitors observe input before dispatch and return it unchanged.
            // https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let scrollView = enclosingScrollView,
                      event.window === window, event.scrollingDeltaY != 0,
                      let content = window?.contentView, let parent = content.superview else { return event }
                let point = parent.convert(event.locationInWindow, from: nil)
                let hit = content.hitTest(point)
                guard Self.routesVerticalWheel(from: hit, to: scrollView) else { return event }
                onWheel()
                return event
            }
        }

        private static func routesVerticalWheel(from hit: NSView?, to timeline: NSScrollView) -> Bool {
            var owner = hit?.enclosingScrollView
            while let scroll = owner {
                if scroll === timeline { return true }
                // Horizontal markdown scrollers pass vertical movement to the timeline.
                // A nested vertical viewport keeps its own input, even with hidden bars.
                if scroll is MathParagraphHost {
                    owner = scroll.superview?.enclosingScrollView
                    continue
                }
                guard !scroll.hasVerticalScroller, let document = scroll.documentView,
                      document.bounds.height <= scroll.contentView.bounds.height + 1 else { return false }
                owner = scroll.superview?.enclosingScrollView
            }
            return false
        }
    }
}

/// Hidden switch. Only the string `b` selects the upstream band; anything else, including a
/// missing value, keeps the local 72pt band. Read when the mask is laid out, not observed.
private enum TimelineFadeStyle {
    static let defaultsKey = "timelineTopFadeStyle"
    case a, b

    static var current: TimelineFadeStyle {
        (CaptureRun.defaults ?? .standard).string(forKey: defaultsKey) == "b" ? .b : .a
    }

    /// A matches `Chrome.veilHeight` and `Chrome.contentTopInset` (12 + 32 + 28). The
    /// timeline's top padding fills that band, so a resting top puts the first message on
    /// the solid side of the mask. B ends 6pt below the capsule, inside that padding.
    var bandHeight: CGFloat {
        switch self {
        case .a: Chrome.veilHeight
        case .b: Chrome.chromeTopPadding + Chrome.capsuleHeight + 6
        }
    }

    var colors: [CGColor] {
        switch self {
        case .a: [Self.clear, Self.clear, Self.partial, Self.opaque]
        case .b: [Self.clear, Self.clear, Self.opaque]
        }
    }

    var locations: [NSNumber] {
        let midline = Chrome.chromeTopPadding + Chrome.capsuleHeight / 2
        switch self {
        case .a:
            return Self.stops(0, midline / Chrome.veilHeight, 0.74, 1)
        case .b:
            let height = bandHeight
            return Self.stops(0, height > 0 ? midline / height : 0, 1)
        }
    }

    private static let clear = CGColor(gray: 0, alpha: 0)
    private static let partial = CGColor(gray: 0, alpha: 0.45)
    private static let opaque = CGColor(gray: 0, alpha: 1)

    private static func stops(_ values: CGFloat...) -> [NSNumber] {
        values.map { NSNumber(value: Double($0)) }
    }
}

/// Mask on the timeline `NSScrollView`'s own layer: one gradient band, then a solid body.
/// The compositor applies it as the content moves, so scrolling and streaming do not touch
/// it. A resize, a new scroll view, or a return to the window lays it out again. No color
/// is painted behind the title.
@MainActor
private final class TimelineTopFade {
    private static let maskName = "timelineTopFade"
    private weak var scrollView: NSScrollView?
    private weak var mask: TimelineTopFadeMask?
    /// Restored on detach when this fade is what turned frame posts on.
    private var enabledFramePosts = false

    /// Same scroll view and the same mask is a no-op. A mask we did not create is left in place.
    func attach(to candidate: NSScrollView?) {
        guard let candidate else {
            detach()
            return
        }
        if let mask, scrollView === candidate, (candidate.layer?.mask as AnyObject?) === mask { return }
        detach()
        install(on: candidate)
    }

    /// Window entry and a fresh mount re-read the style. Scroll frames do not get here.
    func relayout() {
        guard let scrollView, let mask, (scrollView.layer?.mask as AnyObject?) === mask else { return }
        mask.layout(in: scrollView)
    }

    func detach() {
        let dying = mask
        let host = scrollView
        let restorePosts = enabledFramePosts
        mask = nil
        scrollView = nil
        enabledFramePosts = false
        dying?.clearObserver()
        guard let host else { return }
        if restorePosts { host.postsFrameChangedNotifications = false }
        guard let dying, (host.layer?.mask as AnyObject?) === dying else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.layer?.mask = nil
        CATransaction.commit()
    }

    private func install(on scrollView: NSScrollView) {
        scrollView.wantsLayer = true
        guard let host = scrollView.layer, host.mask == nil else { return }
        let installed = TimelineTopFadeMask()
        installed.name = Self.maskName
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        host.mask = installed
        bind(mask: installed, to: scrollView)
    }

    private func bind(mask installed: TimelineTopFadeMask, to scrollView: NSScrollView) {
        mask = installed
        self.scrollView = scrollView
        if !scrollView.postsFrameChangedNotifications {
            scrollView.postsFrameChangedNotifications = true
            enabledFramePosts = true
        }
        if installed.observer == nil {
            installed.observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main
            ) { [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView, let installed = self.mask,
                          self.scrollView === scrollView,
                          (scrollView.layer?.mask as AnyObject?) === installed else { return }
                    installed.layout(in: scrollView)
                }
            }
        }
        installed.layout(in: scrollView)
    }
}

/// Gradient plus solid body. The observer token lives here, so dropping the mask drops the
/// observation with it. The block holds the scroll view weakly.
private final class TimelineTopFadeMask: CALayer {
    let band = CAGradientLayer()
    let body = CALayer()
    var observer: NSObjectProtocol?

    override init() {
        super.init()
        body.backgroundColor = CGColor(gray: 0, alpha: 1)
        addSublayer(band)
        addSublayer(body)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func clearObserver() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    deinit { clearObserver() }

    /// Lays the band against the top edge in both flipped and unflipped scroll views.
    /// A non-zero bounds origin is the mask frame; sublayers sit in the mask's own bounds.
    /// Shorter than the band, the band hangs off the top and the mask clips it, so the
    /// stops stay put instead of squeezing into the view.
    @MainActor
    func layout(in scrollView: NSScrollView) {
        let hostBounds = scrollView.layer?.bounds ?? scrollView.bounds
        let style = TimelineFadeStyle.current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        frame = hostBounds
        masksToBounds = true
        let local = bounds
        let width = local.width
        let height = local.height
        let bandHeight = style.bandHeight
        guard width > 0, height > 0, bandHeight > 0 else {
            band.frame = .zero
            body.frame = .zero
            return
        }
        let flipped = scrollView.isFlipped
        if flipped {
            band.frame = CGRect(x: local.minX, y: local.minY, width: width, height: bandHeight)
            body.frame = CGRect(
                x: local.minX, y: local.minY + bandHeight,
                width: width, height: max(0, height - bandHeight)
            )
            band.startPoint = CGPoint(x: 0.5, y: 0)
            band.endPoint = CGPoint(x: 0.5, y: 1)
        } else {
            band.frame = CGRect(
                x: local.minX, y: local.minY + height - bandHeight,
                width: width, height: bandHeight
            )
            body.frame = CGRect(
                x: local.minX, y: local.minY,
                width: width, height: max(0, height - bandHeight)
            )
            band.startPoint = CGPoint(x: 0.5, y: 1)
            band.endPoint = CGPoint(x: 0.5, y: 0)
        }
        band.colors = style.colors
        band.locations = style.locations
    }
}

/// Bumps when the app comes to the front or one of its windows is uncovered: the moments
/// a reader comes back to a timeline that has been changing unseen. Which window it was
/// is kept with the bump: the app coming to the front concerns every timeline, a window
/// being uncovered only the timelines in it. Every window ordered in posts the same
/// occlusion change, a popover's or a tooltip's included, and a timeline that took those
/// for its own window being uncovered checked itself each time one opened over the chat:
/// a snap to the end, and its scroll view moved a point and back, under a reader who had
/// not gone anywhere.
@MainActor
@Observable
final class FrontMonitor {
    static let shared = FrontMonitor()
    private(set) var revision = 0
    /// Whether anyone can see the app: it is frontmost and one of its windows is on screen.
    /// What the decorations that run without end follow, so a hidden or backgrounded
    /// window animates nothing.
    private(set) var isVisible = true
    /// The window the last bump was for, or none when the app itself came to the front.
    @ObservationIgnored private weak var uncovered: NSWindow?
    @ObservationIgnored private var isAppWide = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.bump(for: nil)
                self?.refreshVisibility()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibility() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Delivered on the main queue; the window is read on the main actor it belongs to.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                self?.refreshVisibility()
                guard let window = object as? NSWindow, window.occlusionState.contains(.visible) else { return }
                self?.bump(for: window)
            }
        })
    }

    /// Whether the last bump brought the reader back to a timeline in `window`. A timeline
    /// in no window yet has nothing to check.
    func concerns(_ window: NSWindow?) -> Bool {
        if isAppWide { return true }
        guard let uncovered, let window else { return false }
        return uncovered === window
    }

    private func bump(for window: NSWindow?) {
        uncovered = window
        isAppWide = window == nil
        revision += 1
    }

    private func refreshVisibility() {
        let visible = NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        if visible != isVisible { isVisible = visible }
    }
}

/// Scroll measurements, built by a plain initializer rather than an inline closure.
/// Deliberately minimal: every stored field is compared every scroll frame, and any
/// write to view state here would re-render the timeline mid-scroll.
private struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var distanceFromBottom: CGFloat
    var travel: CGFloat
    /// The viewport's vertical centre in the content: the sign that it moved.
    var centerY: CGFloat
    /// The raw offset, which only a scroll changes; the centre moves with the viewport's height too.
    var offset: CGFloat

    init(geometry: ScrollGeometry) {
        centerY = geometry.visibleRect.midY
        offset = geometry.contentOffset.y
        contentHeight = geometry.contentSize.height
        containerHeight = geometry.containerSize.height
        let insets = geometry.contentInsets.top + geometry.contentInsets.bottom
        // Never more than the content can actually scroll. While the queue tab folds,
        // the bottom inset shrinks a frame ahead of the filler that keeps a short
        // conversation at the pane's bottom, so the bottom anchor briefly lifts empty
        // space under the chrome; the veil would flash over nothing.
        let excess = max(0, geometry.contentSize.height + insets - geometry.containerSize.height)
        travel = min(max(0, geometry.contentOffset.y + geometry.contentInsets.top), excess)
        if geometry.contentSize.height <= geometry.containerSize.height + 1 {
            distanceFromBottom = 0
        } else {
            // On macOS the safe-area composer already reduces containerSize. Adding
            // its bottom inset again reports a reader at the end as one composer-height
            // away, so scrolling back down never re-enables following. visibleRect also
            // includes the inset; use the content viewport's offset and size instead.
            distanceFromBottom = geometry.contentSize.height
                - geometry.contentOffset.y - geometry.containerSize.height
        }
    }
}

enum TimelineGroup: Identifiable, Equatable {
    case single(TimelineEntry)
    /// Adjacent tools, thinking and informational notices, in arrival order.
    case work(id: String, entries: [TimelineEntry])
    /// Adjacent Hydra delegations stay at their original position, outside work groups.
    case heads(id: String, entries: [TimelineEntry])

    var id: String {
        switch self {
        case .single(let entry): entry.id
        case .work(let id, _): id
        case .heads(let id, _): id
        }
    }

    /// Whether the entry is a head the turn sent out: a tool call of the `.agent` kind.
    @MainActor
    static func isHead(_ entry: TimelineEntry) -> Bool {
        if case .tool(let call) = entry.item.content, call.kind == .agent { return true }
        return false
    }

    @MainActor
    static func build(_ entries: [TimelineEntry], showReasoning: Bool) -> [TimelineGroup] {
        var groups: [TimelineGroup] = []
        var work: [TimelineEntry] = []
        var heads: [TimelineEntry] = []

        func flushWork() {
            guard let first = work.first else { return }
            groups.append(.work(id: "work-\(first.id)", entries: work))
            work.removeAll()
        }

        func flushHeads() {
            guard let first = heads.first else { return }
            groups.append(.heads(id: "heads-\(first.id)", entries: heads))
            heads.removeAll()
        }

        for entry in entries {
            // Persistence-only snapshots and hidden thinking do not split visible steps.
            if entry.kind == .todos || (entry.kind == .reasoning && !showReasoning) { continue }
            if isHead(entry) {
                flushWork()
                if let last = heads.last, let previous = last.turnID, let current = entry.turnID, previous != current { flushHeads() }
                heads.append(entry)
                continue
            }
            flushHeads()
            let isStep: Bool
            switch entry.kind {
            case .tool, .reasoning:
                isStep = true
            case .notice:
                if case .notice(let notice) = entry.item.content {
                    isStep = notice.level == .info && notice.limit == nil
                } else { isStep = false }
            default:
                isStep = false
            }
            if isStep {
                if let last = work.last, let previous = last.turnID, let current = entry.turnID, previous != current { flushWork() }
                work.append(entry)
            } else {
                flushWork()
                groups.append(.single(entry))
            }
        }
        flushWork()
        flushHeads()
        return groups
    }
}

/// The finished heads' roster indices in finish order, `earlier` those done before the
/// running turn began, `later` the rest. Both live in their turn's process.
struct HeadPills: Equatable {
    var earlier: [Int] = []
    var later: [Int] = []
    var byTurn: [UUID: [Int]] = [:]
}

/// Native tool identities retain completed reports on the turn that delegated them.
enum HydraCompletionPlacement {
    @MainActor static func byTurn(heads: [HydraHeadInfo], entries: [TimelineEntry], turns: [TurnRecord]) -> [UUID: [Int]] {
        guard heads.contains(where: { $0.isFinished && $0.nativeCanonicalID == nil }) else { return [:] }
        var owners: [String: UUID] = [:]
        for entry in entries {
            guard entry.kind == .tool, let turn = entry.turnID else { continue }
            owners[OMPAgentJournal.toolID(entry.id)] = turn
        }
        let orderedTurns = turns.sorted { $0.index < $1.index }
        var result: [UUID: [Int]] = [:]
        let finished = heads.filter { $0.isFinished && $0.nativeCanonicalID == nil }.sorted {
            ($0.finishedAt ?? .distantPast, $0.index) < ($1.finishedAt ?? .distantPast, $1.index)
        }
        for head in finished {
            let owner: UUID?
            if let toolID = head.toolUseID ?? head.nativeResult?.parentToolCallID {
                owner = owners[OMPAgentJournal.toolID(toolID)]
            } else {
                // Old records without a tool identity use their observed start, never
                // their completion (which may be several parent turns later).
                let start = head.executionStartedAt ?? head.startedAt
                owner = orderedTurns.last {
                    $0.startedAt <= start && ($0.completedAt.map { start <= $0 } ?? true)
                }?.id
            }
            if let owner { result[owner, default: []].append(head.index) }
        }
        return result
    }
}

/// Transient waiting belongs to the turn's process, including after its overall fold.
struct TurnWaiting: Equatable {
    var heads: [Int] = []
    var backgroundTasks: [String] = []
}

/// A turn keeps one block identity while it runs and after completion. Running content
/// reads chronologically; completion folds the entire process above its final reply.
/// Entries outside a turn render as plain groups.
///
/// Equatable, so a rebuilt timeline can tell an unchanged block from a changed one and
/// skip its row. Entries compare by identity: what a row shows of an entry it observes
/// itself, so the same entry object always means the same row.
enum DisplayBlock: Identifiable, Equatable {
    /// A turn, with its entries in order (the end marker left out): folded
    /// once it has a summary, running (or ended without its marker) until then.
    /// `showsWorking` is the working line at the end of the running turn.
    case turn(id: String, turnID: UUID, entries: [TimelineEntry], summary: TurnSummary?, finalAssistantID: String?, showsWorking: Bool, waiting: TurnWaiting)
    /// A plain group, with the facts its row needs from the turn it belongs to: the turn's
    /// summary on the turn's last reply, and whether the turn produced a reply on its end marker.
    case group(TimelineGroup, summary: TurnSummary?, hasReply: Bool)
    /// The working line on its own, for a running turn whose latest entries belong to no
    /// turn. Never built from the entries: the timeline appends it while waiting on a reply.
    case working(turnID: UUID?, liveWork: [TimelineEntry])
    /// The team's work on its way to the remote once the lead's turn is over (see
    /// `AppModel.autoMergeHydraWork`). Never built from the entries either: the timeline
    /// appends its pill while the merge runs and drops it when the note about the outcome
    /// lands, the pill morphing in place into the merged report. Carries the id the
    /// outcome note will land under (`ThreadRuntime.hydraMergeNoteID`), so the note's
    /// block takes this one's identity and the pill morphs into the merged report.
    case merging(id: String)
    /// The heads still out on the lead's behalf once its turn is over, by their roster
    /// index in the order they went. Never built from the entries: the timeline appends
    /// it while any head works and drops it when the last one reports back.
    case headsWorking(heads: [Int], trailing: Bool)
    case backgroundTasks([String])

    var id: String {
        switch self {
        case .turn(let id, _, _, _, _, _, _): id
        case .group(let group, _, _): group.id
        case .working(let turnID, _): "working-\(turnID?.uuidString ?? "")"
        case .merging(let id): id
        case .headsWorking(_, let trailing): trailing ? "hydra-heads-working-tail" : "hydra-heads-working"
        case .backgroundTasks: "background-tasks"
        }
    }

    /// The turn the block belongs to, for the revert controls.
    var turnID: UUID? {
        switch self {
        case .turn(_, let turnID, _, _, _, _, _): turnID
        case .group(.single(let entry), _, _): entry.turnID
        case .group(.work, _, _), .group(.heads, _, _), .working, .merging, .headsWorking, .backgroundTasks: nil
        }
    }

    /// Whether the block holds a message the user sent (a turn prompt or a
    /// standalone user message). Only these get rail ticks.
    var hasUserMessage: Bool {
        switch self {
        case .turn(_, _, let entries, _, _, _, _): entries.contains { $0.kind == .user }
        case .group(.single(let entry), _, _): entry.kind == .user
        case .group(.work, _, _), .group(.heads, _, _), .working, .merging, .headsWorking, .backgroundTasks: false
        }
    }

    /// The merge pill's state when this block is the pill: the merge under way, or the
    /// note about its outcome. The note lands under the merging block's own id (see
    /// `ThreadRuntime.hydraMergeNoteID`), so the block keeps its identity across the
    /// change and one row morphs from the one state to the other.
    @MainActor
    var hydraMergePhase: HydraMergePhase? {
        switch self {
        case .merging: return .merging
        case .group(.single(let entry), _, _):
            guard case .user(let message) = entry.item.content, Self.isMergeOutcome(message) else { return nil }
            return .outcome(message)
        default: return nil
        }
    }

    /// What a build leaves behind besides its blocks: where the last run began. The runs
    /// before it are what an append never touches, so the cache keeps their blocks and
    /// builds the rest again (see `TimelineBlockCache`).
    struct Built {
        var blocks: [DisplayBlock]
        /// How many blocks at the front come from runs before the last one. The synthetic
        /// blocks at the end never count.
        var stableCount: Int
        /// The index of the entry the last run begins with.
        var lastRunStart: Int
    }

    @MainActor
    static func build(_ entries: [TimelineEntry], meta: TimelineMeta, showReasoning: Bool, isRunning: Bool, hydraMergeID: String?, pills: HeadPills = HeadPills()) -> [DisplayBlock] {
        build(entries, from: 0, keeping: [], meta: meta, showReasoning: showReasoning, isRunning: isRunning, hydraMergeID: hydraMergeID, pills: pills).blocks
    }

    /// The blocks for the entries from `start` on, after `kept`: the blocks the entries
    /// before `start` built last time. Building from 0 with nothing kept is the full build.
    @MainActor
    static func build(_ entries: [TimelineEntry], from start: Int, keeping kept: ArraySlice<DisplayBlock>, meta: TimelineMeta, showReasoning: Bool, isRunning: Bool, hydraMergeID: String?, pills: HeadPills) -> Built {
        // Partition into contiguous runs sharing one turnID (nil groups together), so every
        // turn becomes one block. A run is a range of indices: no entry is copied to find it.
        var runs: [(turnID: UUID?, range: Range<Int>)] = []
        var ended = false
        for index in start..<entries.count {
            // Unscoped notices arriving during a turn still belong at that point in its
            // process. They must not split one completed turn into several disclosures.
            let turnID = entries[index].turnID ?? (ended ? nil : runs.last?.turnID)
            if let last = runs.last, last.turnID == turnID {
                runs[runs.count - 1].range = last.range.lowerBound..<(index + 1)
            } else {
                runs.append((turnID, index..<(index + 1)))
                ended = false
            }
            if entries[index].kind == .turnEnd { ended = true }
        }
        // A final-answer identity is selected only once the native turn ends.
        let waiting = isRunning
        var blocks = kept.map { block -> DisplayBlock in
            guard case .turn(let id, let turnID, let rows, let summary, let final, let working, _) = block else { return block }
            return .turn(id: id, turnID: turnID, entries: rows, summary: summary, finalAssistantID: final, showsWorking: working, waiting: TurnWaiting())
        }
        blocks.reserveCapacity(kept.count + runs.count + 3)
        var stableCount = blocks.count
        for (index, run) in runs.enumerated() {
            let isLast = index == runs.count - 1
            if isLast { stableCount = blocks.count }
            if let turnID = run.turnID {
                let rows = entries[run.range].filter { $0.kind != .turnEnd }
                let summary = meta.summaryByTurn[turnID]
                let showsWorking = isLast && summary == nil && waiting
                // The first row also distinguishes any later segment with this turn ID.
                let runID = entries[run.range.lowerBound].id
                blocks.append(.turn(id: "turn-\(turnID.uuidString)-\(runID)", turnID: turnID, entries: rows, summary: summary,
                                    finalAssistantID: summary == nil ? nil : meta.finalAssistantIDByTurn[turnID], showsWorking: showsWorking, waiting: TurnWaiting()))
            } else {
                for group in TimelineGroup.build(Array(entries[run.range]), showReasoning: showReasoning) {
                    blocks.append(.group(group, summary: meta.summary(for: group), hasReply: meta.hasReply(for: group)))
                }
            }
        }
        if waiting, !(blocks.last?.carriesWorkingLine ?? false) {
            blocks.append(.working(turnID: entries.last?.turnID, liveWork: []))
        }
        // Waiting is process content too. Keeping it on the turn lets completion fold
        // it with tools, intermediate replies and delegations instead of leaving a tail.
        attachHeads(pills.earlier, to: &blocks, completedOnly: true)
        attachHeads(pills.later, to: &blocks, completedOnly: false)
        var assigned = Set<UUID>()
        for index in blocks.indices.reversed() {
            guard case .turn(let id, let turnID, let rows, let summary, let final, let working, var waiting) = blocks[index],
                  let completed = pills.byTurn[turnID], assigned.insert(turnID).inserted else { continue }
            var seen = Set<Int>()
            waiting.heads = (waiting.heads + completed).filter { seen.insert($0).inserted }
            blocks[index] = .turn(id: id, turnID: turnID, entries: rows, summary: summary,
                                  finalAssistantID: final, showsWorking: working, waiting: waiting)
        }
        // The merge begins once the lead's turn is over; while it runs, its pill ends the
        // timeline, and stays if the user starts the lead on something else meanwhile.
        // The pill shares the merged report's frame, so when the note about the outcome
        // lands the merging state morphs into it in place. The outcome and the pill never
        // show together: the note and the flag clearing land in one pass, and this guard
        // covers the beat between them, so there is no second row.
        if let hydraMergeID, !Self.endsWithMergeOutcome(entries) {
            blocks.append(.merging(id: hydraMergeID))
        }
        return Built(blocks: blocks, stableCount: stableCount, lastRunStart: runs.last?.range.lowerBound ?? start)
    }

    private var carriesWorkingLine: Bool {
        if case .turn(_, _, _, _, _, true, _) = self { return true }
        return false
    }

    private static func attachHeads(_ heads: [Int], to blocks: inout [DisplayBlock], completedOnly: Bool) {
        guard !heads.isEmpty else { return }
        if let index = blocks.lastIndex(where: {
            if case .turn(_, _, _, let summary, _, _, _) = $0 { return !completedOnly || summary != nil }
            return false
        }), case .turn(let id, let turnID, let rows, let summary, let final, let working, var waiting) = blocks[index] {
            var seen = Set<Int>()
            waiting.heads = (waiting.heads + heads).filter { seen.insert($0).inserted }
            blocks[index] = .turn(id: id, turnID: turnID, entries: rows, summary: summary, finalAssistantID: final, showsWorking: working, waiting: waiting)
        } else {
            blocks.append(.headsWorking(heads: heads, trailing: !completedOnly))
        }
    }

    static func addingBackgroundTasks(_ descriptions: [String], to blocks: [DisplayBlock]) -> [DisplayBlock] {
        guard !descriptions.isEmpty else { return blocks }
        var blocks = blocks
        if let index = blocks.lastIndex(where: {
            if case .turn = $0 { return true }
            return false
        }), case .turn(let id, let turnID, let rows, let summary, let final, let working, var waiting) = blocks[index] {
            waiting.backgroundTasks = descriptions
            blocks[index] = .turn(id: id, turnID: turnID, entries: rows, summary: summary, finalAssistantID: final, showsWorking: working, waiting: waiting)
        } else {
            blocks.append(.backgroundTasks(descriptions))
        }
        return blocks
    }

    /// Whether the timeline already ends with the merge's outcome note, so the merging
    /// pill has already become the merged report and must not linger as a second row.
    /// Merge notes are Hydra's own (no heads behind them) and titled "Hydra …"; a head's
    /// landing or patch note leads with the head's name instead.
    @MainActor
    private static func endsWithMergeOutcome(_ entries: [TimelineEntry]) -> Bool {
        guard let last = entries.last, case .user(let message) = last.item.content else { return false }
        return isMergeOutcome(message)
    }

    /// Whether a Hydra note is about a merge's outcome. Merge notes are Hydra's own (no
    /// heads behind them) and titled "Hydra …"; a head's landing or patch note leads with
    /// the head's name instead.
    static func isMergeOutcome(_ message: UserMessage) -> Bool {
        guard message.isFromHydra, (message.hydraHeads ?? []).isEmpty else { return false }
        let title = message.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return title.hasPrefix("Hydra ")
    }
}

/// The last build of the timeline's blocks, with everything that build read. Entries are
/// compared by identity (a pointer each) and by kind, never by content, so a body run that
/// changed none of them gets its blocks back instead of building them again, and the body
/// never observes a streaming row through the key. The per-turn meta is the cache's own,
/// built with the blocks. Nothing else reaches the blocks: they are handed straight to
/// the stack, whose rows compare them.
@MainActor
final class TimelineBlockCache {
    /// One cache per open thread, kept across the timeline view being rebuilt, so coming
    /// back to a chat reuses its blocks; the runtime keeps the entries alive so their
    /// identities stay valid.
    @MainActor private static var shared: [UUID: TimelineBlockCache] = [:]
    @MainActor private static var order: [UUID] = []
    @MainActor static func cache(for threadID: UUID) -> TimelineBlockCache {
        if let existing = shared[threadID] {
            order.removeAll { $0 == threadID }
            order.append(threadID)
            return existing
        }
        let created = TimelineBlockCache()
        shared[threadID] = created
        order.append(threadID)
        while order.count > 24 {
            let oldest = order.removeFirst()
            shared.removeValue(forKey: oldest)
        }
        return created
    }

    private struct Key: Equatable {
        var entries: [ObjectIdentifier]
        /// The fold: a turn's block folds the moment its end marker lands. The marker is an
        /// entry of its own, so the identities say so already; the count says so again for
        /// the price of one integer, should a marker ever be written into a row in place.
        var turnEnds: Int
        var isRunning: Bool
        /// The merge's row comes and goes on this alone; no entry changes for it.
        var hydraMergeID: String?
        /// The heads' row likewise: it comes and goes as heads start and finish.
        var pills: HeadPills
        var showReasoning: Bool

        /// Whether this key is `old` with entries appended and nothing else changed.
        func extends(_ old: Key) -> Bool {
            entries.count > old.entries.count
                && isRunning == old.isRunning
                && hydraMergeID == old.hydraMergeID
                && pills == old.pills
                && showReasoning == old.showReasoning
                && entries.starts(with: old.entries)
        }
    }

    private var key: Key?
    private var built = DisplayBlock.Built(blocks: [], stableCount: 0, lastRunStart: 0)
    private var meta = TimelineMeta()
    /// The mention list, once per roster of heads: heads come and go far more rarely
    /// than this body runs.
    private var personaHeads: [Int?] = []
    private var personaRoster = false
    private var personas: [HydraPersona] = []
    private struct CompletionHead: Equatable {
        let index: Int
        let tool: String?
        let start: Date
        let end: Date?
    }
    private struct CompletionTurn: Equatable {
        let id: UUID
        let index: Int
        let start: Date
        let end: Date?
    }
    private struct CompletionKey: Equatable {
        let revision: UInt64
        let heads: [CompletionHead]
        let turns: [CompletionTurn]
    }
    private var completionKey: CompletionKey?
    private var completedByTurn: [UUID: [Int]] = [:]

    func completions(heads: [HydraHeadInfo], entries: [TimelineEntry], revision: UInt64, turns: [TurnRecord]) -> [UUID: [Int]] {
        let finished = heads.filter { $0.isFinished && $0.nativeCanonicalID == nil }
        guard !finished.isEmpty else { completionKey = nil; completedByTurn = [:]; return [:] }
        let links = finished.map { CompletionHead(index: $0.index, tool: $0.toolUseID ?? $0.nativeResult?.parentToolCallID,
                                                 start: $0.executionStartedAt ?? $0.startedAt, end: $0.finishedAt) }
        let oldTurns = links.contains { $0.tool == nil } ? turns.map {
            CompletionTurn(id: $0.id, index: $0.index, start: $0.startedAt, end: $0.completedAt)
        } : []
        let wanted = CompletionKey(revision: revision, heads: links, turns: oldTurns)
        if wanted != completionKey {
            completedByTurn = HydraCompletionPlacement.byTurn(heads: finished, entries: entries, turns: turns)
            completionKey = wanted
        }
        return completedByTurn
    }
    #if DEBUG
    private var tailBuilds = 0
    #endif

    func blocks(for entries: [TimelineEntry], showReasoning: Bool, isRunning: Bool, hydraMergeID: String?, pills: HeadPills = HeadPills()) -> [DisplayBlock] {
        var identities: [ObjectIdentifier] = []
        identities.reserveCapacity(entries.count)
        var turnEnds = 0
        for entry in entries {
            identities.append(ObjectIdentifier(entry))
            if entry.kind == .turnEnd { turnEnds += 1 }
        }
        let wanted = Key(
            entries: identities,
            turnEnds: turnEnds,
            isRunning: isRunning,
            hydraMergeID: hydraMergeID,
            pills: pills,
            showReasoning: showReasoning
        )
        if wanted == key { return built.blocks }
        if let key, wanted.extends(key),
           let tail = buildTail(entries, appendedFrom: key.entries.count, showReasoning: showReasoning, isRunning: isRunning, hydraMergeID: hydraMergeID, pills: pills) {
            built = tail
        } else {
            meta = TimelineMeta.build(entries)
            built = DisplayBlock.build(entries, from: 0, keeping: [], meta: meta, showReasoning: showReasoning, isRunning: isRunning, hydraMergeID: hydraMergeID, pills: pills)
        }
        key = wanted
        return built.blocks
    }

    /// The append fast path: entries arrived and nothing else changed. Every run but the
    /// last is as it was, and so are its blocks: a turn block that is not the last carries
    /// no working line, and a plain group reads nothing beyond its own run. So the last run
    /// and the synthetic blocks after it are built again, over the meta grown by the new
    /// entries, and the rest is kept. Nil when a new end marker folds a kept turn block;
    /// that build starts over.
    private func buildTail(_ entries: [TimelineEntry], appendedFrom appended: Int, showReasoning: Bool, isRunning: Bool, hydraMergeID: String?, pills: HeadPills) -> DisplayBlock.Built? {
        var grown = meta
        for entry in entries[appended...] {
            grown.add(entry)
            if entry.kind == .turnEnd, case .turnEnd(let summary) = entry.item.content,
               built.blocks[..<built.stableCount].contains(where: { $0.turnID == summary.turnID }) {
                return nil
            }
        }
        let tail = DisplayBlock.build(entries, from: built.lastRunStart, keeping: built.blocks[..<built.stableCount], meta: grown, showReasoning: showReasoning, isRunning: isRunning, hydraMergeID: hydraMergeID, pills: pills)
        #if DEBUG
        // The fast path must be invisible: now and then, hold it against a full build.
        // A difference is a bug in the fast path, not a reason to crash a chat: it is
        // logged, and the full build stands in.
        tailBuilds += 1
        if tailBuilds % 20 == 0 {
            let full = DisplayBlock.build(entries, meta: grown, showReasoning: showReasoning, isRunning: isRunning, hydraMergeID: hydraMergeID, pills: pills)
            if tail.blocks != full {
                print("ThreadTimeline: the tail build differed from a full build after \(entries.count) entries")
                return nil
            }
        }
        #endif
        meta = grown
        return tail
    }

    /// The personas the prose may name, by the heads' roster indices, and with `roster`
    /// every name on the roster after them (a head still to be sent out). Memoized on
    /// both, so the list is built when a head comes or goes and not on every pass.
    func mentionPersonas(for heads: [ChatThread], roster: Bool) -> [HydraPersona] {
        let indices = heads.map { $0.hydra?.index }
        if indices == personaHeads, roster == personaRoster { return personas }
        var seen = Set<String>()
        personas = heads.compactMap { $0.hydra?.persona }.filter { seen.insert($0.name).inserted }
        if roster {
            personas += HydraRoster.personas.filter { seen.insert($0.name).inserted }
        }
        personaHeads = indices
        personaRoster = roster
        return personas
    }
}

/// Lazy-loading window for the timeline: only the newest groups are materialized, so
/// the number of live views stays bounded even for very long threads.
/// Opening a thread builds and lays out every block in the window before the first
/// frame — the bottom anchor needs the content's full height, and a block costs several
/// milliseconds — so the window opens with a handful, grows to its resting size a beat
/// later, and then a page at a time as the reader scrolls back.
enum TimelineWindow {
    static let firstPaint = 3
    static let initial = 24
    /// A page of history has never been measured, so all of it is built the frame it lands,
    /// mid-scroll; a small page keeps that frame short, and the next one follows as the
    /// reader goes on up.
    static let page = 10
    /// The most blocks the eager stack holds while the reader follows the end; past it the
    /// window drops back to `initial`.
    static let eagerLimit = 96
}

/// Per-turn facts computed once per timeline pass, so rows never scan the thread to
/// find their own summary. `kind`, `id` and `turnID` are fixed for a row's lifetime,
/// and finished turn summaries never change, so building this never costs renders
/// while streaming.
struct TimelineMeta {
    var lastAssistantIDByTurn: [UUID: String] = [:]
    /// The latest reply after the turn's last tool or user steer. It becomes a final
    /// answer only on successful completion, and is shared across split turn blocks.
    var finalAssistantIDByTurn: [UUID: String] = [:]
    var summaryByTurn: [UUID: TurnSummary] = [:]
    var turnsWithReply: Set<UUID> = []

    @MainActor
    static func build(_ entries: [TimelineEntry]) -> TimelineMeta {
        var meta = TimelineMeta()
        for entry in entries { meta.add(entry) }
        return meta
    }

    /// Takes one more entry, in timeline order. Only an end marker's content is read, and
    /// that never changes once written.
    @MainActor
    mutating func add(_ entry: TimelineEntry) {
        switch entry.kind {
        case .assistant:
            if let turnID = entry.turnID {
                lastAssistantIDByTurn[turnID] = entry.id
                turnsWithReply.insert(turnID)
                if summaryByTurn[turnID] == nil { finalAssistantIDByTurn[turnID] = entry.id }
            }
        case .tool, .user:
            if let turnID = entry.turnID, summaryByTurn[turnID] == nil {
                finalAssistantIDByTurn[turnID] = nil
            }
        case .turnEnd:
            if case .turnEnd(let summary) = entry.item.content {
                summaryByTurn[summary.turnID] = summary
                if summary.status != .completed { finalAssistantIDByTurn[summary.turnID] = nil }
            }
        default:
            break
        }
    }

    /// The turn's summary, shown on the turn's last reply only. A dictionary lookup,
    /// so rows never scan the thread.
    @MainActor
    func summary(for group: TimelineGroup) -> TurnSummary? {
        guard case .single(let entry) = group, entry.kind == .assistant,
              let turnID = entry.turnID, lastAssistantIDByTurn[turnID] == entry.id else { return nil }
        return summaryByTurn[turnID]
    }

    /// Whether a turn-end marker's turn produced a reply; when it did, the duration lives
    /// on the reply's hover line instead.
    @MainActor
    func hasReply(for group: TimelineGroup) -> Bool {
        guard case .single(let entry) = group, entry.kind == .turnEnd, let turnID = entry.turnID else { return false }
        return turnsWithReply.contains(turnID)
    }
}

/// What a row needs from outside its block, as plain values. Rows never read the app
/// model or the runtime's turn list themselves, so a change anywhere else in the app
/// never re-renders them; only a change to these values does.
struct RowContext: Equatable {
    var workingDirectory: String?
    /// Whether the block's turn can be reverted right now.
    var canRewind: Bool
}

private struct DisplayBlockView: View, Equatable {
    let block: DisplayBlock
    let runtime: ThreadRuntime
    let context: RowContext

    nonisolated static func == (lhs: DisplayBlockView, rhs: DisplayBlockView) -> Bool {
        lhs.block == rhs.block && lhs.runtime === rhs.runtime && lhs.context == rhs.context
    }

    var body: some View {
        // The merge pill in either state: the block keeps its id from the merge's first
        // stage to its outcome note, so this one branch keeps the row's identity and the
        // pill morphs rather than being swapped for another.
        if let phase = block.hydraMergePhase {
            HydraMergeRow(runtime: runtime, phase: phase)
        } else {
            switch block {
            case .group(let group, let summary, let hasReply):
                TimelineGroupView(group: group, runtime: runtime, summary: summary, hasReply: hasReply, context: context)
            case .turn(_, let turnID, let entries, let summary, let finalAssistantID, let showsWorking, let waiting):
                // The fold is a change of what the block shows, in the same frame, with no
                // transition: a fade over a block that can run to thousands of points is a
                // whole-layer composite the renderer may draw as nothing.
                if let summary {
                    TurnFinishedBlock(
                        runtime: runtime,
                        turnID: turnID,
                        summary: summary,
                        entries: entries,
                        finalAssistantID: finalAssistantID,
                        workingDirectory: context.workingDirectory,
                        canUndo: context.canRewind,
                        waiting: waiting
                    )
                    .transition(.identity)
                } else {
                    TurnRunningBlock(runtime: runtime, entries: entries, showsWorking: showsWorking, context: context, waiting: waiting)
                        .transition(.identity)
                }
            case .working:
                ActivityStatusLine(runtime: runtime)
            case .merging:
                // Routed through `hydraMergePhase` above; never reached.
                EmptyView()
            case .headsWorking(let heads, _):
                HydraHeadsWorkingRow(heads: heads, runtime: runtime)
            case .backgroundTasks(let descriptions):
                BackgroundTasksWorkingRow(descriptions: descriptions)
            }
        }
    }
}

/// Running turns and expanded completed processes share the same ordered rows.
struct TurnRunningBlock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.timelineLiveAppearance) private var liveAppearance
    let runtime: ThreadRuntime
    let entries: [TimelineEntry]
    let showsWorking: Bool
    let context: RowContext
    var waiting = TurnWaiting()
    /// The partition as last built, keyed on the entries' identities: grouping is by kind
    /// only, so it changes when a row comes or goes and never while one streams.
    @State private var groupCache = TurnGroupCache()

    var body: some View {
        let groups = groupCache.groups(for: entries, showReasoning: model.settings.showReasoning)
        let trailingWorkID: String? = if case .work? = groups.last { groups.last?.id } else { nil }
        // A plain stack: a lazy stack inside a lazy row resolved its own visibility on every
        // scrolled frame for nothing, the row is on screen whole or not at all.
        return VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
            ForEach(groups) { group in
                TurnRow(group: group, runtime: runtime, context: context, isWorking: showsWorking && group.id == trailingWorkID)
                    .equatable()
                    .transition(liveAppearance ? ThreadTimeline.rowTransition : .identity)
            }
            if !waiting.heads.isEmpty {
                HydraHeadsWorkingRow(heads: waiting.heads, runtime: runtime)
            }
            if !waiting.backgroundTasks.isEmpty {
                BackgroundTasksWorkingRow(descriptions: waiting.backgroundTasks)
            }
            if showsWorking {
                ActivityStatusLine(runtime: runtime, entries: entries)
                    .transition(liveAppearance ? ThreadTimeline.rowTransition : .identity)
            }
        }
    }
}

/// A running turn's last partition, with the identities it was built from. An object, so
/// handing the groups back is not a state write.
@MainActor
private final class TurnGroupCache {
    private var identities: [ObjectIdentifier] = []
    private var showReasoning = false
    private var groups: [TimelineGroup] = []

    func groups(for entries: [TimelineEntry], showReasoning: Bool) -> [TimelineGroup] {
        let wanted = entries.map(ObjectIdentifier.init)
        if wanted != identities || self.showReasoning != showReasoning {
            groups = TimelineGroup.build(entries, showReasoning: showReasoning)
            identities = wanted
            self.showReasoning = showReasoning
        }
        return groups
    }
}

/// One row of a running turn. Equatable, so a new entry re-renders its own row and none
/// of the rows above it.
private struct TurnRow: View, Equatable {
    let group: TimelineGroup
    let runtime: ThreadRuntime
    let context: RowContext
    var isWorking = false

    nonisolated static func == (lhs: TurnRow, rhs: TurnRow) -> Bool {
        lhs.group == rhs.group && lhs.runtime === rhs.runtime && lhs.context == rhs.context && lhs.isWorking == rhs.isWorking
    }

    var body: some View {
        // A running turn has no summary yet and no end marker: nothing for a row to carry
        // from the turn beyond the group itself.
        TimelineGroupView(group: group, runtime: runtime, summary: nil, hasReply: false, context: context, isWorking: isWorking)
    }
}

struct TimelineGroupView: View {
    let group: TimelineGroup
    let runtime: ThreadRuntime
    /// The turn's summary, when this group is the turn's last reply.
    let summary: TurnSummary?
    /// Whether the turn produced a reply, for a turn-end marker.
    let hasReply: Bool
    let context: RowContext
    var isWorking = false

    var body: some View {
        switch group {
        case .single(let entry):
            switch entry.kind {
            case .user: UserMessageRow(entry: entry, runtime: runtime, canRevert: context.canRewind)
            case .assistant: AssistantMessageRow(entry: entry, summary: summary, runtime: runtime)
            case .reasoning: EmptyView()
            case .tool: ActivityGroup(id: "work-" + entry.id, entries: [entry], runtime: runtime, workingDirectory: context.workingDirectory, isLive: isWorking)
            case .plan: PlanCard(entry: entry, runtime: runtime)
            case .todos: EmptyView()
            case .notice: NoticeRow(entry: entry)
            case .turnEnd:
                if case .turnEnd(let summary) = entry.item.content {
                    TurnEndRow(summary: summary, hasReply: hasReply)
                }
            }
        case .work(let id, let entries):
            ActivityGroup(id: id, entries: entries, runtime: runtime, workingDirectory: context.workingDirectory, isLive: isWorking)
        case .heads(_, let entries):
            HydraHeadsList(entries: entries, runtime: runtime, workingDirectory: context.workingDirectory)
        }
    }
}

/// The running turn's thinking, as tall as its content up to a cap, scrolling past it
/// (the tool rows' in-row cap). While the reader is at the end the streamed text keeps
/// the end in view; scrolled up, growth holds what they are reading in place instead.
struct ThinkingScroll: View {
    let steps: [ThinkingStep]
    private static let maxHeight: CGFloat = 360
    private static let pinSlack: CGFloat = 48
    @State private var pinned = true
    @State private var viewportHeight: CGFloat = 1
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var followTask: Task<Void, Never>?

    private var isStreaming: Bool { steps.contains { $0.isStreaming } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    MarkdownView(text: step.text, isStreaming: step.isStreaming).equatable()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) { height in
                let bounded = min(Self.maxHeight, max(1, height))
                if viewportHeight != bounded { viewportHeight = bounded }
                // Continue following after the viewport reaches its cap as well.
                if isStreaming && pinned { followLatest() }
            }
        }
        .frame(height: viewportHeight)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(pinned ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
        } action: { _, distance in
            // Initial measurement and new paragraphs can report an intermediate offset.
            // Only actual user scrolling can release the live bottom anchor.
            guard position.isPositionedByUser else { return }
            let atEnd = distance < Self.pinSlack
            if atEnd != pinned { pinned = atEnd }
        }
        .onChange(of: isStreaming, initial: true) { _, streaming in
            if streaming && pinned { followLatest() }
            else { followTask?.cancel() }
        }
        .onDisappear {
            followTask?.cancel()
            followTask = nil
        }
        .clipped()
    }

    private func followLatest() {
        followTask?.cancel()
        followTask = Task { @MainActor in
            // Apply the position after content and the bounded viewport have laid out.
            await Task.yield()
            guard !Task.isCancelled, pinned else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(edge: .bottom) }
        }
    }
}

/// One piece of the running turn's thinking, and whether it is still arriving.
struct ThinkingStep: Equatable {
    var text: String
    var isStreaming: Bool
}

/// Whether the reader has scrolled away from the latest message, shared with the composer that shows the jump button.
@MainActor
@Observable
final class TimelineScrollState {
    var showsJumpButton = false
    private(set) var jumpRequest = 0
    /// The composer area over the timeline changed height (the queued follow-ups tab
    /// opening, a follow-up being queued, an approval badge arriving): the viewport lost
    /// that height from its bottom edge. Kept apart from `jumpRequest`, which the reader's
    /// own jump button fires: a growth must never move a reader who scrolled up to read.
    private(set) var areaGrowthRequest = 0
    @ObservationIgnored private var growthPending = false
    @ObservationIgnored private var jumpButtonPending = false

    func jumpToLatest() {
        jumpRequest += 1
    }

    /// Out of the scroll handler, once per run-loop turn: `resolve` is read when the write
    /// lands, so a pin or distance that swung back within the turn writes nothing.
    func settleJumpButton(_ resolve: @escaping @MainActor () -> Bool) {
        guard !jumpButtonPending else { return }
        jumpButtonPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            jumpButtonPending = false
            let shows = resolve()
            guard shows != showsJumpButton else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                showsJumpButton = shows
            }
        }
    }

    /// One request per run-loop turn, so a height that swings within a frame asks once.
    func noteComposerAreaGrowth() {
        guard !growthPending else { return }
        growthPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            growthPending = false
            areaGrowthRequest += 1
        }
    }
}

/// Manual disclosures keep the containing block at its current viewport position.
/// A stable box lets the timeline renew the callback without invalidating every row.
/// Outside a timeline it does nothing.
@MainActor
final class TimelineRevealBox: Equatable {
    var presentation = TimelinePresentation()
    var disclosure: (String) -> Void = { _ in }

    nonisolated static func == (lhs: TimelineRevealBox, rhs: TimelineRevealBox) -> Bool {
        lhs === rhs
    }
}

private struct RevealTimelineEndKey: EnvironmentKey {
    static let defaultValue: TimelineRevealBox? = nil
}

extension EnvironmentValues {
    var revealTimelineEnd: TimelineRevealBox? {
        get { self[RevealTimelineEndKey.self] }
        set { self[RevealTimelineEndKey.self] = newValue }
    }
}

/// Applies the scroll freeze to the rows from a leaf of its own: the flag lives on the
/// tracking object and only this modifier reads it, so its flips re-render nothing but
/// this node, never the timeline's body.
private struct ScrollFreeze: ViewModifier {
    let tracking: TimelineScrollTracking

    func body(content: Content) -> some View {
        content.allowsHitTesting(!tracking.isReaderScrolling)
    }
}

/// The run of blocks the stack builds, by the ids of its first and last block, so a block
/// arriving at the end or a pill inserted above it never shifts which blocks those are.
/// No last id runs to the end, so a reader following the conversation gets every new block.
private struct MountedWindow: Equatable {
    var lowerID: String
    var upperID: String?

    init(lowerID: String, upperID: String?) {
        self.lowerID = lowerID
        self.upperID = upperID
    }

    init(_ range: Range<Int>, in blocks: [DisplayBlock]) {
        lowerID = blocks[min(range.lowerBound, blocks.count - 1)].id
        upperID = range.upperBound >= blocks.count ? nil : blocks[max(range.lowerBound, range.upperBound - 1)].id
    }

    /// The window over `blocks`, never before `start`. Nil when its first block has left.
    func range(in blocks: [DisplayBlock], start: Int) -> Range<Int>? {
        range(ids: blocks.lazy.map(\.id), start: start)
    }

    func range<Ids: RandomAccessCollection>(ids: Ids, start: Int) -> Range<Int>? where Ids.Element == String, Ids.Index == Int {
        guard let found = ids.firstIndex(of: lowerID) else { return nil }
        let lower = min(ids.count, max(start, found))
        let upper = upperID.flatMap { id in ids[lower...].firstIndex(of: id).map { $0 + 1 } } ?? ids.count
        return lower..<max(lower, upper)
    }
}

@MainActor
private final class TimelineMeasurements {
    var width: CGFloat = 0
    var frames: [String: CGRect] = [:]
    /// A row's frame in the viewport, from its content frame and the scroll offset: a
    /// geometry callback per row for this fired on every frame of every scroll.
    func viewportFrame(_ id: String, offset: CGFloat) -> CGRect? {
        frames[id]?.offsetBy(dx: 0, dy: Chrome.contentTopInset - offset)
    }
    var blockIDs: [String] = []
    var liveIDs: Set<String> = []
    var liveQuestions: Set<String> = []
    var materializedIDs: Set<String> = []
    private var knownIDs: Set<String>?
    private var knownQuestions: Set<String>?

    func noteArrivals(_ ids: [String], questions: [String]) {
        blockIDs = ids
        let current = Set(ids)
        if let knownIDs { liveIDs.formUnion(current.subtracting(knownIDs)) }
        knownIDs = current
        let questionIDs = Set(questions)
        if let knownQuestions { liveQuestions.formUnion(questionIDs.subtracting(knownQuestions)) }
        knownQuestions = questionIDs
    }

    func invalidate(width: CGFloat) {
        guard self.width != width else { return }
        self.width = width
        frames.removeAll()
    }

    func record(_ id: String, frame: CGRect) { frames[id] = frame }

    func height(of blocks: ArraySlice<DisplayBlock>) -> CGFloat {
        blocks.reduce(0) { $0 + (frames[$1.id]?.height ?? 0) + TimelineMetrics.rowSpacing }
    }

    func window(around index: Int, in blocks: [DisplayBlock], start: Int, viewport: CGFloat) -> Range<Int> {
        var lower = index
        var upper = index + 1
        var distance: CGFloat = 0
        while lower > start, distance < viewport {
            lower -= 1
            distance += (frames[blocks[lower].id]?.height ?? viewport) + TimelineMetrics.rowSpacing
        }
        distance = 0
        while upper < blocks.count, distance < viewport {
            distance += (frames[blocks[upper].id]?.height ?? viewport) + TimelineMetrics.rowSpacing
            upper += 1
        }
        // An unmeasured row cannot be replaced by an exact spacer.
        if let unknown = (start..<lower).first(where: { frames[blocks[$0].id] == nil }) { lower = unknown }
        if let unknown = (upper..<blocks.count).last(where: { frames[blocks[$0].id] == nil }) { upper = unknown + 1 }
        return lower..<upper
    }

    /// The newest blocks that fill a viewport and a margin above it, and every unmeasured
    /// block before them, which has no height for a spacer to stand in for.
    func tail(of blocks: [DisplayBlock], start: Int, viewport: CGFloat) -> Range<Int> {
        guard start < blocks.count else { return start..<blocks.count }
        var lower = blocks.count
        var distance: CGFloat = 0
        while lower > start, distance < max(600, viewport) * 2 {
            lower -= 1
            distance += (frames[blocks[lower].id]?.height ?? viewport) + TimelineMetrics.rowSpacing
        }
        if let unknown = (start..<lower).first(where: { frames[blocks[$0].id] == nil }) { lower = unknown }
        return lower..<blocks.count
    }
}

private struct TimelineLiveAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var timelineLiveAppearance: Bool {
        get { self[TimelineLiveAppearanceKey.self] }
        set { self[TimelineLiveAppearanceKey.self] = newValue }
    }
}

@MainActor
@Observable
final class TimelinePresentation {
    var finished: [UUID: Bool] = [:]
    var working: [String: Bool] = [:]
    var thoughts: [String: Bool] = [:]
    var prompts: [String: Bool] = [:]
    var notices: [String: Bool] = [:]
    @ObservationIgnored var revealedActivity: Set<String> = []
    @ObservationIgnored var previews: [String: String] = [:]
    @ObservationIgnored var anchorID: String?
    @ObservationIgnored var anchorOffset: CGFloat = 0
    @ObservationIgnored var pinned = true
    @ObservationIgnored var windowStartID: String?
    @ObservationIgnored var mountedIDs: [String] = []
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var width: CGFloat = 0
    @ObservationIgnored var fontFingerprint: [Int] = []
}

@MainActor
private enum TimelinePresentationStore {
    private static var entries: [UUID: TimelinePresentation] = [:]
    private static var order: [UUID] = []

    static func entry(for id: UUID) -> TimelinePresentation {
        order.removeAll { $0 == id }
        order.append(id)
        if let entry = entries[id] { return entry }
        let entry = TimelinePresentation()
        entries[id] = entry
        if order.count > 32 { entries.removeValue(forKey: order.removeFirst()) }
        return entry
    }
}

private struct TimelineBlockIDKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var timelineBlockID: String {
        get { self[TimelineBlockIDKey.self] }
        set { self[TimelineBlockIDKey.self] = newValue }
    }
}


/// Confirms the rendered conversation, not a sidebar selection. AppKit visibleRect
/// only accounts for clipping; window occlusion and hidden ancestors are checked too.
/// Source: developer.apple.com/documentation/appkit/nsview/visiblerect
private struct ThreadResultReadProbe: NSViewRepresentable {
    let model: AppModel
    let threadID: UUID
    let revision: UUID?
    let hasUnread: Bool
    let canRead: Bool

    func makeNSView(context: Context) -> ResultView { ResultView() }

    func updateNSView(_ view: ResultView, context: Context) {
        view.model = model
        view.threadID = threadID
        view.revision = revision
        view.hasUnread = hasUnread
        view.canRead = canRead
        model.threadViewVisibility[view.registrationID] = (threadID, { [weak view] in
            view?.isReadableWindow == true
        })
        view.scheduleRead()
    }

    static func dismantleNSView(_ view: ResultView, coordinator: ()) {
        view.model?.threadViewVisibility[view.registrationID] = nil
        view.invalidate()
        view.model = nil
    }

    final class ResultView: NSView {
        let registrationID = UUID()
        weak var model: AppModel?
        var threadID: UUID?
        var revision: UUID?
        var hasUnread = false
        var canRead = false
        private var generation = 0
        private var observers: [any NSObjectProtocol] = []

        var isReadableWindow: Bool {
            guard NSApp.isActive, !NSApp.isHidden, let window,
                  window.isVisible, !window.isMiniaturized,
                  window.occlusionState.contains(.visible),
                  !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty else { return false }
            return true
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let center = NotificationCenter.default
            for name in [NSApplication.didBecomeActiveNotification,
                         NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRead() }
                })
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func invalidate() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            generation += 1
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleRead()
        }

        override func layout() {
            super.layout()
            scheduleRead()
        }

        func scheduleRead() {
            generation += 1
            let expectedGeneration = generation
            let expectedRevision = revision
            let expectedThreadID = threadID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration,
                      self.hasUnread, self.canRead, self.isReadableWindow,
                      let id = expectedThreadID else { return }
                self.model?.markRead(id, revision: expectedRevision)
            }
        }
    }
}
