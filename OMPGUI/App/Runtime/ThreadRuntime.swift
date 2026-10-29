import AppKit
import Foundation
import SwiftUI

/// One timeline row. A class, so a streaming row redraws without re-diffing the whole thread.
@MainActor
@Observable
final class TimelineEntry: Identifiable {
    enum Kind {
        case user
        case assistant
        case reasoning
        case tool
        case plan
        case todos
        case notice
        case turnEnd
    }

    let id: String
    /// Fixed for the row's lifetime, so grouping never observes streaming content.
    let kind: Kind
    let turnID: UUID?
    var item: TimelineItem {
        didSet { if oldValue != item { onChange?() } }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    init(_ item: TimelineItem) {
        id = item.id
        turnID = item.turnID
        kind = switch item.content {
        case .user: .user
        case .assistant: .assistant
        case .reasoning: .reasoning
        case .tool: .tool
        case .plan: .plan
        case .todos: .todos
        case .notice: .notice
        case .turnEnd: .turnEnd
        }
        self.item = item
    }
}

/// Entries compare by identity: a row observes its entry's content itself, so the same
/// object always means the same row, and a rebuilt timeline can skip the rows whose
/// entries it already shows.
extension TimelineEntry: Equatable {
    nonisolated static func == (lhs: TimelineEntry, rhs: TimelineEntry) -> Bool {
        lhs === rhs
    }
}

/// A message from earlier in the chat that the next message talks about: shown as a
/// chip in the chat box, sent ahead of the typed words as a quote.
struct ReplyQuote: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String

    var excerpt: String {
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return "" }
        let collapsed = line.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > 72 else { return collapsed }
        return String(collapsed.prefix(72)) + "…"
    }
}

extension ReplyQuote {
    /// A sent message read back into the quotes it led with and the words after them,
    /// the reverse of `ComposerDraft.outgoingText`: each `> ` block up to a blank line
    /// that no further `>` line follows. A leading slash command stays with the words.
    /// A message with no leading quote comes back whole.
    nonisolated static func peel(_ text: String) -> (quotes: [ReplyQuote], body: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var command: String?
        if let first = lines.first, first.hasPrefix("/"), lines.count > 2, lines[1].isEmpty, lines[2].hasPrefix(">") {
            command = first
            lines.removeFirst(2)
        }
        var quotes: [ReplyQuote] = []
        var index = 0
        while index < lines.count, lines[index].hasPrefix(">") {
            var block: [String] = []
            while index < lines.count, lines[index].hasPrefix(">") {
                var line = lines[index].dropFirst()
                if line.hasPrefix(" ") { line = line.dropFirst() }
                block.append(String(line))
                index += 1
            }
            quotes.append(ReplyQuote(text: block.joined(separator: "\n")))
            // One blank line separates a block from the next; a blank line before the words stays for the trim below.
            if index + 1 < lines.count, lines[index].isEmpty, lines[index + 1].hasPrefix(">") {
                index += 1
            }
        }
        guard !quotes.isEmpty else { return ([], text) }
        var body = lines[index...].joined(separator: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }
        if let command { body = body.isEmpty ? command : command + " " + body }
        return (quotes, body)
    }
}

/// The slash command or skill the message leads with, picked from the suggestions:
/// a chip in the chat box, the first word of what goes out.
struct DraftCommand: Equatable, Sendable {
    var name: String
    var detail: String
    var isBuiltIn: Bool
}

struct ComposerDraft: Equatable {
    let id = UUID()
    var text = ""
    var attachments: [Attachment] = []
    var quotes: [ReplyQuote] = []
    var command: DraftCommand? = nil

    var isEmpty: Bool {
        attachments.isEmpty && command == nil && !text.contains { !$0.isWhitespace }
    }

    /// What actually goes out: every quote as a markdown blockquote, a blank line, then
    /// the typed words.
    var outgoingText: String {
        let body: String = {
            guard !quotes.isEmpty else { return text }
            let blocks = quotes.map { quote in
                quote.text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
            }
            return blocks.joined(separator: "\n\n") + "\n\n" + text
        }()
        guard let command else { return body }
        let head = "/\(command.name)"
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return head }
        if quotes.isEmpty { return head + " " + body }
        return head + "\n\n" + body
    }
}

/// A prompt mid-edit (a queued follow-up, or a message already sent): which one, and its
/// text and files as edited so far. A class, so the rows watching which prompt is open
/// never re-render on keystrokes.
@MainActor
@Observable
final class PromptEdit {
    let id: UUID
    var text: String
    var attachments: [Attachment]

    init(id: UUID, text: String, attachments: [Attachment]) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }

    var isEmpty: Bool {
        attachments.isEmpty && !text.contains { !$0.isWhitespace }
    }
}

enum RuntimePhase: Equatable {
    case idle
    case starting
    case running
}

/// Owns a thread's live state: its timeline, its provider session and its pending requests.
@MainActor
@Observable
final class ThreadRuntime {
    let threadID: UUID

    private(set) var entries: [TimelineEntry] = [] {
        didSet {
            itemPositionsInvalid = true
            entriesStructureRevision &+= 1
            let populated = entries.contains { !$0.item.hasNothingToRead && $0.kind != .todos }
            if hasEntries != populated { hasEntries = populated }
        }
    }
    /// Empty-state layout observes only this boundary, never every arriving entry.
    private(set) var hasEntries = false
    @ObservationIgnored private(set) var entriesStructureRevision: UInt64 = 0

    private func bindEntry(_ entry: TimelineEntry) {
        entry.onChange = { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.markTurnDirty(entry.turnID)
        }
        markTurnDirty(entry.turnID)
    }

    private func replaceEntries(_ updated: [TimelineEntry]) {
        let kept = Set(updated.map(\.id))
        for entry in entries where !kept.contains(entry.id) { markTurnDirty(entry.turnID) }
        for entry in updated { bindEntry(entry) }
        entries = updated
        latestTodoEntry = entries.last { $0.kind == .todos }
    }

    private func removeEntries(where remove: (TimelineEntry) -> Bool) {
        var removesTodo = false
        entries.removeAll { entry in
            guard remove(entry) else { return false }
            markTurnDirty(entry.turnID)
            removesTodo = removesTodo || entry.kind == .todos
            return true
        }
        if removesTodo { latestTodoEntry = entries.last { $0.kind == .todos } }
    }

    private func insertEntry(_ entry: TimelineEntry, at index: Int) {
        bindEntry(entry)
        entries.insert(entry, at: index)
        if entry.kind == .todos { latestTodoEntry = entries.last { $0.kind == .todos } }
    }

    private(set) var latestTodoEntry: TimelineEntry?
    /// The native list's presentation, retaining completed work after a clear.
    private var nativeTodoSteps: [TodoStep]?
    @ObservationIgnored private var nativeTodoSnapshot: TodoSnapshot?
    var todoSteps: [TodoStep] {
        if let nativeTodoSteps { return nativeTodoSteps }
        guard let entry = latestTodoEntry, case .todos(let steps) = entry.item.content else { return [] }
        return steps
    }
    private(set) var turns: [TurnRecord] = [] {
        // A turn leaving the thread (reverted) takes any edit of its message, and its
        // cached diff, with it.
        didSet {
            let previous = Dictionary(oldValue.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for turn in turns where previous[turn.id] != turn { markTurnDirty(turn.id) }
            if let edit = messageEdit, !turns.contains(where: { $0.id == edit.id }) { messageEdit = nil }
            if turns.count < oldValue.count {
                let kept = Set(turns.map(\.id))
                for turn in oldValue where !kept.contains(turn.id) { turnDiffs.removeValue(for: turn.id) }
            }
            let latest = turns.last(where: { $0.latestTokenSpend != nil })?.latestTokenSpend
                .flatMap(PromptCacheUsage.init)
            if latestPromptCacheUsage != latest { latestPromptCacheUsage = latest }
            app?.usageRevision &+= 1
        }
    }
    private(set) var usage: ContextUsage?
    private(set) var latestPromptCacheUsage: PromptCacheUsage?
    /// Forwarded context from another thread, kept with the thread's history rather than
    /// as a message: the source's prompt goes out ahead of the first ordinary message
    /// (see `startTurn`), and never becomes part of the user's own message or draft.
    private(set) var continuation: ThreadContinuation?
    private(set) var phase: RuntimePhase = .idle {
        didSet {
            if (oldValue == .idle) != (phase == .idle) { app?.updateTaskSleepPrevention() }
            // Only a turn handed to its session is watched: starting has its own steps
            // (folders, a CLI update, the session's launch) that are no session gone quiet.
            if oldValue != .running, phase == .running { startQuietWatchdog() }
            if phase != .running { stopQuietWatchdog() }
        }
    }
    /// Whole minutes the running turn has gone without a word from its session, once that
    /// passes five (see `watchQuiet`); nil while it is talking. The working line says so.
    private(set) var quietMinutes: Int?
    /// System uptime at the session's last event, which stands still while the Mac sleeps,
    /// so a night's sleep never counts as a turn gone quiet.
    @ObservationIgnored private var lastSessionEventUptime: TimeInterval = 0
    @ObservationIgnored private var quietWatchdog: Task<Void, Never>?
    private(set) var isReverting = false
    /// Do not replace a damaged document unless its original bytes were kept.
    private(set) var historyRecoveryBlocked = false
    private var historyRecoveryMessage: String {
        Chrome.localized("OMP GUI could not preserve unreadable chat files. Sending and saving are paused. Check the library's disk space and permissions, then reopen this chat.")
    }
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var questions: [QuestionRequest] = []
    /// Live forms belong to this conversation; there is no cross-session index or
    /// resolved-request archive. Windows displaying it share the same draft.
    private var interactions: [UUID: OMPInteraction] = [:]
    var pendingInteractionStatus: ThreadActivityStatus? {
        if !approvals.isEmpty { return .approval }
        if !questions.isEmpty { return .question }
        return nil
    }
    private(set) var backgroundTasks: [String] = [] {
        didSet {
            if oldValue.isEmpty != backgroundTasks.isEmpty { app?.updateTaskSleepPrevention() }
        }
    }
    private(set) var ompActivity: OMPActivity? {
        didSet {
            if oldValue?.hasWork != ompActivity?.hasWork { app?.updateTaskSleepPrevention() }
        }
    }
    private(set) var ompCapabilities = OMPCapabilities()
    private(set) var ompExtensionState = OMPExtensionState()
    private(set) var ompLoginLinks: [OMPLoginLink] = []
    private(set) var pendingOMPEditorText: String?
    @ObservationIgnored private var lastOMPEditorText: String?
    private(set) var explicitFileContext: FileQuestionContext?
    @ObservationIgnored private var nativeDetailConsumers = Set<String>()
    private(set) var ompContext = OMPContextSnapshot()
    private(set) var ompContextIsCached = false
    @ObservationIgnored private var ompContextSessionFile: String?
    private(set) var ompRunOptions = OMPRunOptionsSnapshot()
    private(set) var ompGoal = OMPGoalSnapshot()
    private(set) var ompDebug = OMPDebugSnapshot()

    func prepareDebugRun(_ runID: String) async {
        guard let run = ompDebug.runs.first(where: { $0.id == runID }) else { return }
        let missing = run.records.filter { $0.details == nil && $0.phase != "state" && $0.phase != "begin" }
        guard !missing.isEmpty else { return }
        let recovered = await OMPDebugHistory.read(sessionFile: run.sessionFile, records: missing)
        guard !Task.isCancelled, ompDebug.runs.contains(where: { $0.id == runID && $0.sessionFile == run.sessionFile }) else { return }
        let values = recovered.mapValues(\.details)
        var summaries: [String: OMPDebugSession] = [:]
        for record in missing {
            guard let value = recovered[record.id] else { continue }
            if var summary = value.session ?? record.session {
                summary.cwd = summary.cwd ?? value.cwd; summaries[record.id] = summary
            }
        }
        if ompDebug.recoverDetails(runID: runID, values: values, summaries: summaries) {
            _ = (session as? OMPSession)?.debugSnapshot.recoverDetails(runID: runID, values: values, summaries: summaries)
            saveRevision += 1; scheduleSave()
        }
    }
    var ompGoalBudgetDraft = ""
    var ompGoalComposerError: String?
    var ompGoalComposerWorking = false
    var ompGoalControlWorking = false
    var ompGoalComposerSubmission: OMPGoalComposerSubmission?
    var ompSideQuestion = OMPSideQuestionSnapshot() {
        didSet {
            if oldValue.hasLiveWork != ompSideQuestion.hasLiveWork { app?.updateTaskSleepPrevention() }
        }
    }
    let sideQuestionDraft = OMPSideQuestionDraft()
    @ObservationIgnored var sideQuestionSubmission: (id: String, text: String)?
    private var nativeOperationCount = 0
    /// Read-only context refreshes block recycling and branching, but not the
    /// context panel's controls: a read changes nothing those actions could race.
    private var nativeRefreshCount = 0
    @ObservationIgnored private var branchedAttachments: [Attachment] = []
    var hasNativeWork: Bool { ompActivity?.hasWork == true }
    var nativeWorkDescription: String? {
        switch ompActivity?.phase {
        case .queued: Chrome.localized("OMP is processing queued messages.")
        case .compacting: Chrome.localized("OMP is compacting context.")
        case .retrying: Chrome.localized("OMP is retrying the request.")
        case .background: Chrome.localized("OMP background work")
        case .responding: Chrome.localized("OMP is processing a request.")
        default: nil
        }
    }

    /// Used only for automatic recycling. An explicit Stop/Quit still owns the
    /// right to stop work. Unknown native state never grants this permission.
    var canRecycleSession: Bool { canRecycleOutsideSideQuestion && !ompSideQuestion.blocksRecycling }

    private var canRecycleOutsideSideQuestion: Bool {
        phase == .idle && !isCLIStarting && !isReverting && nativeOperationCount == 0 && nativeRefreshCount == 0 && !isLoadingHistory && finishingTurnID == nil
            && providerHistoryOperation == nil && pendingSend == nil && !followUps.contains { $0.ompState?.isTerminal != true }
            && approvals.isEmpty && questions.isEmpty && backgroundTasks.isEmpty
            && !hasWorkingHelpers && !isHydraMerging && !isWaitingForLimit
            && (ompActivity.map { $0.canRecycle || ($0.stopped && session == nil) } ?? (session == nil))
    }

    @discardableResult
    func recycleSessionIfIdle() -> Bool {
        guard canRecycleOutsideSideQuestion else { return false }
        if let snapshot = unsavedSnapshot(), !DiskWriter.shared.writeThreadSynchronously(snapshot) {
            saveNow()
            return false
        }
        if let native = session as? OMPSession, ompSideQuestion.blocksRecycling {
            // A terminal record precedes its sidecar write. EOF lets OMP drain
            // it while this runtime continues to receive persistence failures.
            if !ompSideQuestion.hasLiveWork, ompSideQuestion.persistenceError == nil {
                _ = native.beginSideQuestionDrain()
            }
            return false
        }
        guard !ompSideQuestion.blocksRecycling else { return false }
        stopSession()
        return true
    }
    private(set) var turnStartedAt: Date?
    /// Bumped whenever the thread's files may differ from what the last diff saw. The diff
    /// cache and the change stats are keyed by it, so the entries of an old revision are
    /// unreachable and go with it rather than lingering until 64 newer ones push them out.
    private(set) var diffRevision = 0 {
        didSet {
            revisionDiffs = RecentCache(limit: 4)
            changeStatsRevision = nil
        }
    }
    /// Queued steering prompts. Enqueued while a turn runs, each one is sent as a
    /// direct user chat message once the running turn finishes, in order.
    /// True from init until a history that was not prefetched has been decoded and installed.
    private(set) var isLoadingHistory = false
    private(set) var followUps: [FollowUpPrompt] = [] {
        // A follow-up leaving the queue (sent, deleted) takes any edit of it with it.
        didSet {
            if let edit = followUpEdit, !followUps.contains(where: { $0.id == edit.id }) { followUpEdit = nil }
        }
    }
    var visibleFollowUps: [FollowUpPrompt] { followUps.filter(\.isVisibleInDeliveryPanel) }
    private var withdrawingFollowUpIDs: Set<UUID> = []
    private(set) var hydraMerges: [HydraMergeRecord] = []
    /// The queued follow-up being edited, with the edit so far. Lives on the thread rather
    /// than in the editor, so leaving the thread mid-edit and coming back finds the editor
    /// open where it was left.
    var followUpEdit: PromptEdit?
    /// Whether the queue tab's rows are folded away under its title. Lives on the thread
    /// like `followUpEdit` does: the tab leaves the screen whenever the queue empties, and
    /// a fold the reader set must not spring back open on the next queued prompt.
    var followUpsCollapsed = false

    /// Counts the turns that start on their own — a queued follow-up, a head's report, the
    /// budget note — rather than on a message the reader just sent. The timeline compares it
    /// with the value it last saw, so an unattended turn never drags a reader who scrolled up
    /// down to the end. Never observed: the timeline reads it directly.
    @ObservationIgnored private(set) var autoStartedTurnToken = 0
    /// The sent message being edited (by its turn), the same way.
    var messageEdit: PromptEdit?

    var draft = ComposerDraft() {
        didSet {
            let isEmpty = draft.isEmpty
            if isEmpty != draftIsEmpty { draftIsEmpty = isEmpty }
        }
    }
    /// `draft.isEmpty`, flipped only when it changes: the menu bar's commands read this
    /// rather than the draft, so a keystroke never re-evaluates the command tree.
    private(set) var draftIsEmpty = true
    /// Shared by all editors for this chat; no microphone or asset request until a click.
    @ObservationIgnored lazy var dictation = ComposerDictation()
    var isDictating = false
    var isTerminalVisible = false {
        // Opened, the terminal takes the keyboard (see `TerminalHost`); a thread switched to
        // with its terminal already open leaves the keyboard where it is.
        didSet { if isTerminalVisible, !oldValue { terminalFocusLocation = .bottom } }
    }
    @ObservationIgnored var terminalFocusLocation: TerminalLocation?
    /// True while the terminal's divider is held: the pane's height follows the pointer, and the chat's panels follow it with no spring until it is let go.
    var isTerminalResizing = false
    var isDiffVisible = false
    /// Which corner of the chat pane the helper panel this thread spawned sits in.
    var subagentPanelDock: PanelDockCorner = .bottomTrailing
    /// The same for the Hydra panel.
    var hydraPanelDock: PanelDockCorner = .bottomTrailing
    /// The head whose timeline the Hydra panel shows.
    var hydraSelectedHeadID: UUID?
    /// The head popped out of the Hydra panel into a second panel of its own, if any, and
    /// the corner that panel sits in.
    var hydraPoppedHeadID: UUID?
    var hydraPoppedPanelDock: PanelDockCorner = .bottomLeading
    /// Heads whose automatic panel the user closed, so they stay in the team panel while
    /// the others fill the room.
    var hydraAutoPopHeld: Set<UUID> = []
    /// The order the user gave the panels inside their corners by dragging; a panel not
    /// listed comes after the listed ones, in the built-in order: helper, team, popped
    /// head, usage, heads popped out automatically.
    var panelStackOrder: [FloatingPanelID] = []
    /// Heads whose automatic panel the user dragged: they keep that corner and count
    /// against its room.
    var hydraAutoPanelDocks: [UUID: PanelDockCorner] = [:]
    /// The Hydra panel was dismissed; the next head to start brings it back.
    var isHydraPanelHidden = false
    /// Heads by the tool row that stands for them in this timeline, so the row can show
    /// who was sent out.
    private(set) var hydraToolHeads: [String: [UUID]] = [:]
    private(set) var nativeAgentHistoryLoading = false
    private(set) var nativeAgentHistoryIssue: String?
    @ObservationIgnored private var nativeAgentHistoryRead: Task<Void, Never>?
    @ObservationIgnored private var nativeAgentHistoryReadID: UUID?
    @ObservationIgnored private var nativeAgentHistorySnapshot: (file: String, fingerprint: String)?
    private var nativeAgentContext = OMPAgentJournal.ContextReport()
    @ObservationIgnored private var nativeAgentContextRevision: UInt64 = 0
    @ObservationIgnored private var nativeAgentContextRead: (id: UUID, file: String, observationID: String?, task: Task<OMPAgentJournal.ContextReport, Error>)?
    @ObservationIgnored private var nativeJournalDecoder: OMPEventDecoder?
    @ObservationIgnored private var nativeJournalEntries = Set<String>()
    @ObservationIgnored private var nativeJournalDate: Date?
    @ObservationIgnored private var nativeJournalLastDate: Date?
    @ObservationIgnored private var nativeJournalEntryID: String?
    @ObservationIgnored private var nativeJournalNoticeIndex = 0
    @ObservationIgnored private var nativeUntimedTurns = Set<UUID>()
    /// Reports from Tivano-run heads waiting for the lead to be idle.
    @ObservationIgnored private var hydraPendingReports: [HydraReport] = []
    /// The reports' turn is on its way (see `flushHydraReports`): a head finishing in the
    /// meantime joins it rather than starting a turn of its own.
    @ObservationIgnored private var hydraFlushScheduled = false
    /// The landing under way in this lead's checkout (see `AppModel.landHydraHead`); the
    /// next head's waits behind it, so two never write the same files at once.
    @ObservationIgnored var hydraLanding: Task<Void, Never>?
    /// Delegations still in flight: the heads of each batch report together.
    @ObservationIgnored private var hydraBatches: [UUID: HydraBatch] = [:]
    /// Delegated tasks past the pair's limit, sent out as heads finish.
    @ObservationIgnored private var hydraWaiting: [(delegation: HydraDelegation, batchID: UUID, queuedAt: Date)] = [] {
        didSet { hydraWaitingCount = hydraWaiting.count }
    }
    /// How many delegated tasks wait for a head to finish before they go out, for the
    /// heads popover to say so: a team held to the cap is not a team that lost its tail.
    private(set) var hydraWaitingCount = 0
    /// The per-request budgets behind a lead's delegation blocks: rounds of heads gone
    /// out, refusals given a turn of their own, and a dropped block's notice waiting to
    /// ride on the lead's next turn. A message of the user's own starts the count over;
    /// a turn carrying head reports or a refusal notice continues the same request.
    @ObservationIgnored private var hydraBudget = HydraDelegationBudget()
    /// The delegation block being read as the reply streams: which turn and row it
    /// belongs to, the batch its heads go out under, and how many entries have gone
    /// out so far. One block per turn: the first row with one claims it.
    @ObservationIgnored private var hydraStream: (turnID: UUID, entryID: String, batchID: UUID, sent: Int)?
    /// The reader holding that block's place between flushes (see
    /// `HydraDelegationStreamParser`). Reset wherever `hydraStream` is, so the next block is
    /// read by a parser that starts where the block does.
    @ObservationIgnored private var delegationParser: HydraDelegationStreamParser?
    /// A Tivano-run head's time for one turn (see `HydraBudget`): past it, the head is
    /// stopped and its next turn is its report.
    @ObservationIgnored private var headBudget: Task<Void, Never>?
    @ObservationIgnored private var headBudgetSpent = false
    @ObservationIgnored private var headReportsNext = false
    /// The team's finished work is on its way to the remote (see `AppModel.autoMergeHydraWork`).
    var isHydraMerging = false {
        didSet {
            if oldValue != isHydraMerging { app?.updateTaskSleepPrevention() }
            if !isHydraMerging { app?.publishDeferredResult(threadID) }
        }
    }
    /// This chat's finished work is waiting for another chat's merge to finish, and goes
    /// right after it (see `AppModel.autoMergeHydraWork`).
    var isHydraMergeQueued = false
    /// A quiet retry of a merge that failed in a way that clears by itself is scheduled.
    var hasHydraMergeRetryPending = false
    /// What the merge is doing right now, in words, for the timeline: gathering the
    /// team's files, writing the commit, pushing, opening the merge request, merging.
    var hydraMergeStage: String?
    /// The stage under way, for the pill's track of dots (see `HydraMergeStage`); nil
    /// while no merge runs.
    var hydraMergeStep: HydraMergeStage?
    /// When the merge under way began, so the timeline can show how long it has been at it.
    var hydraMergeStartedAt: Date?
    /// The id the merge's outcome note will land under, chosen when the merge starts. The
    /// timeline draws its merging pill as the block with this id, so the note takes the
    /// pill's place under the same identity and the pill morphs into the merged report
    /// rather than being replaced (see `DisplayBlock.merging`).
    var hydraMergeNoteID: String?
    /// A head's progress while it runs (its last tool, its tool count, its spend), kept
    /// here rather than on the thread record: the provider reports it many
    /// times a second, and a write to a thread re-renders everything that lists threads.
    /// Only the panel row that shows this head follows these; they land on the record
    /// once the head finishes (see `AppModel.finishHydraHead`).
    var hydraActivity: String?
    var hydraToolCalls = 0
    var hydraTokens = 0
    /// When the head last did anything (a tool, a word of its reply or its reasoning),
    /// and how many file edits its tools have made: what the watchdog reads to tell a
    /// head that is thinking from one that has stalled (see `AppModel.startHydraWatchdog`).
    /// Not observed: it moves with every flush of every head, and the one view that
    /// reads it (the lead's working pill) is redrawn by the watchdog's label instead.
    @ObservationIgnored var hydraLastEventAt: Date?
    var hydraEditCount = 0
    /// How long the head has been quiet, in seconds; zero before it has done anything.
    var hydraIdleSeconds: TimeInterval { hydraLastEventAt.map { Date.now.timeIntervalSince($0) } ?? 0 }

    private struct HydraBatch {
        var pending: Set<UUID>
        var reports: [HydraReport] = []
    }
    var diffSelection: UUID?
    /// The view the changes popover should open on: a tool row's label, a turn's Review
    /// button, or nil for the changes tab. Held weakly so a row that leaves the screen
    /// never keeps a view alive.
    @ObservationIgnored var diffAnchor: WeakView?
    /// The side of `diffAnchor` the popover hangs from. Anchors are plain, unflipped
    /// views, so `.minY` is below (a tool row, as its chevron promises) and `.maxY` is
    /// above (a Review button, at the foot of its turn).
    @ObservationIgnored var diffAnchorEdge: NSRectEdge = .maxY
    /// Bumped by `showDiff(on:edge:turn:focusEdits:)`, so the popover moves to the new
    /// anchor even when it is already open somewhere else.
    private(set) var diffOpenRequest = 0
    /// The edits a tapped tool row asked to see, patches included. The popover leaves
    /// their cards expanded and scrolls to the first of them, and falls back to a patch
    /// when the turn's diff has nothing for it; empty for the tab and the Review button,
    /// which open the whole selection.
    private(set) var diffFocusEdits: [FileEdit] = []
    /// Bumped whenever `diffFocusEdits` changes, so the popover reloads its file list
    /// even when a second row names the same file with a different patch.
    private(set) var diffFocusRevision = 0

    /// Opens the changes popover on `anchor` (a tool row or a Review button), hanging
    /// from its `edge`, showing `turn`'s changes, or the whole thread's for nil.
    /// `focusEdits` are the tapped row's own edits, so the file it reports is what the
    /// popover opens on even when the turn's diff cannot show it yet.
    func showDiff(on anchor: NSView, edge: NSRectEdge = .maxY, turn: UUID?, focusEdits: [FileEdit] = []) {
        diffAnchor = WeakView(anchor)
        diffAnchorEdge = edge
        if diffSelection != turn { diffSelection = turn }
        setDiffFocus(focusEdits)
        if !isDiffVisible { isDiffVisible = true }
        diffOpenRequest += 1
    }

    /// Drops the edits a tapped tool row focused, so the openers that show a whole
    /// selection (the changes tab, ⌘D) never open on some earlier row's file.
    func clearDiffFocus() {
        setDiffFocus([])
    }

    private func setDiffFocus(_ edits: [FileEdit]) {
        let focus = edits.filter { !$0.path.isEmpty }
        guard focus != diffFocusEdits else { return }
        diffFocusEdits = focus
        diffFocusRevision += 1
    }

    /// The changes tab, the toolbar button, ⌘D and the palette: they show the whole
    /// selection, so any file a tapped tool row focused is dropped first and the
    /// popover opens at the top of the list rather than on some earlier row's file.
    func toggleDiff() {
        clearDiffFocus()
        if !isDiffVisible { diffAnchor = nil }
        isDiffVisible.toggle()
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var session: (any ProviderSession)?
    @ObservationIgnored private var sessionsAwaitingReplacement: [any ProviderSession] = []
    @ObservationIgnored private var crashInterruptedTurnIDs: Set<UUID> = []
    @ObservationIgnored private var attemptedCodexCrashRecovery = false
    @ObservationIgnored private var providerHistoryOperation: Task<Void, Never>?
    /// A session being started ahead of the first message (`warmSession`).
    @ObservationIgnored private var warmup: Task<Void, Never>?
    @ObservationIgnored private var sessionStartup: Task<Void, Error>?
    // User messages wait behind the brief while the head's route and copy are prepared.
    @ObservationIgnored var hydraStartupPending = false
    /// The session's ID while no message has gone through it. The provider has nothing
    /// to resume under such an ID: a session warmed while the first message was typed and
    /// replaced before it went (a setting changed the launch) was resumed as "no
    /// conversation found", and the chat was told its agent had lost a conversation that
    /// never was. So the ID reaches the thread with the first message, and a session
    /// replaced before then is followed by one that starts fresh.
    @ObservationIgnored private var unsentSessionID: String?
    @ObservationIgnored private var lastFlushAt = ContinuousClock.now - .seconds(1)
    @ObservationIgnored private var sessionSignature: SessionSignature?
    /// Whether the anti-slop policy has already gone out as a fallback prefix on this
    /// session. The providers that cannot keep it in a system prompt get it once, with
    /// the first turn that carries text; a restarted, retried or explicitly compacted
    /// session takes it again (see `releaseSession`, `compact`).
    @ObservationIgnored private var antiSlopFallbackSent = false
    /// Whether the forwarded continuation has already gone out as a prefix on this
    /// session. Delivered once, with the first ordinary message that goes through the
    /// session; a restarted, retried or explicitly compacted session takes it again
    /// (see `releaseSession`, `compact`).
    @ObservationIgnored private var continuationSent = false
    /// Which session the runtime is listening to. Every session made carries the count it
    /// was made under, and its events are dropped once the count has moved on: a CLI that
    /// closes long after it was let go used to end the turn that replaced it, take down
    /// the live session with it and leave its process running with nothing holding it.
    @ObservationIgnored private var sessionEpoch = 0
    /// Whether `ensureSession` is waiting on a session's `start()`. A session that exits
    /// then is reported by that throwing, and `ensureSession` starts over where it can,
    /// so its exit event neither lets the session go nor fails the turn.
    @ObservationIgnored private var isStartingSession = false
    /// Claude started a turn of its own (a background task it launched finished) while the
    /// previous turn was still being finalized: its events wait here and are replayed into
    /// a turn of their own once `finishTurn` is done with the old one.
    @ObservationIgnored private var opensTurnAfterFinish = false
    @ObservationIgnored private var deferredBackgroundTurnEvents: [ProviderEvent] = []
    /// The turn being finalized, claimed before the first suspension: a completion and an
    /// exit can both arrive for one turn, and the second must not finalize it again.
    @ObservationIgnored private var finishingTurnID: UUID?
    @ObservationIgnored private var finishingGeneration: UUID?
    @ObservationIgnored private var runtimeTurnGeneration: UInt64 = 0
    @ObservationIgnored private var runtimeOwnerTurnID: UUID?
    @ObservationIgnored private var entryIndex: [String: TimelineEntry] = [:]
    @ObservationIgnored private var pendingDeltas: [String: PendingDelta] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var streamByteLengths: [String: Int] = [:]
    @ObservationIgnored private var pendingFlushBytes = 0
    /// Bumped by anything that changes what `saveNow` writes, so the periodic save
    /// during a quiet stretch finds nothing new and does no work.
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var lastSavedRevision = 0
    @ObservationIgnored private var turnRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var savedTurnRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var nextTurnRevision: UInt64 = 0
    @ObservationIgnored private var itemPositions: [String: Double] = [:] {
        didSet { itemPositionsInvalid = true }
    }
    @ObservationIgnored private var itemPositionsInvalid = true
    @ObservationIgnored private var installingHistory = false

    private func markTurnDirty(_ id: UUID?) {
        guard !installingHistory else { return }
        saveRevision += 1
        guard let id else { return }
        nextTurnRevision &+= 1
        turnRevisions[id] = nextTurnRevision
    }

    @ObservationIgnored private var saveRetryTask: Task<Void, Never>?
    @ObservationIgnored private var saveFailures = 0
    @ObservationIgnored private var saveNoticeID: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var historyLoad: Task<Void, Never>?
    @ObservationIgnored private var persistenceEnabled = true
    @ObservationIgnored private var currentTurnID: UUID? {
        didSet {
            guard let currentTurnID, currentTurnID != oldValue else { return }
            runtimeTurnGeneration &+= 1
            runtimeOwnerTurnID = currentTurnID
            // A new turn supersedes any suspended finalizer's runtime ownership.
            finishingTurnID = nil
            finishingGeneration = nil
            closingTurnID = nil
        }
    }
    /// The turn being closed (see `finishTurn`): its id is taken out of `currentTurnID`
    /// first, and its diffs are then waited for. An event landing in that wait (a late
    /// tool result, a notice, a Hydra note) still belongs to the turn; filed under no turn
    /// it split the turn's rows into two blocks with one id, and the second, the running
    /// tail, stopped drawing.
    @ObservationIgnored private var closingTurnID: UUID?
    /// The pair whose heads-provider fallback was already noted in this timeline.
    @ObservationIgnored private var hydraFallbackNoted: UUID?
    /// The turn a new row is filed under.
    private var turnIDForNewRows: UUID? { currentTurnID ?? closingTurnID }
    /// The provider's latest diff and resume anchor for the running turn. Codex re-sends its
    /// whole turn diff on every file change and Claude names an anchor per message; both land
    /// on the turn record once, as the turn finishes, since every write to `turns` re-runs
    /// the whole timeline body.
    @ObservationIgnored private var currentProviderDiff: String?
    @ObservationIgnored private var currentProviderAnchor: String?
    @ObservationIgnored private var interruptWatchdog: Task<Void, Never>?
    /// The CLI version a message was last sent again at after the CLI said it was too old
    /// for the model, per provider: one resend per version, so a CLI that is still too old
    /// after its update says so rather than trying again forever.
    @ObservationIgnored private var cliResendVersions: [ProviderKind: String] = [:]
    /// The tree each running command tool is diffed from, by tool id, and
    /// the diffs being settled as they finish (see `watchCommand`).
    @ObservationIgnored private var commandTrees: [String: Task<CheckoutSnapshot?, Never>] = [:]
    @ObservationIgnored private var commandStarts: [String: Date] = [:]
    /// A returned native tool can still own a running background job. Its known
    /// before-tree remains valid until OMP completes the whole run.
    @ObservationIgnored private var nativeBackgroundCommands: [String: String] = [:]
    @ObservationIgnored private var commandSettles: [String: Task<Void, Never>] = [:]
    /// Commands that `cd` into another checkout first (an agent's own worktree, a sibling
    /// repository): what each is diffed from, by tool id (see `watchForeignCommand`).
    @ObservationIgnored private var foreignCommandBases: [String: Task<ForeignBase?, Never>] = [:]
    /// The last tree captured in each such checkout this turn, by repository root, and
    /// every root this thread's commands have worked in, so a new turn snapshots them
    /// before its first command can write there.
    @ObservationIgnored private var foreignTrees: [String: Task<CheckoutSnapshot?, Never>] = [:]
    @ObservationIgnored private var foreignRoots: Set<String> = []
    /// Snapshots run one after another: each is several git processes over the whole
    /// checkout, and a turn can have many commands in flight at once.
    @ObservationIgnored private var treeCaptures: Task<CheckoutSnapshot?, Never>?
    /// The tree a command left behind, with the count below as it stood when it was taken.
    /// While that count has not moved, nothing can have changed the working tree since, so
    /// the next command takes it as its own "before" and snapshots nothing.
    @ObservationIgnored private var settledTree: (tree: CheckoutSnapshot, epoch: Int)?
    /// The last tree any command of this turn finished capturing, whatever ran since: a
    /// command starting later than that is diffed from it when no settled tree stands,
    /// rather than from a snapshot started alongside it that the command could outrun.
    @ObservationIgnored private var latestTree: CheckoutSnapshot?
    /// Bumped by anything that could write a file: a command starting, a tool that edits.
    @ObservationIgnored private var treeEpoch = 0
    /// The row a turn's todo list lives on, so each update finds it without scanning the
    /// timeline.
    @ObservationIgnored private var todosEntryID: String?
    /// Paths this turn has touched so far, kept current as the turn's edits land, so a head
    /// that asks what the turn has already changed is answered from the turn rather than by
    /// walking the timeline. Reset with the turn (see `startTurn`, `install`, `revert`) and
    /// left holding the turn's finished set once it ends (`finishTurn`).
    @ObservationIgnored private(set) var hydraCurrentTurnTouchedPaths: Set<String> = []

    private struct SessionSignature: Equatable {
        var provider: ProviderKind
        var directory: String
        var executable: URL
        var environment: [String: String]
        var launchRuntimeMode: RuntimeMode?
        var launchEffort: String?
        var launchFast: Bool?
        /// Antigravity pins model, effort, mode and plan state at launch
        /// (`--model`, `--effort`, `--mode`), so any of them restarts it.
        var launchModel: String?
        var launchInteraction: InteractionMode?
        /// Changing the team or switching Hydra restarts the session on every provider.
        var hydra: HydraLaunch?
        var hydraPairID: UUID?
        /// The anti-slop policy travels with the session, so flipping the setting
        /// restarts it and the policy in force is the one the session was made with.
        var antiSlopEnabled: Bool
        var memory: OMPMemoryConfiguration
    }

    enum DeltaKind {
        case message
        case reasoning
        case toolOutput
        case plan
    }

    private struct PendingDelta {
        var kind: DeltaKind
        var text: String
    }

    init(threadID: UUID, app: AppModel) {
        self.threadID = threadID
        self.app = app
        isLoadingHistory = true
        let prefetched = DocumentPrefetch.shared.take(threadID)
        if let prefetched { install(prefetched, prepared: true) }
        historyLoad = Task.detached(priority: .userInitiated) { [threadID] in
            // Writes are atomic and a read waits for queued ones, so a file that still will
            // not read after a few tries is damaged. Waiting on it for good left the chat
            // blank and a send hanging; it is set aside instead, never saved over.
            var decoded = prefetched ?? Storage.readRecentDocument(threadID)?.document
            var tries = 0
            while decoded == nil && tries < 3 && FileManager.default.fileExists(atPath: Storage.threadURL(threadID).path) && !Task.isCancelled {
                tries += 1
                try? await Task.sleep(for: .seconds(2))
                decoded = Storage.readRecentDocument(threadID)?.document
            }
            guard !Task.isCancelled else { return }
            var keptAt: URL?
            let unreadable = decoded == nil && Storage.documentMayExist(threadID)
            if unreadable { keptAt = Storage.setAside(threadID, moving: true) }
            let recent = decoded ?? ThreadDocument(threadID: threadID)
            if prefetched == nil { await self.install(recent, prepared: true) }
            let loaded = Set(recent.turns.map(\.id))
            let remaining = (recent.turnIndex ?? []).filter { !loaded.contains($0.id) }
            if !remaining.isEmpty {
                for attempt in 0..<3 where !Task.isCancelled {
                    if let older = Storage.readTurns(threadID, references: remaining)?.document {
                        await self.finishLoad(older)
                        return
                    }
                    if attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
                }
                guard !Task.isCancelled else { return }
                // The newer turns carry on; the next save prunes the turns its head no longer
                // lists, so the whole thread is copied aside first.
                keptAt = Storage.setAside(threadID, moving: false)
                await self.completeHistoryLoad(unreadable: keptAt, partly: true, preservationFailed: keptAt == nil)
            } else {
                await self.completeHistoryLoad(unreadable: keptAt, partly: false, preservationFailed: unreadable && keptAt == nil)
            }
        }
    }

    private func install(_ document: ThreadDocument, prepared: Bool = false) {
        installingHistory = true
        itemPositions.merge(document.itemPositions ?? [:]) { _, new in new }
        for reference in document.turnIndex ?? [] {
            savedTurnRevisions[reference.id] = reference.revision
            turnRevisions[reference.id] = turnRevisions[reference.id] ?? reference.revision
            nextTurnRevision = max(nextTurnRevision, reference.revision)
        }
        var recovered = false
        let wasDirty = saveRevision != lastSavedRevision
        var installedTurns = document.turns + turns
        if thread?.hydra?.kind == .tivano {
            hydraTokens = installedTurns.flatMap { $0.tokenSpends ?? [] }.reduce(0) { $0 + $1.totalTokens }
        }
        // Claude's older saved meter came from turn spend, not context occupancy.
        // Only a fresh report from the live CLI may populate its meter.
        if thread?.provider != .claude { usage = usage ?? document.usage }
        if thread?.provider == .omp, thread?.hydra?.kind != .native,
           ompContextSessionFile == nil, session == nil,
           let cache = document.ompContext, cache.sessionFile == thread?.providerSessionID {
            ompContext = cache.snapshot.savedSnapshot
            ompContextSessionFile = cache.sessionFile
            ompContextIsCached = true
        }
        continuation = document.continuation ?? continuation
        if thread?.provider == .omp, thread?.hydra?.kind != .native, session == nil,
           ompDebug.sessionFile == nil, let archive = document.ompDebug {
            ompDebug = OMPDebugSnapshot(archive: archive)
        }
        followUps = document.followUps.filter { !$0.isEmpty && $0.ompState != .consumed }.map { prompt in
            var prompt = prompt
            if prompt.ompState == .submitting || prompt.ompState == .accepted {
                prompt.ompState = .unknown
                prompt.deliveryError = Chrome.localized("Delivery was not observed before this conversation was reopened. The message will not be resent automatically.")
            }
            return prompt
        } + followUps
        hydraMerges = document.hydraMerges + hydraMerges
        // Thinking with no text is nothing to show or keep: Claude Code redacts its
        // reasoning and streams only empty deltas, which older builds stored as blank
        // entries. A reply of punctuation alone -- the lone "." some models punctuate a
        // pause between tool calls with -- is the same nothing. Both are dropped here and
        // never created below. Threads stored before the app flattened model prose on the
        // way in are cleaned as they are read, so no reply from any earlier build can put
        // an em dash back on screen.
        let items = TimelineItem.coalescingConsecutiveNotices(prepared ? document.items.map(\.normalizedOMPAsyncNotice)
            : document.items.filter { !$0.hasNothingToRead }.map { $0.normalizedOMPAsyncNotice.cleanedOfEmDashes })
        recovered = items != document.items || document.followUps.contains { $0.isEmpty || $0.ompState == .consumed }
        let loaded = items.map { TimelineEntry($0) }
        // Older native heads cannot resume; their spawning rows are finished history.
        let nativeToolIDs = Set(app?.children(of: threadID).compactMap { head -> String? in
            guard head.hydra?.kind == .native else { return nil }
            return head.hydra?.toolUseID
        } ?? [])
        for entry in loaded {
            entryIndex[entry.id] = entry
            switch entry.item.content {
            case .assistant(let message): recovered = recovered || message.isStreaming
            case .reasoning(let block): recovered = recovered || block.isStreaming
            case .plan(let plan): recovered = recovered || plan.state == .drafting
            default: break
            }
            endStreaming(entry)
            if case .tool(var call) = entry.item.content, call.status == .running {
                recovered = true
                call.finish(nativeToolIDs.contains(entry.id) ? .completed : .failed)
                entry.item.content = .tool(call)
            }
        }
        let installedEntries = loaded + entries
        // A card left in its sent state by a quit mid-hold goes now: its heads went out long ago.
        for entry in loaded {
            guard case .assistant(var message) = entry.item.content, HydraPrompts.hasSentDelegationBlock(in: message.text) else { continue }
            recovered = true
            message.text = HydraPrompts.withoutDelegationBlock(message.text)
            if message.text.isEmpty { message.text = "Sent out heads." }
            entry.item.content = .assistant(message)
        }
        for index in installedTurns.indices where installedTurns[index].status == .running {
            recovered = true
            crashInterruptedTurnIDs.insert(installedTurns[index].id)
            installedTurns[index].status = .interrupted
        }
        // Repair old histories in one batch. Mutating the observable arrays once per
        // missing marker repeatedly rebuilt their dirty indexes and froze long chats.
        var marked = Set<UUID>()
        var lastEntryByTurn: [UUID: Int] = [:]
        for (offset, entry) in installedEntries.enumerated() {
            guard let turnID = entry.turnID else { continue }
            lastEntryByTurn[turnID] = offset
            if entry.kind == .turnEnd { marked.insert(turnID) }
        }
        let turnOffsets = Dictionary(installedTurns.enumerated().map { ($0.element.id, $0.offset) },
                                     uniquingKeysWith: { first, _ in first })
        let positions = itemPositions.values.sorted()
        var insertedPositions: [Double: Double] = [:]
        var endings: [Int: TimelineEntry] = [:]
        for turn in document.turns.reversed() {
            guard let index = turnOffsets[turn.id], !marked.contains(turn.id),
                  let lastIndex = lastEntryByTurn[turn.id] else { continue }
            marked.insert(turn.id)
            recovered = true
            let endedAt = installedTurns[index].completedAt ?? installedEntries[lastIndex].item.date
            installedTurns[index].completedAt = endedAt
            let summary = TurnSummary(turnID: turn.id, status: installedTurns[index].status,
                duration: max(0, endedAt.timeIntervalSince(installedTurns[index].startedAt)),
                filesChanged: installedTurns[index].touchedPaths?.count ?? 0,
                additions: 0, deletions: 0, changes: nil)
            let entry = TimelineEntry(TimelineItem(turnID: turn.id, date: endedAt, content: .turnEnd(summary)))
            if let previous = itemPositions[installedEntries[lastIndex].id] {
                var lower = 0, upper = positions.count
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if positions[middle] <= previous { lower = middle + 1 } else { upper = middle }
                }
                let next = insertedPositions[previous] ?? (lower < positions.count ? positions[lower] : nil)
                let position = next.map { previous + ($0 - previous) / 2 } ?? (previous + 1)
                itemPositions[entry.id] = position
                insertedPositions[previous] = position
            }
            endings[lastIndex] = entry
            entryIndex[entry.id] = entry
        }
        var restoredEntries: [TimelineEntry] = []
        restoredEntries.reserveCapacity(installedEntries.count + endings.count)
        for (offset, entry) in installedEntries.enumerated() {
            restoredEntries.append(entry)
            if let ending = endings[offset] { restoredEntries.append(ending) }
        }
        turns = installedTurns
        replaceEntries(restoredEntries)
        installingHistory = false
        if recovered {
            for turn in document.turns { markTurnDirty(turn.id) }
            saveRevision += 1
        }
        if !recovered && !wasDirty { lastSavedRevision = saveRevision }
        if document.turnIndex == nil { saveRevision += 1 }
        if currentTurnID == nil {
            endDelegationStream()
            hydraCurrentTurnTouchedPaths = []
        } else {
            // A turn's events can arrive while its history is loading.
            for entry in entries where entry.turnID == currentTurnID {
                if case .tool(let call) = entry.item.content { recordCurrentTurnEdits(call.edits) }
            }
        }
        // Warm native sessions and mirrored workers can report state before disk
        // history arrives. Persist that state after the prepend, including clears.
        if let nativeTodoSnapshot {
            let previous: [TodoStep]
            if let entry = latestTodoEntry, case .todos(let steps) = entry.item.content { previous = steps }
            else { previous = [] }
            upsertTodoSnapshot(nativeTodoSnapshot, previous: previous)
        }
    }

    private func finishLoad(_ document: ThreadDocument) {
        guard isLoadingHistory else { return }
        install(document, prepared: true)
        // Head-only rows can sit between finished turns; restore their exact positions
        // after the older rows have gone through the same prepend/recovery path.
        entries.sort { (itemPositions[$0.id] ?? .greatestFiniteMagnitude) < (itemPositions[$1.id] ?? .greatestFiniteMagnitude) }
        completeHistoryLoad()
    }

    private func completeHistoryLoad(unreadable keptAt: URL? = nil, partly: Bool = false, preservationFailed: Bool = false) {
        isLoadingHistory = false
        historyLoad = nil
        if preservationFailed {
            historyRecoveryBlocked = true
            appendNotice(.warning, historyRecoveryMessage)
            return
        }
        if let keptAt {
            let message = String(format: Chrome.localized(partly
                ? "Older parts of this chat couldn't be read. OMP GUI kept the files in %@."
                : "This chat's history couldn't be read. OMP GUI kept the files in %@."), keptAt.path)
            append(TimelineItem(turnID: nil, content: .notice(Notice(level: .warning, message: message))))
            saveRevision += 1
        }
        if saveRevision != lastSavedRevision { scheduleSave() }
    }

    /// Anything that continues the history (a new turn) waits for it first.
    func ensureLoaded() async {
        if let historyLoad { await historyLoad.value }
    }

    /// Installs context only while the destination has no conversation of its own.
    func installContinuation(_ value: ThreadContinuation) async -> Bool {
        await ensureLoaded()
        guard let thread, turns.isEmpty, entries.isEmpty, thread.providerSessionID == nil else { return false }
        // Selecting the new row can warm a session before the snapshot is installed.
        releaseSession(stop: true)
        continuation = value
        saveRevision += 1
        saveNow()
        return true
    }

    var isRunning: Bool { phase != .idle }
    var isCLIStarting: Bool { isStartingSession }

    var thread: ChatThread? { app?.thread(threadID) }

    /// Whether any head of this lead is still at work. A turn with heads at work is never
    /// interrupted on the user's behalf by a new message: only the Stop button and
    /// Escape stop it, and those are the user stopping the lead on purpose.
    var hasWorkingHeads: Bool {
        (app?.runningHydraHeads(of: threadID) ?? 0) > 0
    }

    /// Whether any helper of this lead — a head or a plain helper — is at work: the same
    /// question the folded-helpers line asks about the same helpers, so a lead's own row,
    /// its badge and the line under it never disagree.
    var hasWorkingHelpers: Bool {
        guard let app else { return false }
        for helper in app.children(of: threadID) {
            if let runtime = app.existingRuntime(for: helper.id), runtime.isRunning || runtime.isHydraMerging {
                return true
            }
        }
        return false
    }

    /// Escape on a running turn: the turn is stopped and taken back. The conversation
    /// rewinds to before it, the provider's context too (`revert`, the way editing a message
    /// rewinds it: Claude resumes at the kept turn's last message, Codex rolls the turn
    /// back), so the aborted exchange costs nothing next turn, and its message goes back
    /// in the composer to be changed and sent again. Files stay as the turn left them. With
    /// something already typed in the box, heads out on the turn (their reports belong
    /// to it), or a rewind the provider refuses, the turn is only stopped and stays in
    /// the thread.
    func takeBackRunningTurn() {
        guard draft.isEmpty, !hasWorkingHeads, let turnID = currentTurnID, let turn = turns.first(where: { $0.id == turnID }),
              let itemID = turn.userItemID, let entry = entryIndex[itemID],
              case .user(let message) = entry.item.content, !message.isFromHydra else {
            interrupt()
            return
        }
        interrupt()
        Task {
            // The interrupt lands asynchronously, and a rewind needs the turn finished; the
            // watchdog ends a session that ignores it within eight seconds. Words typed
            // into the box while the stop landed are the reader's, not the message's to
            // overwrite: the stopped turn then stays in the thread.
            for _ in 0..<200 where phase != .idle { try? await Task.sleep(for: .milliseconds(50)) }
            guard phase == .idle, draft.isEmpty, turns.contains(where: { $0.id == turnID }) else { return }
            do {
                try await revert(to: turnID, restoreFiles: false)
            } catch {
                appendNotice(.error, "The stopped message was kept: \(error.localizedDescription)")
                return
            }
            draft.text = message.text
            draft.attachments = message.attachments
        }
    }

    var sentPrompts: [String] {
        entries.compactMap { entry in
            if case .user(let message) = entry.item.content, !message.isFromHydra, !message.isHydraBrief { return message.text }
            return nil
        }
    }

    var hasSentPrompts: Bool {
        entries.contains { entry in
            if case .user(let message) = entry.item.content { return !message.isFromHydra }
            return false
        }
    }

    var pendingPlanApproval: ApprovalRequest? {
        approvals.first { $0.kind == .plan }
    }

    // MARK: - Sending

    func send() {
        guard !isDictating else { return }
        guard !historyRecoveryBlocked else { appendNotice(.warning, historyRecoveryMessage); return }
        if let head = thread, let nativeID = head.hydra?.nativeID, let parentID = head.parentThreadID {
            guard !isOMPAgentSteeringPending else { return }
            guard canSteerNativeOMPAgent else {
                appendNotice(.warning, nativeOMPControlMessage)
                return
            }
            let outgoing = draft
            let text = Self.ompSteeringText(draft.outgoingText, attachments: draft.attachments)
            guard !text.trimmed.isEmpty else { return }
            let observationID = head.hydra?.nativeObservationID
            let visibleNativeUsers = Set(nativeAgentObservedUsers.keys.map { "omp-native-user-" + $0 })
            isOMPAgentSteeringPending = true
            Task {
                defer { isOMPAgentSteeringPending = false }
                do {
                    guard let parent = app?.existingRuntime(for: parentID) else { throw ProviderError.notRunning }
                    try await parent.steerOMPAgent(nativeID, observationID: observationID, text: text)
                    guard thread?.hydra?.nativeObservationID == observationID else { return }
                    if draft == outgoing { draft = ComposerDraft() }
                    recordNativeAgentSteeringAcceptance(outgoing: outgoing, text: text, visibleNativeUsers: visibleNativeUsers)
                    saveNow()
                }
                catch {
                    appendNotice(.error, error.localizedDescription)
                }
            }
            return
        }

        if usesNativeOMPQueue {
            submitNativeDraft(delivery: nativeDraftDelivery(.steer))
            return
        }
        guard !isReverting, !draft.isEmpty, phase == .idle else { return }
        let attachments = draft.attachments
        let outgoing = draft.outgoingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if handleLocalCommand(outgoing) {
            draft = ComposerDraft()
            return
        }
        draft = ComposerDraft()
        // With every message going to a head, the lead stays idle for the reports.
        if dispatchSentHead(text: outgoing, attachments: attachments) { return }
        Task { await ensureLoaded(); await startTurn(text: outgoing, attachments: attachments) }
    }

    func sendHydraBrief(_ text: String, attachments: [Attachment]) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              phase == .idle else { return }
        draft = ComposerDraft()
        // The head's clock starts with its brief, so one that never answers counts as quiet.
        hydraLastEventAt = .now
        Task { await ensureLoaded(); await startTurn(text: text, attachments: attachments, hydraBrief: true) }
    }

    // Native submissions are admission records, never an execution scheduler.
    @ObservationIgnored private var nativeSubmissionDrafts: [UUID: ComposerDraft] = [:]
    @ObservationIgnored private var nativeSubmissionTurns: [UUID: UUID] = [:]
    @ObservationIgnored private var nativeInputGroups: [UUID] = []
    @ObservationIgnored private var nativeSeenUserMessages: Set<String> = []
    @ObservationIgnored private var nativePromptOutcomes: [UUID: TurnStatus] = [:]
    @ObservationIgnored private var nativeStartupSubmissionID: UUID?
    @ObservationIgnored private var nativeStartupWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var nativeRequestsSent: Set<UUID> = []

    private var usesNativeOMPQueue: Bool { thread?.provider == .omp && thread?.hydra?.kind != .native }

    func steerDraft() {
        guard !isDictating else { return }
        guard usesNativeOMPQueue else { interruptAndSend(); return }
        submitNativeDraft(delivery: nativeDraftDelivery(.steer))
    }

    private func nativeDraftDelivery(_ requested: OMPMessageDelivery) -> OMPMessageDelivery {
        phase == .idle && nativeStartupSubmissionID == nil && !hasNativeWork ? .prompt : requested
    }

    private func releaseNativeStartupAdmission(_ id: UUID) {
        guard nativeStartupSubmissionID == id else { return }
        nativeStartupSubmissionID = nil
        let waiters = nativeStartupWaiters
        nativeStartupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    @discardableResult
    private func submitNativeDraft(delivery: OMPMessageDelivery, submitted: ComposerDraft? = nil) -> UUID? {
        guard !isDictating else { return nil }
        guard !historyRecoveryBlocked else { appendNotice(.warning, historyRecoveryMessage); return nil }
        guard !ompFastModeWorking else {
            appendNotice(.warning, Chrome.localized("Wait for OMP to confirm Fast mode before sending."))
            return nil
        }
        if submitted == nil, submitOMPGoalDraftIfNeeded() { return nil }
        guard !ompSideQuestion.draining else {
            appendNotice(.warning, Chrome.localized("OMP is saving the side question and closing this connection. Wait for it to finish."))
            return nil
        }
        let outgoing = submitted ?? draft
        guard !isReverting, !outgoing.isEmpty else { return nil }
        guard ompContext.pendingCommand == nil else {
            appendNotice(.warning, Chrome.localized("Wait until OMP has confirmed the context action before sending another message."))
            return nil
        }
        let text = outgoing.outgoingText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Retained uncertain drafts cannot be duplicated by another Return.
        guard !followUps.contains(where: {
            !$0.canEdit && $0.ompState?.isTerminal != true && $0.text == text && $0.attachments == outgoing.attachments
        }) else {
            appendNotice(.warning, Chrome.localized("This draft already has a pending or unknown delivery. Check the message queue before sending it again."))
            return nil
        }
        if submitted == nil, delivery == .prompt, handleLocalCommand(text) {
            if draft == outgoing { draft = ComposerDraft() }
            return nil
        }
        let row = FollowUpPrompt(text: text, attachments: outgoing.attachments, ompDelivery: delivery,
            ompState: .submitting, ompShowsDelivery: delivery != .prompt)
        followUps.append(row)
        if submitted == nil { nativeSubmissionDrafts[row.id] = outgoing }
        saveRevision += 1
        saveNow()
        if delivery == .prompt {
            nativeStartupSubmissionID = row.id
            Task { await ensureLoaded(); await startTurn(text: text, attachments: outgoing.attachments, nativeSubmissionID: row.id) }
        } else {
            Task { await submitNativeQueueMessage(row.id) }
        }
        return row.id
    }

    private func submitNativeQueueMessage(_ id: UUID) async {
        // A cold first prompt owns session startup, model selection and its
        // checkpoint. Later inputs must not reach OMP before that prompt.
        if let first = nativeStartupSubmissionID, first != id {
            await withCheckedContinuation { nativeStartupWaiters.append($0) }
        }
        guard let index = followUps.firstIndex(where: { $0.id == id }),
              followUps[index].ompState == .submitting,
              let native = session as? OMPSession, let thread else {
            updateNativeSubmission(id, state: .failed, error: Chrome.localized("OMP is not ready to accept this message. Your draft has been kept."))
            return
        }
        let row = followUps[index]
        let files = row.attachments.filter { !$0.isImage }
        let text = files.isEmpty ? row.text : row.text + "\n\nAttached files:\n" + files.map { "- \($0.path)" }.joined(separator: "\n")
        do {
            try await native.send(TurnInput(text: text, images: row.attachments.filter(\.isImage), model: thread.model,
                effort: thread.effort, runtimeMode: thread.runtimeMode, interactionMode: thread.interactionMode,
                command: nil, ompDelivery: row.ompDelivery ?? .followUp, ompRequestID: id))
        } catch {
            // OMPSession distinguishes rejection from an unknown admission. Only
            // errors before a native request exists are definitely retryable.
            if followUps.first(where: { $0.id == id })?.ompState == .submitting {
                updateNativeSubmission(id, state: .failed, error: error.localizedDescription)
            }
            appendNotice(.warning, error.localizedDescription)
        }
    }

    private func updateNativeSubmission(_ id: UUID, state: OMPSubmissionState, error: String?) {
        guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
        if let turnID = nativeSubmissionTurns[id] {
            updateTurn(turnID) {
                if state == .accepted || state == .consumed || state == .finished { $0.nativeAdmission = true }
                else if state == .failed && $0.nativeAdmission != true { $0.nativeAdmission = false }
            }
        }
        if followUps[index].ompState?.isTerminal == true && state != followUps[index].ompState { return }
        followUps[index].ompState = state
        followUps[index].deliveryError = error
        if state == .accepted || state.isTerminal {
            if let outgoing = nativeSubmissionDrafts.removeValue(forKey: id), draft == outgoing { draft = ComposerDraft() }
        }
        if state != .submitting || nativeRequestsSent.contains(id) { releaseNativeStartupAdmission(id) }
        retireConsumedNativeSubmission(id)
        saveRevision += 1
        scheduleSave()
    }

    /// Delivery rows cover admission uncertainty. Once the native user entry
    /// has a transcript item, it owns the message and its attachments.
    private func retireConsumedNativeSubmission(_ id: UUID) {
        guard followUps.first(where: { $0.id == id })?.ompState == .consumed,
              let turnID = nativeSubmissionTurns[id],
              turns.first(where: { $0.id == turnID })?.userItemID != nil else { return }
        followUps.removeAll { $0.id == id }
    }

    /// A follow-up can begin a new response before OMP's encompassing run ends.
    /// Only the native successful response boundary seals earlier display groups;
    /// a steering message alone never establishes a final answer.
    private func receiveNativeUserMessage(requestID: UUID?, nativeID: String?, text: String, imageCount: Int, startsNewTurn: Bool) {
        if let nativeID, !nativeSeenUserMessages.insert(nativeID).inserted { return }
        if let requestID, let turnID = nativeSubmissionTurns[requestID] {
            updateTurn(turnID) { $0.nativeUserText = text; $0.nativeUserImageCount = imageCount }
            retireConsumedNativeSubmission(requestID)
            return
        }
        flushDeltas()
        let row = requestID.flatMap { id in followUps.first { $0.id == id } }
        if !startsNewTurn, row == nil, let currentTurnID,
           let current = turns.first(where: { $0.id == currentTurnID }),
           current.nativeUserText == text, current.nativeUserImageCount == imageCount {
            return
        }
        if startsNewTurn { sealNativeInputGroups() }
        var turn: TurnRecord
        if let currentTurnID, let existing = turns.first(where: { $0.id == currentTurnID }),
           existing.userItemID == nil, existing.status == .running {
            turn = existing
        } else {
            turn = TurnRecord(index: (turns.map(\.index).max() ?? -1) + 1)
            if let previousID = currentTurnID, turns.contains(where: { $0.id == previousID }) {
                nativeInputGroups.append(previousID)
                // Native input grouping does not capture a Git boundary.
            }
            turns.append(turn)
            currentTurnID = turn.id
        }
        let item = TimelineItem(turnID: turn.id, content: .user(UserMessage(text: row?.text ?? text, attachments: row?.attachments ?? [])))
        updateTurn(turn.id) {
            $0.userItemID = item.id
            $0.nativeUserText = text
            $0.nativeUserImageCount = imageCount
            if let requestID { $0.providerTurnID = requestID.uuidString }
        }
        if let requestID { nativeSubmissionTurns[requestID] = turn.id }
        append(item)
        if let requestID { retireConsumedNativeSubmission(requestID) }
        phase = .running
        turnStartedAt = .now
        saveNow()
    }

    private func sealNativeInputGroups() {
        let root = thread.flatMap { thread in
            app?.executionProject(for: thread).map { thread.executionDirectory(projectPath: $0.path) }
        }
        let projects = app?.projects.map(\.path) ?? []
        let endedAt = Date.now
        for id in nativeInputGroups + [currentTurnID].compactMap({ $0 }) {
            guard let turn = turns.first(where: { $0.id == id }), turn.status == .running else { continue }
            let status = nativePromptOutcomes.removeValue(forKey: id) ?? .completed
            var edits: [FileEdit] = []
            for entry in entries where entry.turnID == id {
                endStreaming(entry)
                if case .tool(let call) = entry.item.content, let root {
                    edits += call.edits.filter { Self.isProjectFile($0.path, root: root, projects: projects) }
                }
            }
            updateTurn(id) { $0.status = status; $0.completedAt = endedAt }
            // Git and command snapshots still belong to the encompassing native
            // run. Its finalization refreshes these counts once those settle.
            upsertNativeInputSummary(TurnSummary(turnID: id, status: status,
                duration: max(0, endedAt.timeIntervalSince(turn.startedAt)), filesChanged: Set(edits.map(\.path)).count,
                additions: edits.reduce(0) { $0 + $1.additions }, deletions: edits.reduce(0) { $0 + $1.deletions }, changes: nil))
        }
    }

    private func upsertNativeInputSummary(_ summary: TurnSummary) {
        let item: TimelineItem
        let position: Int
        if let index = entries.firstIndex(where: { $0.turnID == summary.turnID && $0.kind == .turnEnd }) {
            var existing = entries[index].item
            existing.content = .turnEnd(summary)
            item = existing
            position = index
            // Timeline meta caches summary values by entry identity. Keep the
            // stable row id and saved position, but invalidate its cached value.
            let replacement = TimelineEntry(item)
            replacement.onChange = { [weak self, weak replacement] in
                guard let self, let replacement else { return }
                self.markTurnDirty(replacement.turnID)
            }
            entries[position] = replacement
        } else {
            item = TimelineItem(turnID: summary.turnID, content: .turnEnd(summary))
            position = entries.lastIndex(where: { $0.turnID == summary.turnID }).map { $0 + 1 } ?? entries.count
            insertEntry(TimelineEntry(item), at: position)
        }
        entryIndex[item.id] = entries[position]
        markTurnDirty(summary.turnID)
    }

    private func finishNativeInputGroups(status: TurnStatus, root: String?, endCheckpoint: String?, endSnapshot: CheckoutSnapshot?) async {
        guard usesNativeOMPQueue else { return }
        let groups = nativeInputGroups
        nativeInputGroups.removeAll()
        for id in groups {
            guard let turn = turns.first(where: { $0.id == id }) else { continue }
            let outcome = nativePromptOutcomes.removeValue(forKey: id)
            let groupStatus = turn.status == .running ? (outcome ?? status) : turn.status
            let endedAt = turn.completedAt ?? .now
            var touched = Set<String>()
            for entry in entries where entry.turnID == id {
                endStreaming(entry)
                guard case .tool(var call) = entry.item.content else { continue }
                if call.status == .running {
                    call.finish(groupStatus == .completed ? .completed : .failed)
                    entry.item.content = .tool(call)
                }
                if let root {
                    touched.formUnion(call.edits.compactMap { TouchedPaths.relative($0.path, root: root) })
                }
            }
            updateTurn(id) {
                $0.status = groupStatus
                $0.completedAt = endedAt
                $0.touchedPaths = touched.sorted()
                if let endCheckpoint { $0.endCheckpoint = endCheckpoint }
                $0.endSnapshot = endSnapshot
            }
            hydraCurrentTurnTouchedPaths.formUnion(touched)
            turnDiffs.removeValue(for: id)
            revisionDiffs.removeValue(for: id.uuidString)
            let changes = FileChangeSummary(files: await parsedDiff(selection: id))
            upsertNativeInputSummary(TurnSummary(turnID: id, status: groupStatus,
                duration: max(0, endedAt.timeIntervalSince(turn.startedAt)), filesChanged: changes.files.count,
                additions: changes.additions, deletions: changes.deletions, changes: changes,
                fileAttributionVersion: TurnSummary.currentFileAttributionVersion))
        }
        if let currentTurnID { nativePromptOutcomes[currentTurnID] = nil }
    }

    // MARK: - Follow-up queue

    /// Whether the chat box can queue a message: while a turn runs, and while heads are
    /// out with the lead waiting on them. Return sends to the idle lead at once; the
    /// queue is for what should wait until the heads have reported.
    var canQueue: Bool {
        if thread?.hydra?.kind == .native { return false }
        return isRunning || hasWorkingHeads
    }

    /// Instantly queues the composer's draft as a follow-up while a turn runs or heads are
    /// at work. The prompt, pics and other attachments included, is sent as a direct user
    /// chat message once the running turn (or the heads' report) finishes. Stacks up:
    /// every queued prompt runs in order. With nothing to queue behind, the draft simply
    /// goes out: the queue chord is never a dead key.
    func queueDraftAsFollowUp() {
        guard !isDictating else { return }
        guard !isReverting, !draft.isEmpty else { return }
        if usesNativeOMPQueue {
            submitNativeDraft(delivery: nativeDraftDelivery(.followUp))
            return
        }
        guard canQueue else {
            send()
            return
        }
        enqueueFollowUp(text: draft.outgoingText, attachments: draft.attachments)
        draft = ComposerDraft()
    }

    /// Draft captured by Return while a turn runs: stop the turn, then send this
    /// right away instead of queueing it behind the queue.
    @ObservationIgnored private var pendingSend: PendingSend?
    /// A queued follow-up's turn is on its way to an idle lead (see
    /// `flushFollowUpsIfIdle`): a second prompt queued in the meantime waits its
    /// turn rather than starting one of its own, so two never double-send.
    @ObservationIgnored private var followUpFlushScheduled = false

    private struct PendingSend {
        var text: String
        var attachments: [Attachment]
    }

    /// Interrupts the running turn and sends the draft as soon as the stop
    /// lands, instead of queueing it as a follow-up. The composer clears at
    /// once; the message goes out when the turn fully stops (or immediately,
    /// if the turn finished on its own in the meantime). With heads at work the
    /// turn is left alone and the draft queues instead: see `hasWorkingHeads`.
    func interruptAndSend() {
        guard !isDictating else { return }
        if usesNativeOMPQueue {
            submitNativeDraft(delivery: nativeDraftDelivery(.stopAndSend))
            return
        }
        if thread?.hydra?.kind == .native { send(); return }
        guard !isReverting, !draft.isEmpty, phase != .idle else { return }
        // With every message going to a head, Return while the lead works sends the
        // draft to a head and leaves the lead's turn alone.
        if dispatchSentHead(text: draft.outgoingText, attachments: draft.attachments) {
            draft = ComposerDraft()
            return
        }
        // Heads at work are never stopped by a new message: their reports belong to
        // the running turn. The draft goes to a Tivano-run head of its own when the
        // settings allow it, else it waits as a follow-up behind the running turn; either
        // way nothing is interrupted.
        if hasWorkingHeads {
            enqueueFollowUp(text: draft.outgoingText, attachments: draft.attachments)
            draft = ComposerDraft()
            return
        }
        pendingSend = PendingSend(text: draft.outgoingText, attachments: draft.attachments)
        draft = ComposerDraft()
        interrupt()
    }

    /// Pairs the dragged follow-up onto another so they go out as one message: both
    /// carry the target's bundle (or a fresh one), and the dragged prompt moves to sit
    /// right after the bundle's last prompt.
    func bundleFollowUp(_ id: UUID, onto target: UUID) {
        guard id != target,
              followUps.first(where: { $0.id == id })?.canEdit == true,
              followUps.first(where: { $0.id == target })?.canEdit == true,
              let targetIndex = followUps.firstIndex(where: { $0.id == target }),
              followUps.firstIndex(where: { $0.id == id }) != nil else { return }
        let bundle = followUps[targetIndex].bundleID ?? UUID()
        followUps[targetIndex].bundleID = bundle
        var dragged = followUps.remove(at: followUps.firstIndex(where: { $0.id == id })!)
        dragged.bundleID = bundle
        // The target still carries the bundle, so this always finds at least it.
        let insertAt = (followUps.lastIndex(where: { $0.bundleID == bundle }) ?? (followUps.count - 1)) + 1
        followUps.insert(dragged, at: min(insertAt, followUps.count))
        saveRevision += 1
        scheduleSave()
    }

    /// Takes a prompt out of its bundle on purpose (the link tapped, or the row dragged
    /// out): it goes as its own message again, and a bundle left with one prompt dissolves.
    func unbundleFollowUp(_ id: UUID) {
        guard let index = followUps.firstIndex(where: { $0.id == id }), followUps[index].canEdit, followUps[index].bundleID != nil else { return }
        followUps[index].bundleID = nil
        tidyBundles()
        saveRevision += 1
        scheduleSave()
    }

    /// Drops a prompt from its bundle when neither neighbour shares it, and dissolves
    /// a bundle left with a single prompt.
    private func unbundleIfSeparated(_ id: UUID) {
        guard let index = followUps.firstIndex(where: { $0.id == id }),
              let bundle = followUps[index].bundleID else { return }
        let prevShares = index > 0 && followUps[index - 1].bundleID == bundle
        let nextShares = index + 1 < followUps.count && followUps[index + 1].bundleID == bundle
        guard !prevShares && !nextShares else { return }
        followUps[index].bundleID = nil
        let remaining = followUps.filter { $0.bundleID == bundle }
        if remaining.count == 1, let lone = followUps.firstIndex(where: { $0.id == remaining[0].id }) {
            followUps[lone].bundleID = nil
        }
    }

    /// Clears any bundle held by only one prompt.
    private func tidyBundles() {
        var counts: [UUID: Int] = [:]
        for prompt in followUps {
            if let bundle = prompt.bundleID { counts[bundle, default: 0] += 1 }
        }
        for index in followUps.indices {
            if let bundle = followUps[index].bundleID, counts[bundle] == 1 {
                followUps[index].bundleID = nil
            }
        }
    }

    /// The merged prompt for the bundle starting at `index`, without removing it.
    private func mergedBundle(startingAt index: Int) -> FollowUpPrompt {
        let first = followUps[index]
        guard let bundle = first.bundleID else { return first }
        var end = index
        while end + 1 < followUps.count, followUps[end + 1].bundleID == bundle { end += 1 }
        let members = Array(followUps[index...end])
        var merged = first
        merged.text = Self.bundleText(members)
        merged.attachments = members.flatMap { $0.attachments }
        merged.bundleID = nil
        return merged
    }

    /// The text of a bundle going out as one message. With no attachment among the
    /// members, their texts one after the other; otherwise each message is numbered and
    /// names its own pictures (by their order among the images sent, which is the order
    /// the merged attachments keep) and files (by path) under it, so the model never has
    /// to guess which picture or file came with which of the messages.
    static func bundleText(_ members: [FollowUpPrompt]) -> String {
        let texts = members.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard members.count > 1, members.contains(where: { !$0.attachments.isEmpty }) else {
            return texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        var imageNumber = 0
        var sections: [String] = []
        for (offset, member) in members.enumerated() {
            let number = offset + 1
            var lines = ["Message \(number):"]
            if !texts[offset].isEmpty { lines.append(texts[offset]) }
            let named = member.attachments.map { attachment -> String in
                guard attachment.isImage else { return "file \(attachment.path)" }
                imageNumber += 1
                return "image \(imageNumber) (\(attachment.name))"
            }
            if !named.isEmpty {
                lines.append("Attached to message \(number): " + named.joined(separator: ", ") + ".")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        let header = "\(members.count) messages sent together. The pictures and files a message came with are named under it, the pictures numbered in the order they are attached."
        return ([header] + sections).joined(separator: "\n\n")
    }

    /// Removes the prompt at `index` and every following adjacent prompt with the same
    /// non-nil bundle, returning them as one merged prompt.
    private func takeBundle(startingAt index: Int) -> FollowUpPrompt {
        let merged = mergedBundle(startingAt: index)
        let bundle = followUps[index].bundleID
        if let bundle {
            var end = index
            while end + 1 < followUps.count, followUps[end + 1].bundleID == bundle { end += 1 }
            followUps.removeSubrange(index...end)
        } else {
            followUps.remove(at: index)
        }
        return merged
    }

    /// Sends a queued follow-up right away instead of waiting its turn: the running turn
    /// stops and the prompt goes out as soon as the stop lands, exactly as Return does with
    /// the draft; idle, it simply sends. The rest of the queue waits for the new turn.
    /// Heads live on through a stop, in threads of their own, so the turn stops for the
    /// prompt as it would with none out: "now" means now.
    func sendFollowUpNow(_ id: UUID) {
        guard !isReverting else { return }
        guard !usesNativeOMPQueue || ompContext.pendingCommand == nil else { return }
        guard let index = followUps.firstIndex(where: { $0.id == id }), followUps[index].canEdit else { return }
        if usesNativeOMPQueue {
            let previousID = followUps[index].id
            let nextID = UUID()
            if followUpEdit?.id == previousID { followUpEdit = nil }
            followUps[index].id = nextID
            nativeSubmissionDrafts[nextID] = nativeSubmissionDrafts.removeValue(forKey: previousID)
            nativeSubmissionTurns[previousID] = nil
            let delivery = nativeDraftDelivery(.steer)
            followUps[index].ompDelivery = delivery
            followUps[index].ompShowsDelivery = delivery != .prompt
            followUps[index].ompState = .submitting
            followUps[index].deliveryError = nil
            let prompt = followUps[index]
            if delivery == .prompt {
                nativeStartupSubmissionID = nextID
                Task { await ensureLoaded(); await startTurn(text: prompt.text, attachments: prompt.attachments, nativeSubmissionID: nextID) }
            } else { Task { await submitNativeQueueMessage(nextID) } }
            return
        }
        var start = index
        if let bundle = followUps[index].bundleID {
            while start > 0, followUps[start - 1].bundleID == bundle { start -= 1 }
        }
        let prompt = takeBundle(startingAt: start)
        saveRevision += 1
        scheduleSave()
        guard !prompt.isEmpty else { return }
        if phase == .idle {
            if handleLocalCommand(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)) { return }
            Task { await ensureLoaded(); await startTurn(text: prompt.text, attachments: prompt.attachments) }
        } else if pendingSend == nil {
            pendingSend = PendingSend(text: prompt.text, attachments: prompt.attachments)
            interrupt()
        } else {
            // Return already has a message going out the moment the turn stops; this one
            // goes right behind it.
            followUps.insert(prompt, at: 0)
            saveRevision += 1
            scheduleSave()
        }
    }

    func enqueueFollowUp(text: String, attachments: [Attachment]) {
        let prompt = FollowUpPrompt(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments
        )
        guard !prompt.isEmpty else { return }
        if usesNativeOMPQueue {
            var row = prompt
            row.ompDelivery = .followUp
            row.ompState = .submitting
            row.ompShowsDelivery = true
            followUps.append(row)
            saveRevision += 1
            scheduleSave()
            Task { await submitNativeQueueMessage(row.id) }
            return
        }
        // With Hydra on, a task queued behind a running turn goes to a head right away,
        // with a note on what the lead is doing, instead of waiting its turn.
        if phase != .idle, dispatchQueuedHead(prompt) { return }
        followUps.append(prompt)
        saveRevision += 1
        scheduleSave()
        // An idle lead takes the next queued message at once, even with heads still
        // out: the queue only ever waits behind a running turn, never behind an
        // idle lead. Without this a prompt queued while the lead is idle (steered
        // behind heads at work) sits until the next turn ends, which may be never.
        flushFollowUpsIfIdle()
    }

    /// Hands a queued prompt to a Tivano-run head, when the app and the chat allow it and
    /// the pair has room for one more. Returns whether the head went out.
    private func dispatchQueuedHead(_ prompt: FollowUpPrompt) -> Bool {
        false
    }

    /// Hands a message the user sent, idle lead or not, to a Tivano-run head, when every
    /// message goes to heads and the pair has room. The local commands stay with the chat.
    /// Returns whether the head went out; if not, the message goes the ordinary way.
    private func dispatchSentHead(text: String, attachments: [Attachment]) -> Bool {
        guard let app, app.settings.hydraAlwaysHeads else { return false }
        let prompt = FollowUpPrompt(text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments)
        guard !prompt.isEmpty, prompt.text != "/plan", prompt.text != "/compact" else { return false }
        return dispatchHead(prompt, origin: .sent)
    }

    /// Sends a prompt out as a Tivano-run head with a note on what the lead is doing, or
    /// that it is idle. Returns whether the head went out.
    private func dispatchHead(_ prompt: FollowUpPrompt, origin: HydraHeadInfo.Origin) -> Bool {
        false
    }

    /// Follow-ups queued while the heads were all busy go out as heads once one frees up,
    /// as long as the lead is still at work; an idle lead takes them itself, in order.
    private func dispatchQueuedFollowUps() {
        guard !usesNativeOMPQueue, phase != .idle else { return }
        while !followUps.isEmpty {
            let merged = mergedBundle(startingAt: 0)
            guard dispatchQueuedHead(merged) else { break }
            _ = takeBundle(startingAt: 0)
            saveRevision += 1
            scheduleSave()
        }
    }

    /// Sends the next queued follow-up to an idle lead at once, even with heads still
    /// out. A turn the user stopped waits for them instead (see `drainFollowUps`).
    private func flushFollowUpsIfIdle() {
        guard !usesNativeOMPQueue, phase == .idle, !followUpFlushScheduled, !followUps.isEmpty,
              thread?.lastStatus != .interrupted else { return }
        followUpFlushScheduled = true
        Task { await startQueuedFollowUpTurn() }
    }

    /// The turn `flushFollowUpsIfIdle` scheduled. Something that started first (the
    /// heads' reports, or the user's own word) owns the queue now: its end drains it.
    private func startQueuedFollowUpTurn() async {
        followUpFlushScheduled = false
        guard phase == .idle else { return }
        // The queue drains exactly as after a completed turn: in order, skipping
        // prompts that emptied while queued.
        _ = drainFollowUps(after: .completed)
    }

    func removeFollowUp(_ id: UUID) {
        if canWithdrawFollowUp(id), followUps.first(where: { $0.id == id })?.canDismiss != true {
            withdrawFollowUp(id, restoringDraft: false)
            return
        }
        guard !isWithdrawingFollowUp(id) else { return }
        guard followUps.first(where: { $0.id == id })?.canDismiss == true else { return }
        discardFollowUp(id)
    }

    func isWithdrawingFollowUp(_ id: UUID) -> Bool { withdrawingFollowUpIDs.contains(id) }

    func canWithdrawFollowUp(_ id: UUID) -> Bool {
        guard !isReverting, let prompt = followUps.first(where: { $0.id == id }) else { return false }
        if prompt.canEdit { return true }
        return prompt.ompDelivery == .followUp && prompt.ompState == .accepted
            && ompCapabilities["gui_remove_follow_up"] == .supported
            && (session as? OMPSession)?.canWithdrawQueuedMessages == true
            && ompContext.pendingCommand == nil
    }

    func recallFollowUp(_ id: UUID) {
        guard !isWithdrawingFollowUp(id), canWithdrawFollowUp(id),
              let prompt = followUps.first(where: { $0.id == id }) else { return }
        if prompt.canEdit {
            discardFollowUp(id)
            restoreFollowUpDraft(prompt)
        } else {
            withdrawFollowUp(id, restoringDraft: true)
        }
    }

    /// Only a native queue result can release an admitted message. A consumed message
    /// or a replaced session must never put an already running input back in the box.
    private func withdrawFollowUp(_ id: UUID, restoringDraft: Bool) {
        guard !isWithdrawingFollowUp(id), canWithdrawFollowUp(id),
              let native = session as? OMPSession,
              let prompt = followUps.first(where: { $0.id == id }) else { return }
        withdrawingFollowUpIDs.insert(id)
        nativeOperationCount += 1
        let epoch = sessionEpoch
        Task { @MainActor in
            defer {
                withdrawingFollowUpIDs.remove(id)
                nativeOperationCount -= 1
            }
            do {
                let removed = try await native.withdrawFollowUp(id)
                guard epoch == sessionEpoch, session === native else { return }
                guard removed else {
                    appendNotice(.warning, Chrome.localized("OMP already started this message. It cannot be withdrawn."))
                    return
                }
                guard let current = followUps.first(where: { $0.id == id }),
                      current.ompState?.isTerminal != true else { return }
                discardFollowUp(id)
                if restoringDraft { restoreFollowUpDraft(prompt) }
            } catch {
                guard epoch == sessionEpoch, session === native else { return }
                if let index = followUps.firstIndex(where: { $0.id == id }) {
                    followUps[index].deliveryError = error.localizedDescription
                    saveRevision += 1
                    scheduleSave()
                }
                appendNotice(.warning, error.localizedDescription)
            }
        }
    }

    private func restoreFollowUpDraft(_ prompt: FollowUpPrompt) {
        if !prompt.text.isEmpty {
            draft.text = draft.text.isEmpty ? prompt.text : draft.text + "\n\n" + prompt.text
        }
        var kept = Set(draft.attachments.map(\.id))
        for attachment in prompt.attachments where kept.insert(attachment.id).inserted {
            draft.attachments.append(attachment)
        }
    }

    private func discardFollowUp(_ id: UUID) {
        if followUpEdit?.id == id { followUpEdit = nil }
        nativeSubmissionDrafts[id] = nil
        nativeSubmissionTurns[id] = nil
        followUps.removeAll { $0.id == id }
        tidyBundles()
        saveRevision += 1
        scheduleSave()
    }

    /// Moves a queued follow-up next to another one, for drag reordering. A no-op
    /// when it is already there, so hovering the same half never churns.
    /// Moves a follow-up to sit right before or after `target`; returns whether the queue changed.
    @discardableResult
    func moveFollowUp(_ id: UUID, to target: UUID, placeAfter: Bool) -> Bool {
        guard id != target,
              followUps.first(where: { $0.id == id })?.canEdit == true,
              followUps.first(where: { $0.id == target })?.canEdit == true,
              let from = followUps.firstIndex(where: { $0.id == id }),
              let to = followUps.firstIndex(where: { $0.id == target }) else { return false }
        var dest = to + (placeAfter ? 1 : 0)
        if from < dest { dest -= 1 }
        guard from != dest else { return false }
        let prompt = followUps.remove(at: from)
        followUps.insert(prompt, at: dest)
        unbundleIfSeparated(id)
        saveRevision += 1
        scheduleSave()
        return true
    }

    func updateFollowUp(_ id: UUID, text: String, attachments: [Attachment]) {
        guard let index = followUps.firstIndex(where: { $0.id == id }), followUps[index].canEdit else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, attachments.isEmpty {
            followUps.remove(at: index)
            tidyBundles()
        } else {
            followUps[index].text = text
            followUps[index].attachments = attachments
        }
        saveRevision += 1
        scheduleSave()
    }

    /// Sends the next queued follow-up as a direct user message. Only runs when idle after a
    /// completed turn: an interrupted turn means the user hit stop, so the queue waits for them.
    /// Returns whether a turn starts.
    private func drainFollowUps(after status: TurnStatus) -> Bool {
        guard !usesNativeOMPQueue, status == .completed, phase == .idle, !followUps.isEmpty else { return false }
        var next = takeBundle(startingAt: 0)
        saveRevision += 1
        // Skip prompts that emptied while queued (an attachment file deleted on disk still counts,
        // so only the text+attachment check applies).
        while next.isEmpty, !followUps.isEmpty {
            next = takeBundle(startingAt: 0)
            saveRevision += 1
        }
        guard !next.isEmpty else {
            scheduleSave()
            return false
        }
        scheduleSave()
        if handleLocalCommand(next.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return drainFollowUps(after: status)
        }
        // This turn starts on its own (see autoStartedTurnToken).
        autoStartedTurnToken &+= 1
        Task { await ensureLoaded(); await startTurn(text: next.text, attachments: next.attachments) }
        return true
    }

    func implementPlan(_ entryID: String) {
        guard phase == .idle, let entry = entryIndex[entryID], case .plan(var plan) = entry.item.content else { return }
        plan.state = .accepted
        entry.item.content = .plan(plan)
        saveRevision += 1
        app?.updateThread(threadID) { $0.interactionMode = .build }
        Task { await ensureLoaded(); await startTurn(text: "Implement the plan.", attachments: []) }
    }

    func dismissPlan(_ entryID: String) {
        guard let entry = entryIndex[entryID], case .plan(var plan) = entry.item.content else { return }
        plan.state = .dismissed
        entry.item.content = .plan(plan)
        saveRevision += 1
        scheduleSave()
    }

    private func handleLocalCommand(_ text: String) -> Bool {
        switch text {
        case "/plan":
            if let provider = thread?.provider { app?.providers.recordCommand("plan", for: provider) }
            app?.updateThread(threadID) { $0.interactionMode = $0.interactionMode == .plan ? .build : .plan }
            return true
        case "/compact" where thread?.provider.supportsCompact == true:
            if let provider = thread?.provider { app?.providers.recordCommand("compact", for: provider) }
            compact()
            return true
        default:
            return false
        }
    }

    /// Starts a turn on `text`. `hydraHeads` marks the message as heads reporting back to
    /// their lead rather than the user's own words; `hydraBrief` marks it as the lead's
    /// brief to a head, shown as a pill rather than a plain bubble.
    private func startTurn(text: String, attachments: [Attachment], hydraHeads: [Int]? = nil, hydraBrief: Bool = false, nativeSubmissionID: UUID? = nil) async {
        if let head = thread, let nativeID = head.hydra?.nativeID, let parentID = head.parentThreadID {
            do { try await app?.runtime(for: parentID).steerOMPAgent(nativeID, observationID: head.hydra?.nativeObservationID, text: Self.ompSteeringText(text, attachments: attachments)) }
            catch { appendNotice(.error, error.localizedDescription) }
            return
        }

        // A new turn must not race a provider-side archive. This wait occurs before
        // claiming the idle runtime, and the same session is restored before sending.
        await providerHistoryOperation?.value
        if usesNativeOMPQueue, ompContext.pendingCommand != nil {
            if let nativeSubmissionID {
                updateNativeSubmission(nativeSubmissionID, state: .failed,
                    error: Chrome.localized("Wait until OMP has confirmed the context action before sending another message."))
            }
            return
        }
        if !hydraBrief && (hydraStartupPending || app?.thread(threadID)?.hydra?.pendingProjectReference != nil) {
            if let nativeSubmissionID {
                updateNativeSubmission(nativeSubmissionID, state: .failed,
                    error: Chrome.localized("The conversation is not ready yet. Your draft has been kept."))
                return
            }
            enqueueFollowUp(text: text, attachments: attachments)
            if !hydraStartupPending, let summary = app?.thread(threadID)?.hydra?.summary {
                appendNotice(.error, summary)
            }
            return
        }
        guard phase == .idle, !isReverting else {
            if let nativeSubmissionID {
                if isReverting {
                    updateNativeSubmission(nativeSubmissionID, state: .failed,
                        error: Chrome.localized("The conversation is changing. Your draft has been kept."))
                } else if let index = followUps.firstIndex(where: { $0.id == nativeSubmissionID }),
                          followUps[index].ompState == .submitting {
                    // Another native turn won the startup race. Preserve this
                    // admission identity and let OMP schedule its steering.
                    followUps[index].ompDelivery = .steer
                    await submitNativeQueueMessage(nativeSubmissionID)
                }
                return
            }
            enqueueFollowUp(text: text, attachments: attachments)
            return
        }
        guard let app, let initialThread = app.thread(threadID), let project = app.executionProject(for: initialThread) else {
            if let nativeSubmissionID {
                updateNativeSubmission(nativeSubmissionID, state: .failed,
                    error: Chrome.localized("The conversation or project is no longer available. Your draft has been kept."))
            }
            return
        }
        if hydraBrief && initialThread.hydra?.status != .running {
            hydraStartupPending = false
            return
        }
        guard !initialThread.isArchived else {
            if let nativeSubmissionID {
                updateNativeSubmission(nativeSubmissionID, state: .failed,
                    error: Chrome.localized("This conversation is archived. Your draft has been kept."))
                return
            }
            enqueueFollowUp(text: text, attachments: attachments)
            return
        }
        do {
            let directory = initialThread.executionDirectory(projectPath: project.path)
            try prepareExecutionDirectory(directory, for: initialThread)
            guard app.beginThreadTurn(threadID) else {
                throw ProviderError.failed(Chrome.localized("The conversation could not be saved. Your draft has been kept."))
            }
        } catch {
            appendNotice(.error, error.localizedDescription)
            if let nativeSubmissionID { updateNativeSubmission(nativeSubmissionID, state: .failed, error: error.localizedDescription) }
            else if draft.isEmpty { draft = ComposerDraft(text: text, attachments: attachments) }
            return
        }
        if hydraBrief { hydraStartupPending = false }
        let turnIndex = (turns.map(\.index).max() ?? -1) + 1
        var turn = TurnRecord(index: turnIndex)
        let userItem = TimelineItem(turnID: turn.id, content: .user(UserMessage(text: text, attachments: attachments, hydraHeads: hydraHeads, hydraBrief: hydraBrief ? true : nil)))
        turn.userItemID = userItem.id
        turns.append(turn)
        if let nativeSubmissionID { nativeSubmissionTurns[nativeSubmissionID] = turn.id }
        saveRevision += 1
        currentTurnID = turn.id
        currentProviderDiff = nil
        currentProviderAnchor = nil
        append(userItem)
        app.clearDeferredResult(threadID)
        phase = .starting
        turnStartedAt = .now
        app.updateThread(threadID) {
            $0.updatedAt = .now
            $0.lastStatus = .running
            $0.pendingResultTurnID = nil
            $0.hasUnread = false
            $0.unreadRevision = UUID()
        }
        // A settled thread put back to work is open again.
        app.updateDockBadge()
        app.reopenIfSettled(threadID)
        endDelegationStream()
        hydraCurrentTurnTouchedPaths = []
        // `hydraHeads == nil` marks a turn of the user's own: it starts the request's
        // delegation budget over. Turns carrying head reports or a refusal notice continue it.
        hydraBudget.beginTurn(userAuthored: hydraHeads == nil)
        // A finished head told more from the panel is at work again: its lead's team
        // counts it, and its next report goes out as a fresh one.
        if let info = initialThread.hydra, info.kind == .tivano, info.isFinished {
            app.updateHydraHead(threadID) {
                $0.status = .running
                $0.finishedAt = nil
            }
        }
        if let info = initialThread.hydra, info.kind == .tivano {
            app.updateHydraHead(threadID) {
                if turns.count > 1 {
                    $0.startedAt = .now
                    $0.queuedAt = nil
                    $0.executionStartedAt = .now
                }
                $0.executionFinishedAt = nil
                $0.landingStartedAt = nil
                $0.landingFinishedAt = nil
            }
        }
        // A Tivano-run head gets so long for a turn, on any provider. The API sessions
        // stop themselves a little sooner from inside the turn; this is the backstop, and
        // the only stop a CLI head has.
        let isFinalReport = headReportsNext
        headReportsNext = false
        if initialThread.hydra?.kind == .tivano {
            let allowance = isFinalReport
                ? HydraBudget.reportSeconds
                : HydraBudget.maxSeconds + (initialThread.provider.isAPIKeyBased ? 90 : 0)
            headBudget?.cancel()
            headBudget = Task { [weak self] in
                try? await Task.sleep(for: .seconds(allowance))
                guard let self, !Task.isCancelled, self.currentTurnID == turn.id, self.phase != .idle else { return }
                self.headBudgetSpent = !isFinalReport
                self.interrupt()
            }
        }
        saveNow()
        // The chat is named as its first message goes in, not when the session finally
        // takes it: a cold session can take seconds, and a first send that fails must
        // not leave the chat nameless for good.
        generateTitle(from: text, attachments: attachments)

        await ensureModel(initialThread)

        let directory = initialThread.executionDirectory(projectPath: project.path)
        let git = Git(directory)
        let checkpointRef = Git.checkpointRef(thread: threadID, turn: turn.id, phase: "start")
        // Anything could have happened in the checkout since the last turn, so no snapshot
        // from it stands any more.
        settledTree = nil
        latestTree = nil
        treeEpoch += 1
        // The other checkouts earlier commands worked in are snapshotted afresh for the
        // same reason, alongside the checkpoint, so a command there this turn is diffed
        // from a tree that predates it. A folder that is gone is forgotten.
        foreignTrees = [:]
        for root in foreignRoots {
            guard FileManager.default.fileExists(atPath: root) else { foreignRoots.remove(root); continue }
            foreignTrees[root] = captureTree(Git(root))
        }
        // The checkpoint is several git processes over the whole checkout. It runs while
        // the session starts rather than in front of it, and both are waited for before a
        // word reaches the model, so nothing the agent does can slip past the snapshot.
        let checkpoint = Task.detached(priority: .userInitiated) { () -> CheckoutSnapshot? in
            guard await git.isRepository() else { return nil }
            return try? await git.captureCheckpoint(checkpointRef)
        }

        do {
            // A session started while the message was being typed is the one to use. The
            // session starts alongside the checkpoint. It is picked up from the runtime
            // afterwards rather than handed back as a value, because a session is not
            // Sendable and this task is one of its own.
            if let warmup { await warmup.value }
            let start = Task { () async throws -> Void in _ = try await self.ensureSession(directory: directory) }
            if let snapshot = await checkpoint.value {
                updateTurn(turn.id) { $0.baseCheckpoint = checkpointRef; $0.baseSnapshot = snapshot }
                latestTree = snapshot
            }
            try await start.value
            if SlashCommand.name(in: text) != nil {
                await app.providers.loadCommands(initialThread.provider, directory: directory)
            }
            // The user can stop a turn while it is still starting.
            guard currentTurnID == turn.id, let session, let thread = app.thread(threadID) else {
                if let nativeSubmissionID {
                    updateNativeSubmission(nativeSubmissionID, state: .failed,
                        error: Chrome.localized("The task stopped before this message was submitted. Your draft has been kept."))
                }
                return
            }
            let command = SlashCommand.name(in: text).flatMap { name in
                app.providers.commands[ProviderRegistry.commandKey(thread.provider, directory: directory)]?.first { $0.name == name }
            }
            var prompt = text
            let files = attachments.filter { !$0.isImage }
            if !files.isEmpty {
                prompt += "\n\nAttached files:\n" + files.map { "- \($0.path)" }.joined(separator: "\n")
            }
            // Native task delegation is part of OMP's tool surface and settings.
            // Leave slash commands at the start of the input; deliver guidance with the next ordinary message.
            var injectedAntiSlopPolicy = false
            let antiSlopEpoch = sessionEpoch
            if !Self.keepsHydraPolicyInSystemPrompt(thread.provider),
               SlashCommand.name(in: text) == nil,
               !antiSlopFallbackSent {
                let instructions = AntiSlopPolicy.instructions(enabled: sessionSignature?.antiSlopEnabled ?? app.settings.antiSlopEnabled)
                if !instructions.isEmpty {
                    prompt = instructions + "\n\n" + prompt
                    injectedAntiSlopPolicy = true
                }
            }
            // Forwarded context from the source thread precedes the first ordinary
            // message, after the prompt the user's own words built. A slash command
            // consumes no ordinary prompt, so it neither carries the snapshot nor
            // spends the one delivery.
            var injectedContinuation = false
            let continuationEpoch = sessionEpoch
            if let continuation, !continuationSent, SlashCommand.name(in: text) == nil {
                prompt = continuation.prompt + "\n\n" + prompt
                injectedContinuation = true
            }
            // A block dropped with no refusal turn left to say so still reaches the lead:
            // its notice rides on the front of whatever turn comes next. Taken here, with
            // the send about to run, so a turn that aborts while starting keeps it waiting.
            if let notice = hydraBudget.takeDropNotice() {
                prompt = notice + prompt
            }
            phase = .running
            if thread.provider == .omp {
                updateTurn(turn.id) { $0.nativeUserText = prompt; $0.nativeUserImageCount = attachments.filter(\.isImage).count }
            }
            try await session.send(TurnInput(
                text: prompt,
                images: thread.provider.supportsImages ? attachments.filter(\.isImage) : [],
                model: thread.model,
                effort: thread.effort,
                serviceTier: serviceTier(for: thread),
                fastMode: thread.fastMode,
                runtimeMode: thread.runtimeMode,
                interactionMode: thread.interactionMode,
                isFinalReport: isFinalReport,
                command: command,
                ompRequestID: nativeSubmissionID
            ))
            // Failed sends and replaced sessions must leave delivery pending.
            if injectedAntiSlopPolicy, sessionEpoch == antiSlopEpoch {
                antiSlopFallbackSent = true
            }
            if injectedContinuation, sessionEpoch == continuationEpoch {
                continuationSent = true
            }
            // The session has a conversation the provider can resume from here on.
            if let unsentSessionID {
                self.unsentSessionID = nil
                app.updateThread(threadID) { $0.providerSessionID = unsentSessionID }
            }
            if let command { app.providers.recordCommand(command.name, for: thread.provider) }
        } catch {
            if let nativeSubmissionID {
                let state = followUps.first(where: { $0.id == nativeSubmissionID })?.ompState
                if state == .unknown {
                    appendNotice(.warning, Chrome.localized("Delivery is unknown. OMP may still be processing this message; it will not be sent again automatically."))
                    return
                }
                if state == .submitting { updateNativeSubmission(nativeSubmissionID, state: .failed, error: error.localizedDescription) }
            }
            guard currentTurnID == turn.id else { return }
            if finishTurnUpdatingCLI(error.localizedDescription, status: .failed, turnID: turn.id) { return }
            appendNotice(.error, error.localizedDescription)
            await finishTurn(status: .failed, turnID: turn.id)
        }
    }

    /// Whether the provider's session carries the lead's Hydra policy from launch: the API
    /// sessions put it in their system prompt, and Claude, Codex and Copilot define it at
    /// launch with their own sub-agent tool switched off. Such a session takes the team as
    /// part of its signature, so a change to the team, or Hydra going on or off, restarts
    /// it, and the switch-off holds for every turn and every relaunch.
    private static func keepsHydraPolicyInSystemPrompt(_ provider: ProviderKind) -> Bool {
        AppModel.hydraDefinesPolicyAtLaunch(provider) || provider.isAPIKeyBased
    }

    /// Codex takes fast mode per turn as a service tier; models without a fast tier send none.
    private func serviceTier(for thread: ChatThread) -> String? {
        guard thread.provider == .codex,
              let tier = app?.providers.model(thread.model, for: thread.provider)?.fastTier else { return nil }
        return thread.fastMode ? tier : "default"
    }

    /// A thread with no model yet takes the provider's default, so the session launches
    /// with the model the app would show.
    private func ensureModel(_ thread: ChatThread) async {
        guard thread.model == nil, thread.provider != .omp, let app else { return }
        await app.providers.loadCatalog(thread.provider)
        if let model = app.providers.defaultModel(for: thread.provider) {
            app.updateThread(threadID) {
                $0.model = model.id
                $0.effort = $0.effort ?? model.defaultEffort
            }
        }
    }

    /// The provider process, started while the user is still typing the first message,
    /// so sending does not wait for the CLI to boot: about half a second for `claude`.
    /// Only for CLI providers without a session; a send in the meantime waits for the
    /// warm-up instead of starting a second process.
    func warmSession() {
        guard !historyRecoveryBlocked, phase == .idle, session == nil, warmup == nil, !isReverting, !hydraStartupPending,
              let app, let thread = app.thread(threadID), !thread.isArchived, thread.hydra?.kind != .native, !thread.provider.isAPIKeyBased,
              thread.hydra?.pendingProjectReference == nil,
              !app.providers.cliUpdateBlocksWarmup(thread.provider),
              let project = app.executionProject(for: thread) else { return }
        let directory = thread.executionDirectory(projectPath: project.path)
        guard FileManager.default.fileExists(atPath: directory) else { return }
        warmup = Task { [weak self] in
            guard let self else { return }
            await ensureLoaded()
            guard !historyRecoveryBlocked else { warmup = nil; return }
            await ensureModel(thread)
            guard phase == .idle, session == nil, !hydraStartupPending,
                  app.thread(threadID)?.hydra?.pendingProjectReference == nil,
                  !app.providers.cliUpdateBlocksWarmup(thread.provider) else { warmup = nil; return }
            // A start that fails is not retried on every keystroke: the send makes its own.
            if (try? await ensureSession(directory: directory)) != nil { warmup = nil }
        }
    }

    private func prepareExecutionDirectory(_ directory: String, for thread: ChatThread) throws {
        if thread.projectID == nil {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }

    private func ensureSession(directory: String, allowNewSession: Bool = true) async throws -> any ProviderSession {
        // Reads and sends can request the same cold conversation together.
        // A cancelled waiter must not stop another caller's shared startup.
        if let startup = sessionStartup {
            try await startup.value
            try Task.checkCancellation()
            return try await prepareSession(directory: directory, allowNewSession: allowNewSession)
        }
        if session?.isRunning == true {
            return try await prepareSession(directory: directory, allowNewSession: allowNewSession)
        }
        let startup = Task { _ = try await self.prepareSession(directory: directory, allowNewSession: allowNewSession) }
        sessionStartup = startup
        defer { sessionStartup = nil }
        try await startup.value
        try Task.checkCancellation()
        guard let session, session.isRunning else { throw ProviderError.notRunning }
        return session
    }

    private func prepareSession(directory: String, allowNewSession: Bool) async throws -> any ProviderSession {
        if let native = session as? OMPSession, native.isDraining {
            throw ProviderError.failed(Chrome.localized("OMP is saving the side question and closing this connection. Wait for it to finish."))
        }
        guard !historyRecoveryBlocked else { throw ProviderError.failed(historyRecoveryMessage) }
        guard let app, let thread = app.thread(threadID), thread.provider == .omp else { throw ProviderError.notRunning }
        guard !app.isChangingMemory else {
            throw ProviderError.failed(Chrome.localized("OMP is saving memory and closing its connections. Wait for the change to finish."))
        }
        await LoginEnvironment.load()
        guard !app.isChangingMemory else {
            throw ProviderError.failed(Chrome.localized("OMP is saving memory and closing its connections. Wait for the change to finish."))
        }
        let hydra = app.hydraLaunch(for: thread)
        guard let executable = app.providers.executable(for: .omp) else { throw ProviderError.notInstalled(.omp) }
        let environment = app.providers.environment(for: .omp)
        let signature = SessionSignature(provider: .omp, directory: directory, executable: executable, environment: environment,
            launchRuntimeMode: thread.runtimeMode, launchEffort: nil, launchFast: nil,
            launchModel: nil, launchInteraction: thread.interactionMode,
            hydra: hydra, hydraPairID: nil, antiSlopEnabled: app.settings.antiSlopEnabled, memory: app.settings.ompMemory)
        if let session, session.isRunning, let previous = sessionSignature {
            if previous == signature { return session }
            var sameSession = signature
            sameSession.hydra = previous.hydra
            if sameSession == previous, let omp = session as? OMPSession {
                try omp.updateDelegationPreference(hydra)
                sessionSignature = signature
                return session
            }
        }
        if let native = session as? OMPSession, native.sideQuestionSnapshot.persistenceError != nil {
            throw ProviderError.failed(Chrome.localized("OMP could not save the side question. Keep this connection open and resolve the native storage error before replacing it."))
        }
        if let native = session as? OMPSession, native.sideQuestionSnapshot.blocksRecycling {
            if !native.sideQuestionSnapshot.hasLiveWork { _ = native.beginSideQuestionDrain() }
            throw ProviderError.failed(Chrome.localized("The side question must finish saving before OMP can replace this connection."))
        }
        releaseSession(stop: true)
        try await waitForReplacedSessions()
        guard !app.isChangingMemory, app.settings.ompMemory == signature.memory else {
            throw ProviderError.failed(Chrome.localized("OMP is saving memory and closing its connections. Wait for the change to finish."))
        }
        // Settings can inspect global memory before a task's first prompt has created
        // its working directory. Every native launch needs the same task preparation.
        try prepareExecutionDirectory(directory, for: thread)
        func make(resumeID: String?) -> OMPSession {
            let configuration = SessionConfiguration(provider: .omp, executable: executable,
                workingDirectory: URL(fileURLWithPath: directory), environment: environment,
                resumeID: resumeID, resumeAt: nil, model: thread.model, effort: thread.effort,
                runtimeMode: thread.runtimeMode, interactionMode: thread.interactionMode, apiKey: nil, hydra: hydra,
                memory: app.settings.ompMemory, antiSlopEnabled: app.settings.antiSlopEnabled, modelCatalog: app.providers.models(for: .omp))
            let created = OMPSession(configuration: configuration)
            if let archive = ompDebug.archive {
                created.debugSnapshot = OMPDebugSnapshot(archive: archive)
            }
            if let resumeID, resumeID == ompContextSessionFile {
                created.contextSnapshot = ompContext.savedSnapshot
            }
            created.onHostTool = { [weak self] request in
                guard let self, let app = self.app else { throw OMPHostToolError.unavailablePreview }
                return try await app.handleOMPHostTool(request, threadID: self.threadID)
            }
            observe(created)
            return created
        }
        var candidate = make(resumeID: thread.providerSessionID)
        session = candidate
        sessionSignature = signature
        isStartingSession = true
        var started = false
        defer {
            isStartingSession = false
            if !started { candidate.onEvent = nil; if session === candidate { releaseSession(stop: true) } else { candidate.stop() } }
        }
        let sessionID: String
        do { sessionID = try await candidate.start() }
        catch where allowNewSession && session === candidate && !Task.isCancelled && Self.startsOver(after: error, resuming: thread) {
            releaseSession(stop: true)
            try await waitForReplacedSessions()
            candidate = make(resumeID: nil)
            session = candidate
            sessionSignature = signature
            appendNotice(.warning, AppText.localized("OMP no longer has this conversation. A new session starts here."))
            sessionID = try await candidate.start()
        }
        guard session === candidate, !Task.isCancelled else { throw CancellationError() }
        started = true
        recordSessionID(sessionID)
        return candidate
    }

    var canChangeMemory: Bool { canRecycleSession && !isStartingSession && (session as? OMPSession)?.memoryRequests.isEmpty != false }

    func closeForMemoryChange() async throws {
        guard canChangeMemory else {
            throw ProviderError.failed(Chrome.localized("Wait for all conversations and background work to finish before changing memory."))
        }
        if let snapshot = unsavedSnapshot(), !DiskWriter.shared.writeThreadSynchronously(snapshot) {
            throw ProviderError.failed(Chrome.localized("Save the conversation before changing memory."))
        }
        if let native = session as? OMPSession, native.isRunning {
            try await native.rpc.drainAndWait()
        }
        releaseSession(stop: false)
    }

    private func memorySession() async throws -> OMPSession {
        guard let app, app.settings.ompMemory.enabled, !app.isChangingMemory,
              let thread = app.thread(threadID), let project = app.executionProject(for: thread) else {
            throw ProviderError.failed(Chrome.localized("Enable memory and select a conversation to inspect it."))
        }
        let native = try await ensureSession(directory: thread.executionDirectory(projectPath: project.path))
        guard let native = native as? OMPSession else { throw ProviderError.notRunning }
        return native
    }

    func inspectMemory() async throws -> OMPMemoryInspection {
        try await memorySession().inspectMemory()
    }

    func previewMemory(_ file: OMPMemoryFile) async throws -> OMPMemoryPreview {
        try await memorySession().previewMemory(file)
    }

    func stopHeadSessionAfterProviderHistory() { stopSession() }
    func waitForProviderHistory() async {}

    /// Puts the session's ID on the thread, or holds it back while no message has gone
    /// through the session (`unsentSessionID`). A thread whose conversation the session
    /// picked up takes the ID at once: a provider may hand out a new one for it.
    private func recordSessionID(_ sessionID: String) {
        guard let app else { return }
        ompContextSessionFile = sessionID
        if app.thread(threadID)?.providerSessionID == nil {
            unsentSessionID = sessionID
        } else {
            app.updateThread(threadID) { $0.providerSessionID = sessionID }
        }
    }

    /// Whether a session that would not resume the thread's conversation starts over
    /// from nothing: only when the provider confirms the conversation is gone.
    private static func startsOver(after error: Error, resuming thread: ChatThread) -> Bool {
        guard thread.providerSessionID != nil else { return false }
        return lostConversation(error)
    }

    /// The provider's word for a conversation it no longer has: Claude Code's "No
    /// conversation found with session ID", Command Code's own line.
    private static func lostConversation(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.localizedCaseInsensitiveContains("no conversation found")
            || text.localizedCaseInsensitiveContains("no longer has this conversation")
            || ["thread", "rollout", "session"].contains { subject in
                text.range(of: "\(subject)(?: id)?[^\n.:]{0,120}(?:not found|does not exist)", options: [.regularExpression, .caseInsensitive]) != nil
                    || text.localizedCaseInsensitiveContains("no \(subject) found")
            }
    }

    /// The conversation before the current turn as plain exchanges, for an API session
    /// that starts over: it keeps its history in memory only, so this is how a head
    /// steered on after its session went, or any chat reopened later, still knows what
    /// was said and done. Tool calls stay out; the replies say what they did. Bounded, so
    /// a long thread does not send its whole past with every relaunch.
    private func apiTranscript() -> [TranscriptMessage] {
        // One pass to collect the exchanges, then the runs are joined rather than
        // appended into one another: repeated `+=` on array elements copies the whole
        // reply for every fragment, which is quadratic on fragmented history.
        let exclude = currentTurnID
        var fragments: [(assistant: Bool, text: String)] = []
        fragments.reserveCapacity(entries.count)
        for entry in entries where entry.item.turnID != exclude {
            switch entry.item.content {
            case .user(let message) where !message.text.isEmpty:
                fragments.append((assistant: false, text: message.text))
            case .assistant(let message) where !message.text.isEmpty:
                fragments.append((assistant: true, text: message.text))
            default:
                break
            }
        }
        var transcript: [TranscriptMessage] = []
        transcript.reserveCapacity(fragments.count)
        var index = 0
        while index < fragments.count {
            if !fragments[index].assistant {
                transcript.append(TranscriptMessage(role: .user, text: fragments[index].text))
                index += 1
                continue
            }
            // The status lines a turn streams between its tools read as one reply.
            let runStart = index
            while index < fragments.count, fragments[index].assistant { index += 1 }
            let joined = fragments[runStart..<index].map(\.text).joined(separator: "\n\n")
            transcript.append(TranscriptMessage(role: .assistant, text: joined))
        }
        var kept = Array(transcript.suffix(40))
        var budget = 60_000
        for index in kept.indices.reversed() {
            let length = kept[index].text.count
            if length <= budget {
                budget -= length
            } else if budget > 200 {
                kept[index].text = "…" + String(kept[index].text.suffix(budget))
                budget = 0
            } else {
                kept.removeSubrange(...index)
                break
            }
        }
        return kept
    }

    // MARK: - Controls

    @ObservationIgnored private var userStoppedTurnID: UUID?

    var isWaitingForLimit: Bool { app?.autoContinue.resumesAt[threadID] != nil }

    /// `byUser` false is Tivano stopping a turn gone quiet (see `watchQuiet`): the thread
    /// then finishes the way a failed turn does, unread and calling for attention.
    func interrupt(byUser: Bool = true) {
        if thread?.hydra?.kind == .native {
            app?.stopHydraHead(threadID)
            return
        }

        guard phase != .idle else { return }
        if byUser { userStoppedTurnID = currentTurnID }
        let turnID = currentTurnID
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        // Nothing has been sent yet: the provider has no turn of its own to stop, and
        // asking it would do nothing at all, leaving the watchdog to kill a session that
        // is only just starting. The turn ends here instead, and the message it was about
        // to send never goes.
        if phase == .starting {
            currentTurnID = nil
            Task { await finishTurn(status: .interrupted, turnID: turnID) }
            return
        }
        Task {
            guard currentTurnID == turnID, turnID != nil else { return }
            if let session {
                await session.interrupt()
            } else {
                await finishTurn(status: .interrupted, turnID: turnID)
            }
        }
        interruptWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.currentTurnID == turnID, turnID != nil else { return }
            self.releaseSession(stop: true)
            await self.finishTurn(status: .interrupted, turnID: turnID)
        }
    }

    // MARK: - Quiet watchdog

    /// A session can stay alive and say nothing, its model stream stalled or its process
    /// suspended, and nothing ends the turn then: no exit, no error, no timeout. Every half
    /// minute of a turn this looks at how long the session has been quiet: five minutes
    /// and the working line says so, ten and the turn is stopped, and a session that ignores
    /// the stop is ended by the interrupt watchdog eight seconds later. While a tool runs
    /// the line keeps its tool and the stop waits thirty minutes: a long build can print
    /// nothing for a while, but a tool whose end never arrives must not hide a hang forever.
    private static let quietTick: Duration = .seconds(30)
    private static let quietLabelAfter: TimeInterval = 300
    private static let quietStopAfter: TimeInterval = 600
    private static let quietToolStopAfter: TimeInterval = 1800

    private func startQuietWatchdog() {
        noteSessionEvent()
        quietWatchdog?.cancel()
        quietWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.quietTick)
                guard let self, !Task.isCancelled else { return }
                self.watchQuiet()
            }
        }
    }

    private func stopQuietWatchdog() {
        quietWatchdog?.cancel()
        quietWatchdog = nil
        if quietMinutes != nil { quietMinutes = nil }
    }

    private func noteSessionEvent() {
        lastSessionEventUptime = ProcessInfo.processInfo.systemUptime
        if quietMinutes != nil { quietMinutes = nil }
    }

    private func watchQuiet() {
        // Heads have their own watchdog (see `AppModel.startHydraWatchdog`).
        guard phase == .running, thread?.isHydraHead != true else { return }
        // Waiting on the reader, on a usage limit, on a merge or on heads still at work is
        // not the session gone quiet. The clock starts over once that ends.
        if !approvals.isEmpty || !questions.isEmpty || isWaitingForLimit || isHydraMerging || hasWorkingHeads {
            noteSessionEvent()
            return
        }
        let quiet = ProcessInfo.processInfo.systemUptime - lastSessionEventUptime
        let toolRunning = hasRunningTool
        if quiet >= (toolRunning ? Self.quietToolStopAfter : Self.quietStopAfter) {
            // Stopped once: the interrupt watchdog takes it from here.
            guard interruptWatchdog == nil, currentTurnID != nil else { return }
            let name = thread?.provider.displayName ?? Chrome.localized("The agent")
            let message = toolRunning
                ? Chrome.localized("%@ sent nothing for 30 minutes while a tool ran, so OMP GUI stopped the turn.")
                : Chrome.localized("%@ sent nothing for 10 minutes, so OMP GUI stopped the turn.")
            appendNotice(.error, String(format: message, name))
            interrupt(byUser: false)
        } else if !toolRunning, quiet >= Self.quietLabelAfter {
            let minutes = Int(quiet / 60)
            if quietMinutes != minutes { quietMinutes = minutes }
        }
    }

    /// Whether a tool of the running turn is still at work. Walks back from the end and
    /// stops at the previous turn.
    private var hasRunningTool: Bool {
        guard let turnID = currentTurnID else { return false }
        for entry in entries.reversed() {
            guard let entryTurn = entry.item.turnID else { continue }
            guard entryTurn == turnID else { break }
            if case .tool(let call) = entry.item.content, call.status == .running { return true }
        }
        return false
    }

    func pendingInteraction(for instanceID: UUID) -> OMPInteraction? { interactions[instanceID] }

    private func insertInteraction(_ item: OMPInteraction) {
        let replaced = interactions.values.filter { $0.identity.nativeID == item.identity.nativeID && $0.id != item.id }.map(\.id)
        for id in replaced { endInteraction(id, reason: .cancelled) }
        if interactions[item.id] == nil { interactions[item.id] = item }
    }

    private func endInteraction(_ instanceID: UUID, reason: OMPRequestResolution) {
        interactions.removeValue(forKey: instanceID)?.resolve(reason)
        approvals.removeAll { $0.instanceID == instanceID }
        questions.removeAll { $0.instanceID == instanceID }
    }

    private func invalidateInteractions() {
        for item in interactions.values { item.resolve(.disconnected) }
        interactions.removeAll()
        approvals.removeAll()
        questions.removeAll()
    }

    private var nativeRequestSessionID: String? {
        guard let native = session as? OMPSession else { return thread?.providerSessionID }
        return native.sessionFile.nilIfEmpty ?? native.configuration.resumeID
    }

    private func canAnswer(_ item: OMPInteraction) -> Bool {
        item.identity.threadID == threadID && item.identity.generation == sessionEpoch
            && item.identity.sessionID == nativeRequestSessionID && session?.isRunning == true
    }

    func resolve(_ request: ApprovalRequest, option: ApprovalRequest.Option) {
        guard let item = pendingInteraction(for: request.instanceID), canAnswer(item),
              approvals.contains(where: { $0.instanceID == request.instanceID }),
              request.options.contains(where: { $0.id == option.id }), item.beginSubmission(), let session else { return }
        let epoch = sessionEpoch
        let reportDelivery = answerDeliveryHandler()
        session.resolveApproval(request.id, optionID: option.id) { [weak self] succeeded in
            guard let self, sessionEpoch == epoch else { return }
            item.reportDelivery(succeeded)
            if succeeded {
                endInteraction(request.instanceID, reason: .delivered)
                if request.kind == .plan, let itemID = request.toolItemID,
                   let entry = entryIndex[itemID], case .plan(var plan) = entry.item.content {
                    plan.state = option.role == .approve ? .accepted : .dismissed
                    entry.item.content = .plan(plan)
                    saveRevision += 1
                    scheduleSave()
                }
            }
            reportDelivery(succeeded)
        }
    }

    func answer(_ request: QuestionRequest, answers: [String: QuestionAnswer], delivered completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let item = pendingInteraction(for: request.instanceID), canAnswer(item),
              questions.contains(where: { $0.instanceID == request.instanceID }), item.beginSubmission(), let session else {
            completion?(false)
            return
        }
        let epoch = sessionEpoch
        let reportDelivery = answerDeliveryHandler()
        session.answerQuestion(request.id, answers: answers) { [weak self] succeeded in
            guard let self, sessionEpoch == epoch else { completion?(false); return }
            item.reportDelivery(succeeded)
            if succeeded { endInteraction(request.instanceID, reason: .delivered) }
            reportDelivery(succeeded)
            completion?(succeeded)
        }
    }

    private func answerDeliveryHandler() -> @MainActor (Bool) -> Void {
        let name = thread?.provider.displayName ?? Chrome.localized("the provider")
        return { [weak self] delivered in
            guard !delivered else { return }
            self?.appendNotice(.warning, String(format: Chrome.localized("Your answer didn't reach %@. The request may no longer be available, or the provider could not accept the answer. Try again or send a message to carry on."), name))
        }
    }

    func compact() {
        Task {
            do {
                try await compactContext(customInstructions: "")
            } catch {
                appendNotice(.warning, error.localizedDescription)
            }
        }
    }

    var hasNativeConversation: Bool {
        thread?.provider == .omp && thread?.hydra?.kind != .native && thread?.providerSessionID != nil
    }

    var canBranchConversation: Bool {
        !historyRecoveryBlocked && hasNativeConversation && phase == .idle && !isReverting && nativeOperationCount == 0 && nativeRefreshCount == 0
            && finishingTurnID == nil && pendingSend == nil && !isLoadingHistory && !isStartingSession
            && approvals.isEmpty && questions.isEmpty && backgroundTasks.isEmpty && !hasWorkingHelpers
            && !followUps.contains { $0.ompState?.isTerminal != true }
            && ompContext.pendingCommand == nil && ompCapabilities["branch"] != .unsupported
            && (session == nil || ompActivity?.canRecycle == true)
    }

    var canManageContext: Bool {
        phase == .idle && !isReverting && nativeOperationCount == 0 && finishingTurnID == nil
            && pendingSend == nil && !isLoadingHistory && !isStartingSession
            && approvals.isEmpty && questions.isEmpty && !hasWorkingHelpers
            && !followUps.contains { $0.ompState?.isTerminal != true }
            && ompContext.pendingCommand == nil && ompActivity?.canRecycle == true
            && session?.isRunning == true
    }

    func reportNativeError(_ error: Error) { appendNotice(.warning, error.localizedDescription) }

    func applyOMPEditorText() {
        guard let text = pendingOMPEditorText else { return }
        // Preserve the previous draft as an unsubmitted, editable record. Never
        // silently inject displaced user text into the new model request.
        if !draft.isEmpty || !draft.quotes.isEmpty {
            followUps.append(FollowUpPrompt(text: draft.outgoingText, attachments: draft.attachments, ompState: .draft))
            saveRevision += 1
            scheduleSave()
        }
        draft = ComposerDraft(text: text, attachments: draft.attachments)
        lastOMPEditorText = text
        pendingOMPEditorText = nil
    }

    func dismissOMPEditorText() { pendingOMPEditorText = nil }

    func setExplicitFileContext(_ context: FileQuestionContext?) {
        explicitFileContext = context
    }

    func addFileContextToDraft(_ context: FileQuestionContext) {
        explicitFileContext = context
        draft.quotes.append(ReplyQuote(text: context.promptText))
    }

    func setOMPAgentDetailsVisible(_ nativeID: String, observationID: String?, visible: Bool) async -> Bool {
        guard let native = session as? OMPSession else { return false }
        return await native.setAgentDetailsVisible(nativeID, observationID: observationID, visible: visible)
    }

    func updateNativeDetailConsumer(_ consumer: String, visible: Bool) -> Bool {
        if visible { nativeDetailConsumers.insert(consumer) }
        else { nativeDetailConsumers.remove(consumer) }
        return !nativeDetailConsumers.isEmpty
    }

    var hasNativeDetailConsumers: Bool { !nativeDetailConsumers.isEmpty }

    /// Replace only a native head's display index after OMP reports a truncated
    /// or initially unread journal. The worker and its task remain OMP-owned.
    func resetNativeAgentTranscript() {
        guard thread?.hydra?.kind == .native else { return }
        nativeAgentHistorySnapshot = nil
        // Rehydrate accepted-but-unconsumed records from saved display rows too.
        // A reconnect must not discard the only local copy of a queued steer.
        for entry in entries {
            guard case .user(let message) = entry.item.content else { continue }
            if entry.id.hasPrefix("omp-native-user-") {
                let nativeID = String(entry.id.dropFirst("omp-native-user-".count))
                if nativeAgentInitialUserID == nil { nativeAgentInitialUserID = nativeID }
                nativeAgentObservedUsers[nativeID] = message.text
            } else if entry.id.hasPrefix("omp-steer-local-"), !nativeAgentSteeringDrafts.contains(where: { $0.id == entry.id }) {
                nativeAgentSteeringDrafts.append(NativeAgentSteeringDraft(id: entry.id,
                    text: Self.ompSteeringText(message.text, attachments: message.attachments), message: message))
            }
        }
        flushTask?.cancel()
        flushTask = nil
        pendingDeltas.removeAll()
        pendingFlushBytes = 0
        streamByteLengths.removeAll()
        currentTurnID = nil
        finishingTurnID = nil
        finishingGeneration = nil
        closingTurnID = nil
        runtimeOwnerTurnID = nil
        removeEntries { _ in true }
        entryIndex.removeAll()
        turns.removeAll()
        itemPositions.removeAll()
        turnRevisions.removeAll()
        savedTurnRevisions.removeAll()
        nativeTodoSnapshot = nil
        nativeTodoSteps = nil
        todosEntryID = nil
        usage = nil
        nativeAgentContext.usage = nil
        nativeAgentContextRevision &+= 1
        diffSelection = nil
        diffRevision += 1
        nativeJournalDecoder = nil
        nativeJournalEntries.removeAll()
        nativeJournalLastDate = nil
        nativeUntimedTurns.removeAll()
        nativeAgentInitialUserID = nil
        nativeAgentHistoryIssue = nil
        completeNativeAgentTranscript()
        scheduleSave()
    }

    var canInspectOMPContext: Bool {
        thread?.provider == .omp
            && (thread?.hydra?.kind != .native || thread?.providerSessionID?.isEmpty == false)
            && thread?.hydra?.pendingProjectReference == nil
    }

    /// A worker's capacity belongs to its reported model, never its lead's model.
    /// Catalogue loading can fill a missing limit without another journal read.
    var displayedContextUsage: ContextUsage? {
        guard var value = usage else { return nil }
        if thread?.hydra?.kind == .native, value.windowTokens == nil {
            value.windowTokens = nativeAgentContextWindow
        }
        return value
    }

    var nativeAgentContextWindow: Int? {
        nativeAgentContext.windowTokens
            ?? app?.providers.model(nativeAgentContext.model ?? thread?.model, for: .omp)?.metadata?.contextWindow
    }

    private func refreshOMPAgentContext() async throws {
        guard let file = thread?.providerSessionID else { throw ProviderError.notRunning }
        let observation = thread?.hydra?.nativeObservationID
        let revision = nativeAgentContextRevision
        let readID: UUID
        let read: Task<OMPAgentJournal.ContextReport, Error>
        if let existing = nativeAgentContextRead, existing.file == file, existing.observationID == observation {
            readID = existing.id
            read = existing.task
        } else {
            readID = UUID()
            read = Task.detached(priority: .userInitiated) {
                try OMPAgentJournal.contextReport(OMPAgentJournal.read(file))
            }
            nativeAgentContextRead = (readID, file, observation, read)
        }
        defer { if nativeAgentContextRead?.id == readID { nativeAgentContextRead = nil } }
        var report = try await read.value
        try Task.checkCancellation()
        guard thread?.providerSessionID == file, thread?.hydra?.nativeObservationID == observation else { throw CancellationError() }
        // A progress report or journal delta admitted after this read started wins.
        guard nativeAgentContextRevision == revision else { return }
        report.model = report.model ?? nativeAgentContext.model ?? thread?.model
        if report.model == nativeAgentContext.model {
            report.windowTokens = nativeAgentContext.windowTokens
            report.usage?.windowTokens = report.windowTokens
        }
        nativeAgentContext = report
        usage = displayedAgentUsage(report)
        saveRevision += 1
        scheduleSave()
    }

    private func displayedAgentUsage(_ report: OMPAgentJournal.ContextReport) -> ContextUsage? {
        guard var value = report.usage else { return nil }
        value.windowTokens = value.windowTokens
            ?? report.windowTokens
            ?? app?.providers.model(report.model ?? thread?.model, for: .omp)?.metadata?.contextWindow
        return value
    }

    /// Prepare only visible, existing conversations. A new empty chat still
    /// waits for an explicit action; historical workers use their read-only log.
    func prepareOMPContext() async {
        guard canInspectOMPContext, thread?.isArchived != true,
              thread?.providerSessionID != nil || activeOMPSession != nil else { return }
        try? await refreshOMPContext(ifNeeded: true)
    }

    func refreshOMPContext(ifNeeded: Bool = false) async throws {
        nativeRefreshCount += 1
        defer { nativeRefreshCount -= 1 }
        await ensureLoaded()
        try Task.checkCancellation()
        guard !historyRecoveryBlocked else { throw ProviderError.failed(historyRecoveryMessage) }
        if thread?.hydra?.kind == .native {
            try await refreshOMPAgentContext()
            return
        }
        guard canInspectOMPContext, !isReverting, providerHistoryOperation == nil, !hydraStartupPending,
              let app, !app.isChangingMemory, let thread, let project = app.executionProject(for: thread) else {
            throw ProviderError.notRunning
        }
        if let warmup { await warmup.value }
        if let sessionStartup { try await sessionStartup.value }
        try Task.checkCancellation()
        // Inspection reuses a live connection, even while it is busy. Only a
        // cold read resumes OMP, without falling back to an empty conversation.
        let native: OMPSession
        if let active = activeOMPSession {
            native = active
        } else {
            guard let resumed = try await ensureSession(directory: thread.executionDirectory(projectPath: project.path),
                                                        allowNewSession: false) as? OMPSession else {
                throw ProviderError.notRunning
            }
            native = resumed
        }
        let epoch = sessionEpoch
        if ifNeeded { try await native.refreshContextIfNeeded() }
        else { try await native.refreshContext() }
        guard epoch == sessionEpoch, session === native else { throw CancellationError() }
        if native.contextRefreshedRevision == native.contextSnapshot.revision {
            ompContextIsCached = false
        }
    }

    /// Optional native controls reuse this conversation's live lead process.
    /// Looking at a control never starts OMP or revives a historical worker.
    var activeOMPSession: OMPSession? {
        guard thread?.hydra?.kind != .native, let native = session as? OMPSession, native.isRunning, !native.isDraining else { return nil }
        return native
    }

    /// Protect this read from connection recycling and history mutations just
    /// like the context-ring read. A private extension command is not a turn.
    /// Completion reads may reuse a connection but cannot resume a stopped one.
    func inspectOMPContext(allowResume: Bool = true) async throws -> OMPContextLiveInspection? {
        nativeRefreshCount += 1
        defer { nativeRefreshCount -= 1 }
        await ensureLoaded()
        try Task.checkCancellation()
        guard !historyRecoveryBlocked else { throw ProviderError.failed(historyRecoveryMessage) }
        guard canInspectOMPContext, thread?.hydra?.kind != .native, thread?.isArchived != true,
              !isReverting, providerHistoryOperation == nil, !hydraStartupPending,
              app?.isChangingMemory != true, ompContext.pendingCommand == nil else { throw ProviderError.notRunning }
        if activeOMPSession == nil {
            guard allowResume else { return nil }
            try await refreshOMPContext(ifNeeded: true)
        }
        guard let native = activeOMPSession else { throw ProviderError.notRunning }
        let epoch = sessionEpoch
        let snapshot = try await native.inspectContext()
        if snapshot == nil && allowResume { try await refreshOMPContext() }
        guard epoch == sessionEpoch, session === native else { throw CancellationError() }
        return snapshot
    }

    var ompFastModeWorking = false

    /// Clicking Fast explicitly authorizes a native connection, without sending
    /// the composer draft. Merely opening the model panel remains read-only.
    func changeOMPModelFastMode(_ enabled: Bool, expectedModel: String) async throws {
        guard !ompFastModeWorking else { return }
        ompFastModeWorking = true
        nativeOperationCount += 1
        defer { ompFastModeWorking = false; nativeOperationCount -= 1 }
        await ensureLoaded()
        guard !historyRecoveryBlocked, !isReverting, !isLoadingHistory, providerHistoryOperation == nil,
              !hydraStartupPending, let app, let selected = thread, selected.provider == .omp, !selected.isArchived,
              selected.model == expectedModel, selected.hydra?.kind != .native,
              selected.hydra?.pendingProjectReference == nil,
              app.providers.model(expectedModel, for: .omp)?.supportsFast == true,
              let project = app.executionProject(for: selected) else { throw ProviderError.notRunning }
        if let warmup { await warmup.value }
        guard thread?.model == expectedModel else { throw CancellationError() }
        let native = try await ensureSession(directory: selected.executionDirectory(projectPath: project.path))
        guard let native = native as? OMPSession, session === native, thread?.model == expectedModel else { throw ProviderError.notRunning }
        let epoch = sessionEpoch
        defer {
            // Fast journals native configuration even before the first message.
            // Keep that identity on unknown admission as well as success.
            if epoch == sessionEpoch, session === native, let unsentSessionID,
               native.runOptions.pending?.option == .fast || native.runOptions.fastEnabled != nil {
                self.unsentSessionID = nil
                app.updateThread(threadID) { $0.providerSessionID = unsentSessionID }
            }
        }
        try await native.setModelFastMode(enabled, expectedModel: expectedModel, effort: selected.effort)
        guard epoch == sessionEpoch, session === native else { throw CancellationError() }
    }

    func withActiveOMPSession<T>(_ action: @MainActor (OMPSession) async throws -> T) async throws -> T {
        guard let native = activeOMPSession else { throw ProviderError.notRunning }
        let epoch = sessionEpoch
        nativeOperationCount += 1
        defer { nativeOperationCount -= 1 }
        let result = try await action(native)
        guard epoch == sessionEpoch, session === native else { throw CancellationError() }
        return result
    }

    /// Unlike opening Goal controls, sending an objective explicitly authorizes
    /// startup. Keep ordinary startup/session identity and recycling protection.
    func withOMPGoalSubmissionSession<T>(_ action: @MainActor (OMPSession) async throws -> T) async throws -> T {
        nativeOperationCount += 1
        defer { nativeOperationCount -= 1 }
        await ensureLoaded()
        guard !historyRecoveryBlocked, !isReverting, !isLoadingHistory, providerHistoryOperation == nil,
              !hydraStartupPending, let app, let thread, thread.provider == .omp, !thread.isArchived,
              thread.hydra?.kind != .native, thread.hydra?.pendingProjectReference == nil,
              let project = app.executionProject(for: thread) else { throw ProviderError.notRunning }
        if let warmup { await warmup.value }
        let native = try await ensureSession(directory: thread.executionDirectory(projectPath: project.path))
        guard let native = native as? OMPSession else { throw ProviderError.notRunning }
        let epoch = sessionEpoch
        // Goal creation itself journals native state, even when OMP performs the
        // initial turn without a GUI prompt. Unknown admission also needs the
        // same recovery identity; a lost response cannot discard its journal.
        defer {
            if epoch == sessionEpoch, session === native, let unsentSessionID,
               native.goalSnapshot.pending != nil || native.goalSnapshot.goal != nil || native.goalSnapshot.lastTerminal != nil {
                self.unsentSessionID = nil
                app.updateThread(threadID) { $0.providerSessionID = unsentSessionID }
            }
        }
        let value = try await action(native)
        guard epoch == sessionEpoch, session === native else { throw CancellationError() }
        return value
    }

    func submitOMPGoalPrompt(_ outgoing: ComposerDraft, native: OMPSession, goalID: String, runGeneration: Int) {
        guard session === native, native.canStartGoalPrompt(goalID: goalID, runGeneration: runGeneration) else { return }
        _ = submitNativeDraft(delivery: .prompt, submitted: outgoing)
    }

    private func contextSession() throws -> OMPSession {
        guard canManageContext, let native = session as? OMPSession else {
            throw ProviderError.failed(Chrome.localized("Wait until OMP has finished its current work before managing context."))
        }
        return native
    }

    func compactContext(customInstructions: String) async throws {
        let native = try contextSession()
        nativeOperationCount += 1
        defer { nativeOperationCount -= 1 }
        _ = try await native.compactContext(customInstructions: customInstructions)
    }

    func setAutoCompaction(_ enabled: Bool) async throws {
        let native = try contextSession()
        nativeOperationCount += 1
        defer { nativeOperationCount -= 1 }
        try await native.setAutoCompaction(enabled)
    }

    func handoffContext(customInstructions: String) async throws -> OMPHandoffResult {
        let native = try contextSession()
        nativeOperationCount += 1
        defer { nativeOperationCount -= 1 }
        return try await native.handoffContext(customInstructions: customInstructions)
    }

    func exportContextHTML(to path: String) async throws -> String {
        let native = try contextSession()
        nativeOperationCount += 1
        defer { nativeOperationCount -= 1 }
        return try await native.exportContextHTML(to: path)
    }

    private func nativeHistorySession() async throws -> OMPSession {
        await ensureLoaded()
        guard hasNativeConversation, let app, let thread, let project = app.executionProject(for: thread) else {
            throw ProviderError.failed(Chrome.localized("No native OMP history is available for this conversation."))
        }
        guard let native = try await ensureSession(directory: thread.executionDirectory(projectPath: project.path), allowNewSession: false) as? OMPSession else {
            throw ProviderError.notRunning
        }
        return native
    }

    func loadNativeHistory() async throws -> OMPHistorySnapshot {
        nativeOperationCount += 1
        defer { nativeOperationCount -= 1 }
        let native = try await nativeHistorySession()
        let history = try await native.nativeHistory()
        await mapNativeHistory(history)
        return history
    }

    private func mapNativeHistory(_ history: OMPHistorySnapshot) async {
        let inputs = turns.compactMap { turn -> OMPHistoryUserInput? in
            guard turn.nativeAdmission != false else { return nil }
            guard let id = turn.userItemID, let entry = entryIndex[id], case .user(let user) = entry.item.content else { return nil }
            return OMPHistoryUserInput(id: turn.id, text: turn.nativeUserText ?? user.text,
                imageCount: turn.nativeUserImageCount ?? user.attachments.filter(\.isImage).count,
                nativeEntryID: turn.nativeSessionFile == history.sessionFile ? turn.nativeUserEntryID : nil)
        }
        let mapped = await Task.detached(priority: .userInitiated) {
            var mapped = inputs.count == history.activeUserEntries.count ? history.mapUserEntries(to: inputs) : [:]
            // A new unlinked/failed row must not invalidate earlier identities that
            // are still present with exactly the submitted content on this path.
            let native = Dictionary(uniqueKeysWithValues: history.activeUserEntries.map { ($0.id, $0) })
            for input in inputs where mapped[input.id] == nil {
                if let id = input.nativeEntryID, let message = native[id]?.message,
                   message.text == input.text, message.images.count == input.imageCount { mapped[input.id] = id }
            }
            return mapped
        }.value
        guard thread?.providerSessionID == history.sessionFile else { return }
        var updated = turns
        var dirty: [UUID] = []
        for index in updated.indices {
            let entryID = mapped[updated[index].id]
            if updated[index].nativeUserEntryID != entryID || updated[index].nativeSessionFile != history.sessionFile {
                updated[index].nativeUserEntryID = entryID
                updated[index].nativeSessionFile = history.sessionFile
                dirty.append(updated[index].id)
            }
        }
        guard !dirty.isEmpty else { return }
        turns = updated
        for id in dirty { markTurnDirty(id) }
        saveRevision += 1
        scheduleSave()
    }

    /// What restoring the files to before a turn would touch: the whole checkout against
    /// the turn's checkpoint. A `git add` of the checkout into a scratch index plus a
    /// numstat, hundreds of milliseconds on a big repository, so the message editor asks
    /// for it from the pencil's hover and again on the click, and both get one run.
    /// Kept while the thread's files stay as the last turn left them (`diffRevision`) and
    /// for ten seconds, so edits made outside the app are picked up soon after.
    func revertPreview(for turnID: UUID) -> Task<RevertPreview, Error> {
        if let entry = revertPreviews[turnID], entry.revision == diffRevision, entry.startedAt.duration(to: .now) < .seconds(10) {
            return entry.task
        }
        let revision = diffRevision
        let task = Task { [weak self] () throws -> RevertPreview in
            guard let self else { throw ProviderError.notRunning }
            let result: Result<RevertPreview, Error>
            do { result = .success(try await self.previewRevert(to: turnID)) } catch { result = .failure(error) }
            if self.revertPreviews[turnID]?.revision == revision { self.revertPreviews[turnID]?.result = result }
            return try result.get()
        }
        // Previews of files as they were before the last turn are stale for every message.
        revertPreviews = revertPreviews.filter { $0.value.revision == revision }
        revertPreviews[turnID] = RevertPreviewEntry(revision: revision, startedAt: .now, task: task, result: nil)
        return task
    }

    /// The preview already in hand for a turn, if a hover fetched it: the editor opens on
    /// it at once instead of on a spinner.
    func cachedRevertPreview(for turnID: UUID) -> Result<RevertPreview, Error>? {
        guard let entry = revertPreviews[turnID], entry.revision == diffRevision,
              entry.startedAt.duration(to: .now) < .seconds(10) else { return nil }
        return entry.result
    }

    private struct RevertPreviewEntry {
        let revision: Int
        let startedAt: ContinuousClock.Instant
        let task: Task<RevertPreview, Error>
        var result: Result<RevertPreview, Error>?
    }

    /// Bounded by the thread's turns: only entries of the current revision are kept.
    @ObservationIgnored private var revertPreviews: [UUID: RevertPreviewEntry] = [:]

    /// The files this thread's agent changed from a turn on, as undoing them would find them.
    /// Only the paths its tools and shell commands touched are looked at, so work done in the
    /// same checkout by other threads or by hand never shows up here, let alone gets undone.
    private func previewRevert(to turnID: UUID) async throws -> RevertPreview {
        guard let app, let thread, let project = app.executionProject(for: thread),
              let index = turns.firstIndex(where: { $0.id == turnID }), let base = turns[index].baseCheckpoint else {
            throw ProviderError.failed("No file checkpoint is available for this message. You can still keep the file changes.")
        }
        let removed = turns[index...]
        let paths = Set(removed.flatMap { $0.touchedPaths ?? [] }).sorted()
        let end = removed.compactMap(\.endCheckpoint).last
        return try await Git(thread.executionDirectory(projectPath: project.path)).previewRestore(base: base, end: end, paths: paths)
    }

    /// Edits a sent message: the conversation rewinds to before its turn, the files it and
    /// everything after it changed are put back when asked, and the edited message goes out
    /// from there. Whatever was in the composer stays there. A rewind that fails throws and
    /// leaves the conversation as it was. Rewound but with the files not restored, the edit
    /// waits in the composer beside the notice instead of going out against the wrong tree.
    func resend(_ turnID: UUID, text: String, attachments: [Attachment], restoreFiles: Bool) async throws {
        let restored = try await revert(to: turnID, restoreFiles: restoreFiles, restoreDraft: false)
        let repaired = Dictionary(uniqueKeysWithValues: branchedAttachments.map { ($0.id, $0) })
        let edited = ComposerDraft(text: text, attachments: attachments.map { repaired[$0.id] ?? $0 })
        guard restored else {
            draft = edited
            return
        }
        let kept = draft
        draft = edited
        send()
        draft = kept
    }

    /// Rewinds the conversation to before a turn, optionally restoring the files it changed.
    /// Throws, with the conversation untouched, when it cannot; returns whether the files
    /// were restored as asked, a failure there being reported in the thread.
    @discardableResult
    func revert(to turnID: UUID, restoreFiles: Bool, restoreDraft: Bool = true) async throws -> Bool {
        // Rewind restores/resumes and mutates the provider's same history. Acquire its
        // idle turn only after a prior archive has finished, just as a new send does.
        await waitForProviderHistory()
        guard canBranchConversation else { throw ProviderError.failed(Chrome.localized("Wait until OMP has finished its current work before branching.")) }
        guard let app, let thread = app.thread(threadID), let project = app.executionProject(for: thread),
              let index = turns.firstIndex(where: { $0.id == turnID }) else {
            throw ProviderError.failed("This message is no longer in the thread.")
        }
        guard app.runningTivanoHeads(of: threadID) == 0 else {
            throw ProviderError.failed("Stop the running agents before reverting this conversation.")
        }
        let removed = Array(turns[index...])
        let directory = thread.executionDirectory(projectPath: project.path)

        isReverting = true
        defer { isReverting = false }
        if restoreFiles {
            guard let base = removed.first?.baseCheckpoint else {
                throw ProviderError.failed("This turn has no file checkpoint. Choose to keep the file changes instead.")
            }
            _ = try await Git(directory).output(["rev-parse", "--verify", base])
        }
        let native = try await nativeHistorySession()
        let history = try await native.nativeHistory()
        await mapNativeHistory(history)
        guard let selected = turns.first(where: { $0.id == turnID }),
              selected.nativeSessionFile == history.sessionFile, let entryID = selected.nativeUserEntryID,
              let userID = selected.userItemID, let userEntry = entryIndex[userID], case .user(let user) = userEntry.item.content else {
            throw ProviderError.failed(Chrome.localized("This native message cannot be reliably linked to the displayed history. The original conversation remains available."))
        }
        // Save a complete GUI view of the original before asking OMP to mutate its
        // active session. A disk failure cannot silently discard the old path.
        var original = thread
        original.id = UUID()
        original.title = String(format: Chrome.localized("%@ (original)"), thread.title)
        original.isPinned = false
        original.hasUnread = false
        original.pendingResultTurnID = nil
        original.hasCustomTitle = true
        var originalDocument = snapshotForPersistence()
        originalDocument.threadID = original.id
        try await DiskWriter.shared.writeOrThrow(originalDocument, to: Storage.threadURL(original.id))
        var originalInserted = false
        defer { if !originalInserted { Storage.deleteDocument(original.id) } }
        let restoredAttachments = try await OMPHistoryAttachments.restore(images: history.activeUserEntries.first { $0.id == entryID }?.message?.images ?? [], keeping: user.attachments)
        let oldPaths = Set(user.attachments.map(\.path))
        let newPaths = restoredAttachments.map(\.path).filter { !oldPaths.contains($0) }
        var attachmentsAdopted = false
        defer { if !attachmentsAdopted { for path in newPaths { try? FileManager.default.removeItem(atPath: path) } } }
        let branch = try await native.branchHistory(entryID: entryID)
        guard !branch.cancelled else {
            throw ProviderError.failed(Chrome.localized("An OMP extension declined this branch. The original conversation is unchanged."))
        }
        let branchTodos = nativeTodoSnapshot
        attachmentsAdopted = true
        app.insertThread(original)
        originalInserted = true
        app.updateThread(threadID) { $0.providerSessionID = branch.sessionFile; $0.providerResumeAt = nil }
        unsentSessionID = nil
        antiSlopFallbackSent = true
        continuationSent = true
        nativeSubmissionDrafts.removeAll()
        nativeSubmissionTurns.removeAll()
        nativeInputGroups.removeAll()
        nativeSeenUserMessages.removeAll()
        nativeRequestsSent.removeAll()
        followUps.removeAll()

        let removedIDs = Set(removed.map(\.id))
        removeEntries { entry in
            // Older builds left idle todo snapshots outside any turn. They
            // cannot survive a rewind and revive the removed list in the chrome.
            if entry.item.turnID == nil, case .todos = entry.item.content { return true }
            guard let turn = entry.item.turnID else { return false }
            return removedIDs.contains(turn)
        }
        entryIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        turns.removeSubrange(index...)
        nativeTodoSteps = nil
        nativeTodoSnapshot = nil
        todosEntryID = nil
        if let branchTodos { upsertTodoSnapshot(branchTodos) }
        // A head's paths list is what the turn in flight has changed; the turn they
        // belonged to is gone.
        hydraCurrentTurnTouchedPaths = []
        // The thread's status is its last remaining turn's, or none: with every turn gone
        // it is unused again, so a new thread reuses it and ⌘W deletes it.
        app.updateThread(threadID) {
            $0.lastStatus = turns.last?.status
            $0.pendingResultTurnID = nil
            $0.hasUnread = false
            $0.unreadRevision = UUID()
        }
        app.updateDockBadge()
        saveRevision += 1
        usage = nil
        appendNotice(.info, String(format: Chrome.localized("Native branch created. Original conversation saved as %@. File restoration is reported separately."), original.title))
        // The new identity and trimmed GUI document are adopted without an await.
        // File restoration may take time but cannot persist the old path under it.
        saveNow()
        var fileError: String?
        var fileNoticeLevel: Notice.Level = .error
        if restoreFiles, let base = removed.first?.baseCheckpoint {
            do {
                let preview = try await Git(directory).previewRestore(base: base,
                    end: removed.compactMap(\.endCheckpoint).last,
                    paths: Set(removed.flatMap { $0.touchedPaths ?? [] }).sorted())
                try await Git(directory).restore(preview.restorable.map(\.path), from: base)
                let kept = preview.files.filter(\.isKept).count
                if kept > 0 {
                    fileError = String(format: Chrome.localized("The native branch was created. Restored %lld files; kept %lld files with later changes."), Int64(preview.restorable.count), Int64(kept))
                    fileNoticeLevel = .warning
                } else {
                    appendNotice(.info, String(format: Chrome.localized("Restored %lld files to the selected checkpoint."), Int64(preview.restorable.count)))
                }
            } catch {
                fileError = String(format: Chrome.localized("The native branch was created, but files could not be restored: %@"), error.localizedDescription)
            }
        }
        if let fileError { appendNotice(fileNoticeLevel, fileError) }
        diffSelection = nil
        diffRevision += 1
        // Preserve typing that may have happened during any of the awaited native
        // or file operations. The old conversation retains its own composer too.
        app.runtime(for: original.id).draft = draft
        branchedAttachments = restoredAttachments
        if restoreDraft { draft = ComposerDraft(text: user.text, attachments: restoredAttachments) }
        scheduleSave()
        return fileError == nil
    }

    /// The files this thread's agent changed across every turn, or nil when it changed none.
    private(set) var changeStats: FileChangeSummary?

    @ObservationIgnored private var changeStatsRevision: Int?

    /// Runs once per diff revision: showing the thread again (switching threads, reopening the
    /// window) reuses what the last run found instead of running git and the parser again.
    func refreshChangeStats() async {
        await ensureLoaded()
        let revision = diffRevision
        guard changeStatsRevision != revision else { return }
        let files = await parsedDiff(selection: nil)
        guard revision == diffRevision else { return }
        let stats = files.isEmpty ? nil : FileChangeSummary(files: files)
        if stats != changeStats { changeStats = stats }
        changeStatsRevision = revision
    }

    /// Parsed patches shared by the changes tab, the diff panel and the historical file
    /// cards. A finished turn's diff is fixed by its checkpoints and reported edits, so it is
    /// kept by turn for the runtime's life (a revert takes the turn, and its entry, away);
    /// the whole thread's and a running turn's move with the revision and go with it.
    /// Concurrent callers share one run.
    @ObservationIgnored private var turnDiffs = RecentCache<UUID, Task<[DiffFile], Never>>(limit: 64)
    @ObservationIgnored private var revisionDiffs = RecentCache<String, Task<[DiffFile], Never>>(limit: 4)
    @ObservationIgnored private var repositoryRootLookup: (directory: URL, id: UUID, task: Task<URL, Never>)?
    @ObservationIgnored private var worktreeRootsLookup: (directory: URL, revision: Int, task: Task<[String], Never>)?

    /// Shared across a revision's card and composer reads. Only explicit edits outside
    /// the known project folders need this lookup; no worktree's contents are scanned.
    private func worktreeRoots(for git: Git) -> Task<[String], Never> {
        if let lookup = worktreeRootsLookup, lookup.directory == git.directory, lookup.revision == diffRevision {
            return lookup.task
        }
        let task = Task { (try? await git.worktreeRoots()) ?? [] }
        worktreeRootsLookup = (git.directory, diffRevision, task)
        return task
    }

    private func repositoryRoot(for git: Git) -> Task<URL, Never> {
        if let lookup = repositoryRootLookup, lookup.directory == git.directory { return lookup.task }
        let id = UUID()
        let task = Task { [weak self] in
            var repository = git.directory
            if let prefix = try? await git.output(["rev-parse", "--show-prefix"]) {
                for _ in prefix.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/") {
                    repository.deleteLastPathComponent()
                }
            }
            if let self, repositoryRootLookup?.id == id { repositoryRootLookup = nil }
            return repository
        }
        repositoryRootLookup = (git.directory, id, task)
        return task
    }

    /// A finished turn's diff outlives revisions; anything else is keyed by the revision.
    private func fixedTurn(_ selection: UUID?) -> UUID? {
        guard let selection, !nativeInputGroups.contains(selection),
              let turn = turns.first(where: { $0.id == selection }), turn.status != .running else { return nil }
        return selection
    }

    private func cachedDiff(selection: UUID?) -> Task<[DiffFile], Never>? {
        if let turn = fixedTurn(selection) { return turnDiffs.value(for: turn) }
        return revisionDiffs.value(for: selection?.uuidString ?? "all")
    }

    private func cacheDiff(_ task: Task<[DiffFile], Never>, selection: UUID?) {
        if let turn = fixedTurn(selection) {
            turnDiffs.insert(task, for: turn)
        } else {
            revisionDiffs.insert(task, for: selection?.uuidString ?? "all")
        }
    }

    func hasCachedDiff(selection: UUID?) -> Bool {
        cachedDiff(selection: selection) != nil
    }

    func turnsWithChanges() -> [TurnRecord] {
        var edited: Set<UUID> = []
        for entry in entries {
            guard let id = entry.turnID, case .tool(let call) = entry.item.content, !call.edits.isEmpty else { continue }
            edited.insert(id)
        }
        return turns.filter { $0.endCheckpoint != nil || $0.providerDiff != nil || $0.touchedPaths?.isEmpty == false || edited.contains($0.id) }
    }

    /// Review follows the same attributed files as the completed turn card.
    /// Merely capturing an end checkpoint does not mean the agent changed files.
    func reviewTurns() -> [TurnRecord] {
        var summaries: [UUID: TurnSummary] = [:]
        var edited = Set<UUID>()
        for entry in entries {
            if case .turnEnd(let summary) = entry.item.content { summaries[summary.turnID] = summary }
            if let id = entry.turnID, case .tool(let call) = entry.item.content, !call.edits.isEmpty { edited.insert(id) }
        }
        return turns.filter { turn in
            if let summary = summaries[turn.id], summary.fileAttributionVersion == TurnSummary.currentFileAttributionVersion {
                return summary.changes?.files.isEmpty == false || summary.filesChanged > 0
            }
            return turn.touchedPaths?.isEmpty == false || turn.providerDiff?.isEmpty == false
                || edited.contains(turn.id) || (summaries[turn.id]?.filesChanged ?? 0) > 0
        }
    }

    /// Older imports can retain a file summary without its patches. Keep those
    /// files visible with an unavailable-diff notice, just as the turn card does.
    func reviewFiles(turnID: UUID) async -> [DiffFile] {
        let parsed = await parsedDiff(selection: turnID)
        guard !Task.isCancelled, let summary = await refreshTurnChanges(turnID: turnID) else { return parsed }
        let known = Set(parsed.map(\.path))
        let metadata = summary.files.filter { !known.contains($0.path) }.map { file in
            DiffFile(path: file.path, change: .modified, isBinary: file.isBinary, hunks: [],
                     reportedAdditions: file.additions, reportedDeletions: file.deletions)
        }
        return (parsed + metadata).sorted { $0.path < $1.path }
    }

    func parsedDiff(selection: UUID?, providerFiles: [DiffFile]? = nil) async -> [DiffFile] {
        if let task = cachedDiff(selection: selection) { return await task.value }
        guard let app, let thread = app.thread(threadID), let project = app.executionProject(for: thread) else { return [] }
        let root = thread.executionDirectory(projectPath: project.path)
        let git = Git(root)
        let repository = repositoryRoot(for: git)
        let selectedTurns = selection.map { id in turns.filter { $0.id == id } } ?? turns
        guard !selectedTurns.isEmpty else { return [] }
        let selectedIDs = Set(selectedTurns.map(\.id))
        // Only this chat's explicit tool edits may contribute outside its checkout.
        // Git verifies task worktrees belonging to the same repository; unrelated
        // scratch files, notes and settings still contribute nothing.
        let projectRoots = app.projects.map(\.path)
        let reportedEdits = entries.flatMap { entry -> [FileEdit] in
            guard let id = entry.turnID, selectedIDs.contains(id), case .tool(let call) = entry.item.content else { return [] }
            return call.edits
        }
        let worktrees = reportedEdits.contains { !Self.isProjectFile($0.path, root: root, projects: projectRoots) }
            ? worktreeRoots(for: git) : nil
        // Only the files this chat's turns reported count. A turn without a record (one cut off
        // by a crash) contributes nothing rather than lifting the filter: the snapshot spans the
        // whole checkout and would otherwise show every merge and other thread's work since the
        // chat began.
        let touched = Set(selectedTurns.flatMap { $0.touchedPaths ?? [] }.map { TouchedPaths.normalize($0, root: root) })
        var span: (first: String, last: String, base: CheckoutSnapshot?, end: CheckoutSnapshot?)?
        if let ended = selectedTurns.lastIndex(where: { $0.endCheckpoint != nil }),
           let first = selectedTurns[...ended].first(where: { $0.baseCheckpoint != nil }),
           let base = first.baseCheckpoint,
           let last = selectedTurns[ended].endCheckpoint {
            span = (base, last, first.baseSnapshot, selectedTurns[ended].endSnapshot)
        }
        let task = Task { () -> [DiffFile] in
            let roots = projectRoots + (await worktrees?.value ?? [])
            let edits = reportedEdits.filter { Self.isProjectFile($0.path, root: root, projects: roots) }
            let repositoryPath = await repository.value.path
            let providerPatch = providerFiles == nil ? selectedTurns.compactMap(\.providerDiff).joined(separator: "\n") : ""
            let reported = providerFiles ?? DiffParser.parse(providerPatch)
            let paths = Set((Array(touched) + reported.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) } + edits.map(\.path)).compactMap { path -> String? in
                guard !path.isEmpty else { return nil }
                let absolute = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path
                return TouchedPaths.relative(absolute, root: repositoryPath)
            })
            var snapshot: String?
            // The paths are the repository's, and git reads a pathspec against the folder it
            // runs in: a project inside a larger repository asks for the whole diff instead.
            let atTop = URL(fileURLWithPath: repositoryPath).resolvingSymlinksInPath().standardizedFileURL.path
                == URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            if let span {
                if let base = span.base, let end = span.end {
                    // Across a HEAD change, use the tools' own patches (including
                    // validated command patches), not the encompassing checkout span.
                    // This also retains this chat's earlier edits if they were committed.
                    if base.head != nil, base.head == end.head {
                        snapshot = try? await git.diff(from: base.tree, to: end.tree, paths: paths.isEmpty || !atTop ? nil : paths.sorted())
                    }
                } else {
                    snapshot = try? await git.diff(from: span.first, to: span.last, paths: paths.isEmpty || !atTop ? nil : paths.sorted())
                }
            }
            return await Self.resolveDiff(repositoryRoot: repository.value.path, snapshot: snapshot, providerPatch: providerPatch, providerFiles: providerFiles, edits: edits, touched: touched, root: root)
        }
        cacheDiff(task, selection: selection)
        return await task.value
    }

    /// Whether a path an agent reported editing lies in the chat's checkout or in another
    /// sidebar project: the files a turn's card and diff can speak for.
    private static func isProjectFile(_ path: String, root: String, projects: [String]) -> Bool {
        TouchedPaths.relative(path, root: root) != nil || projects.contains { TouchedPaths.relative(path, root: $0) != nil }
    }

    @concurrent
    private nonisolated static func resolveDiff(repositoryRoot: String, snapshot: String?, providerPatch: String, providerFiles: [DiffFile]?, edits: [FileEdit], touched: Set<String>, root: String) async -> [DiffFile] {
        TurnDiff.merge(snapshot: snapshot.map { DiffParser.parse($0) }, providerPatch: providerPatch, edits: edits, touched: touched, root: root, repositoryRoot: repositoryRoot, providerFiles: providerFiles)
    }

    @concurrent
    private nonisolated static func parseDiff(_ patch: String) async -> [DiffFile] {
        DiffParser.parse(patch)
    }

    /// Only the session observed last is listened to: one observed before it may still
    /// speak as it closes, and nothing it says reaches the thread.
    func observe(_ provider: any ProviderSession) {
        invalidateInteractions()
        ompRunOptions = OMPRunOptionsSnapshot()
        sessionEpoch += 1
        let epoch = sessionEpoch
        provider.onEvent = { [weak self] event in
            guard let self, self.sessionEpoch == epoch else { return }
            self.handle(event)
        }
    }

    /// Lets a session go: from here on it drives nothing, whatever it still has to say as
    /// it closes. Its handler is cleared a turn of the loop later, because a session that
    /// is ending usually says so from inside that very handler.
    private func releaseSession(stop: Bool, allowDrainingStop: Bool = false) {
        if stop, !allowDrainingStop, (session as? OMPSession)?.isDraining == true { return }
        ompSideQuestion.disconnect()
        invalidateInteractions()
        if stop, session != nil, let app {
            for head in app.hydraTeam(of: threadID) where head.hydra?.kind == .native && head.hydra?.isFinished != true {
                if let id = head.hydra?.nativeID { app.finishOMPAgent(nativeID: id, parentID: threadID, status: .interrupted, summary: nil) }
            }
        }

        backgroundTasks = []
        ompActivity = nil
        ompCapabilities = OMPCapabilities()
        ompExtensionState = OMPExtensionState()
        ompLoginLinks.removeAll()
        lastOMPEditorText = nil
        pendingOMPEditorText = nil
        if ompContextSessionFile == thread?.providerSessionID, ompContextSessionFile != nil {
            ompContext = ompContext.savedSnapshot
            ompContextIsCached = true
        } else {
            ompContext = OMPContextSnapshot()
            ompContextSessionFile = nil
            ompContextIsCached = false
        }
        ompRunOptions = OMPRunOptionsSnapshot()
        ompGoal = OMPGoalSnapshot()
        ompDebug.disconnect()
        for index in followUps.indices where followUps[index].ompState == .accepted || (followUps[index].ompState == .submitting && nativeRequestsSent.contains(followUps[index].id)) {
            followUps[index].ompState = .unknown
            followUps[index].deliveryError = Chrome.localized("OMP disconnected before this message was observed in the conversation. Delivery is unknown; it will not be resent automatically.")
            saveRevision += 1
        }
        scheduleSave()
        opensTurnAfterFinish = false
        deferredBackgroundTurnEvents.removeAll()
        sessionEpoch += 1
        sessionSignature = nil
        unsentSessionID = nil
        // A new session has a new history: whatever the fallback prefix did in the old
        // one, it has to go out again, and a forwarded context needs a new session to
        // land in. Reset before any early return, so a session that was never made still
        // leaves the next one to deliver both.
        antiSlopFallbackSent = false
        continuationSent = false
        guard let old = session else { return }
        session = nil
        app?.refreshVisibleOMPAgentHistories(parentID: threadID)
        if stop {
            sessionsAwaitingReplacement.append(old)
            old.stop()
        }
        Task { old.onEvent = nil }
    }

    private func waitForReplacedSessions() async throws {
        let epoch = sessionEpoch
        let oldSessions = sessionsAwaitingReplacement
        for old in oldSessions {
            await old.stopAndWait(timeout: 2)
            guard sessionEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
        }
        // By identity: another start may have waited on and cleared some of these meanwhile.
        sessionsAwaitingReplacement.removeAll { session in oldSessions.contains { $0 === session } }
    }

    func stopSession() {
        releaseSession(stop: true, allowDrainingStop: true)
        // The session's own end is dropped with it (see `releaseSession`), so a turn cut
        // off here is closed by hand: left running, the thread showed the working line
        // for good once reopened, Return queued instead of sending, a head's lead heard
        // nothing until the budget fired. `finishTurn` saves what the turn had.
        guard phase != .idle else { return }
        // A turn cut off here has events its save timer has not written yet, and the timer
        // may not outlive the runtime.
        saveNow()
        // Nothing is left to end the turn, so it ends here, as interrupted. It leaves
        // `currentTurnID` first, the way a stop during a start does, so a message still on
        // its way to the session never goes.
        let turnID = currentTurnID
        // A finalizer already closing the turn owns the busy runtime until it saves.
        guard turnID != nil || finishingTurnID == nil else { return }
        currentTurnID = nil
        Task { await finishTurn(status: .interrupted, turnID: turnID) }
    }

    // MARK: - Events

    /// Opens the turn Claude started by itself while `finishTurn` was finalizing the one
    /// before, and hands it the events that waited. Returns whether there was one.
    private func replayBackgroundTurn() -> Bool {
        guard opensTurnAfterFinish else { return false }
        opensTurnAfterFinish = false
        let events = deferredBackgroundTurnEvents
        deferredBackgroundTurnEvents.removeAll()
        for event in events { handle(event) }
        return true
    }

    private func openBackgroundTurn() {
        rehearseTurn(nil)
        let name = thread?.provider.displayName ?? Chrome.localized("The agent")
        appendNotice(.info, String(format: Chrome.localized("%@ picked the work back up after a background task finished."), name))
    }

    private func handle(_ event: ProviderEvent) {
        if case .ompSideQuestion(let value) = event { installOMPSideQuestion(value); return }
        // Interactive requests belong to the process, even while a displayed
        // turn is closing. Never buffer them behind the next transcript turn.
        if case .approval(let request) = event {
            approvals.removeAll { $0.id == request.id }
            approvals.append(request)
            let identity = OMPRequestIdentity(threadID: threadID, generation: sessionEpoch, sessionID: nativeRequestSessionID, nativeID: request.id, instanceID: request.instanceID)
            insertInteraction(OMPInteraction(identity: identity, approval: request))
            app?.threadNeedsAttention(threadID)
            return
        }
        if case .question(let request) = event {
            questions.removeAll { $0.id == request.id }
            questions.append(request)
            let identity = OMPRequestIdentity(threadID: threadID, generation: sessionEpoch, sessionID: nativeRequestSessionID, nativeID: request.id, instanceID: request.instanceID)
            insertInteraction(OMPInteraction(identity: identity, question: request))
            app?.threadNeedsAttention(threadID)
            return
        }
        if case .ompRequestEnded(let instanceID, let reason) = event {
            endInteraction(instanceID, reason: reason)
            return
        }
        if case .requestResolved(let id) = event {
            for instanceID in approvals.filter({ $0.id == id }).map(\.instanceID) + questions.filter({ $0.id == id }).map(\.instanceID) {
                endInteraction(instanceID, reason: .cancelled)
            }
            approvals.removeAll { $0.id == id }
            questions.removeAll { $0.id == id }
            return
        }
        if case .ompExtensionReset = event {
            ompExtensionState = OMPExtensionState()
            ompLoginLinks.removeAll()
            pendingOMPEditorText = nil
            lastOMPEditorText = nil
            return
        }
        if case .ompExtensionState(let value) = event { ompExtensionState = value; return }
        if case .ompEditorText(let value) = event {
            if draft.isEmpty || draft.text == lastOMPEditorText {
                draft.text = value
                lastOMPEditorText = value
                pendingOMPEditorText = nil
            } else { pendingOMPEditorText = value }
            return
        }
        if case .ompLoginURL(let link) = event {
            ompLoginLinks.removeAll { $0.id == link.id }
            ompLoginLinks.append(link)
            if ompLoginLinks.count > 4 { ompLoginLinks.removeFirst(ompLoginLinks.count - 4) }
            return
        }
        // Native lifecycle belongs to the process, not a buffered displayed turn.
        if case .ompActivity(let value) = event {
            ompActivity = value
            if !value.hasWork && !value.stopped { app?.publishDeferredResult(threadID) }
            return
        }
        if case .ompCapabilities(let value) = event { ompCapabilities = value; return }
        if case .ompRunOptions(let value) = event { ompRunOptions = value; return }
        if case .ompDebug(let value) = event {
            let previous = ompDebug.archive
            var value = value
            value.retainHistory(from: ompDebug)
            let reveal = value.connected && value.presentationID != nil && value.presentationID != ompDebug.presentationID
            ompDebug = value
            if previous != value.archive { saveRevision += 1; scheduleSave() }
            if reveal { app?.revealDebugPanel(threadID: threadID) }
            return
        }
        if case .ompGoal(let value) = event {
            let previous = ompGoal
            ompGoal = value
            observeOMPGoalConfirmation(value, previous: previous)
            return
        }
        if case .ompPromptOutcome(let id, let status, _) = event {
            if let turnID = nativeSubmissionTurns[id] { nativePromptOutcomes[turnID] = status }
            return
        }
        if case .ompContextRewritten = event {
            antiSlopFallbackSent = false
            continuationSent = false
            usage = nil
            saveRevision += 1
            scheduleSave()
            return
        }
        if case .ompContext(let value) = event {
            let previous = savedOMPContext
            let native = session as? OMPSession
            let file = native.map { $0.sessionFile.isEmpty ? $0.configuration.resumeID : $0.sessionFile }
                ?? thread?.providerSessionID
            if ompContextSessionFile != file { ompContextIsCached = false }
            ompContext = value
            ompContextSessionFile = file
            usage = value.usedTokens.map { ContextUsage(usedTokens: $0, windowTokens: value.windowTokens) }
            if savedOMPContext != previous {
                saveRevision += 1
                scheduleSave()
            }
            return
        }
        if case .ompSubmission(let id, let state, let error) = event {
            if state == .submitting { nativeRequestsSent.insert(id) }
            if state == .failed || state.isTerminal { nativeRequestsSent.remove(id) }
            updateNativeSubmission(id, state: state, error: error)
            return
        }
        noteSessionEvent()
        if opensTurnAfterFinish {
            deferredBackgroundTurnEvents.append(event)
            return
        }
        switch event {
        case .ompActivity, .ompCapabilities, .ompSubmission, .ompContext, .ompRunOptions, .ompGoal, .ompDebug, .ompSideQuestion, .ompContextRewritten, .ompPromptOutcome, .ompExtensionState, .ompEditorText, .ompLoginURL, .ompExtensionReset: break
        case .ompAgentJournalEntry: break // Only a native head may project committed entries.
        case .ompUserMessage(let requestID, let nativeID, let text, let imageCount, let startsNewTurn):
            receiveNativeUserMessage(requestID: requestID, nativeID: nativeID, text: text, imageCount: imageCount, startsNewTurn: startsNewTurn)
        case .sessionReady(let sessionID):
            for item in interactions.values { item.bindNativeSessionIfUnknown(sessionID) }
            if !isReverting { recordSessionID(sessionID) }
        case .turnStarted(let providerTurnID):
            if finishingTurnID != nil, currentTurnID == nil || finishingTurnID == currentTurnID {
                opensTurnAfterFinish = true
                deferredBackgroundTurnEvents.append(event)
                return
            }
            if currentTurnID == nil { openBackgroundTurn() }
            phase = .running
            if let currentTurnID, let providerTurnID {
                updateTurn(currentTurnID) {
                    if $0.providerTurnID == nil { $0.providerTurnID = providerTurnID }
                }
            }
            saveNow()
        case .backgroundTasks(let descriptions):
            backgroundTasks = descriptions
            if descriptions.isEmpty { app?.publishDeferredResult(threadID) }
        case .messageDelta(let id, let text):
            queueDelta(id, .message, text)
        case .messageCompleted(let id, let text):
            flushDeltas()
            completeMessage(id, text: text)
        case .reasoningDelta(let id, let text):
            queueDelta(id, .reasoning, text)
        case .reasoningCompleted(let id, let text):
            flushDeltas()
            completeReasoning(id, text: text)
        case .toolStarted(let id, let call):
            flushDeltas()
            upsertTool(id, call)
            if call.kind == .command, thread?.hydra?.kind != .native { watchCommand(id, call) }
        case .toolOutput(let id, let text):
            queueDelta(id, .toolOutput, text)
        case .toolUpdated(let id, let update):
            flushDeltas()
            applyToolUpdate(id, update)
            if let jobID = update.nativeBackgroundJobID,
               commandTrees[id] != nil || foreignCommandBases[id] != nil { nativeBackgroundCommands[id] = jobID }
            if let entry = entryIndex[id], case .tool(let call) = entry.item.content,
               call.kind == .command, call.status != .running, nativeBackgroundCommands[id] == nil {
                settleCommand(id)
            }
        case .planDelta(let id, let text):
            queueDelta(id, .plan, text)
        case .planCompleted(let id, let markdown):
            flushDeltas()
            completePlan(id, markdown: markdown)
        case .todos(let steps):
            upsertTodoSnapshot(TodoSnapshot(steps: steps))
        case .todoSnapshot(let snapshot):
            upsertTodoSnapshot(snapshot)
        case .approval, .question, .requestResolved, .ompRequestEnded: break
        case .contextUsageCleared:
            usage = nil
            saveRevision += 1
        case .usage(let usage):
            self.usage = usage
            saveRevision += 1
            // The turn just spent from the account, so the balance read before it is stale.
            if let provider = thread?.provider {
                app?.providers.invalidateCredits(provider)
                app?.providers.invalidatePlanLimits(provider)
            }
        case .diff(let diff):
            if currentTurnID != nil { currentProviderDiff = diff }
        case .notice(let notice):
            guard !notice.isRuntimeSetupNoise else { return }
            appendNotice(notice)
        case .usageLimit(let resetsAt):
            app?.autoContinue.noteLimit(threadID, resetsAt: resetsAt)
        case .modeChanged(let mode):
            app?.updateThread(threadID) { $0.interactionMode = mode }
        case .effortChanged(let effort):
            app?.updateThread(threadID) { $0.effort = effort }
        case .fastModeChanged(let enabled):
            app?.updateThread(threadID) { $0.fastMode = enabled }
        case .models(let list, let current):
            if !list.isEmpty { app?.providers.updateCatalog(list, for: .omp) }
            if let current { app?.updateThread(threadID) { $0.model = current } }
        case .commands(let list):
            if let app, let thread, let project = app.executionProject(for: thread) {
                app.providers.updateCommands(list, for: thread.provider, directory: thread.executionDirectory(projectPath: project.path))
            }
        case .title(let title):
            // Provider titles are only a fallback; they must not replace the one Tivano writes.
            guard turns.count <= 1, let app, let thread, !thread.hasCustomTitle,
                  app.textEngine(preferring: thread.provider) == nil else { break }
            app.updateThread(threadID) { $0.title = TextCleanup.withoutEmDashes(title) }
        case .assistantMessageID(let anchor):
            if currentTurnID != nil { currentProviderAnchor = anchor }
        case .turnCompleted(let status, let error):
            flushDeltas()
            let turnID = currentTurnID
            if let error, finishTurnUpdatingCLI(error, status: status, turnID: turnID) { break }
            if let error { appendTerminalError(error) }
            Task { await finishTurn(status: status, turnID: turnID) }
        case .exited(let error):
            backgroundTasks = []
            ompActivity = OMPActivity(stopped: true)
            // Resolve any deferred result as failed after dropping native work.
            // Queued/retrying work may have no generic background-task row.
            app?.publishDeferredResult(threadID, status: .failed)
            flushDeltas()
            // A session that exits while it starts is reported by its `start()` throwing:
            // `ensureSession` starts over where it can, and otherwise the turn ends with
            // that error. Letting the session go here broke the start-over, which needs
            // the session it replaces still in place, and failed the turn before it.
            if isStartingSession { break }
            releaseSession(stop: false)
            approvals.removeAll()
            questions.removeAll()
            if currentTurnID != nil {
                let name = thread?.provider.displayName ?? "The agent"
                let turnID = currentTurnID
                if let error, finishTurnUpdatingCLI(error, status: .failed, turnID: turnID) { break }
                appendTerminalError(error ?? "\(name) stopped unexpectedly.")
                Task { await finishTurn(status: .failed, turnID: turnID) }
            }
        case .tokenSpend(let spend):
            // A provider sub-agent's spend is not this thread's own, as before. Hydra heads
            // never come from there: every head is a thread of its own, with its own spend.
            if spend.agentID == nil { recordTokenSpend(spend) }
        case .agentStarted(let spawn):
            app?.mirrorOMPAgent(spawn, parentID: threadID)
        case .agentTranscriptReset(let id, let observationID):
            app?.resetOMPAgentTranscript(nativeID: id, parentID: threadID, observationID: observationID)
        case .agentTranscriptLoaded(let id, let observationID):
            app?.completeOMPAgentTranscript(nativeID: id, parentID: threadID, observationID: observationID)
        case .agentTranscriptUnavailable(let id, let observationID):
            app?.recoverOMPAgentHistory(nativeID: id, parentID: threadID, observationID: observationID)
        case .agentEvent(let id, let event):
            app?.receiveOMPAgentEvent(event, nativeID: id, parentID: threadID)
        case .agentProgress(let id, let summary, let tool, let tokens, let calls):
            app?.updateOMPAgent(nativeID: id, parentID: threadID, summary: summary, tool: tool, tokens: tokens, calls: calls)
        case .agentFinished(let id, let status, let summary):
            app?.finishOMPAgent(nativeID: id, parentID: threadID, status: status, summary: summary)
        case .agentResult(let id, let observationID, let result, let summary):
            app?.updateOMPAgentResult(nativeID: id, parentID: threadID, observationID: observationID, result: result, summary: summary)
        }
    }

    /// A model newer than the installed CLI fails with the CLI's own "version X or newer
    /// is required". That is not left to the user: the turn ends, the CLI runs its own
    /// updater, and the message goes out again on the new version. Returns whether the
    /// error was taken that way; the caller then neither posts it nor ends the turn.
    private func finishTurnUpdatingCLI(_ error: String, status: TurnStatus, turnID: UUID?) -> Bool { false }

    private func recordTokenSpend(_ spend: TokenSpend) {
        guard spend.totalTokens > 0,
              let index = turns.lastIndex(where: { $0.id == currentTurnID }) ?? (thread?.hydra?.kind == .native ? turns.indices.last : nil) else { return }
        var amounts = turns[index].tokenSpends ?? []
        if let source = amounts.firstIndex(where: { $0.provider == spend.provider && $0.model == spend.model && $0.agentID == spend.agentID }) {
            amounts[source].merge(spend)
        } else {
            amounts.append(spend)
        }
        turns[index].tokenSpends = amounts
        turns[index].latestTokenSpend = spend
        if thread?.hydra != nil { hydraTokens += spend.totalTokens }
        saveRevision += 1
        scheduleSave()
    }

    /// Closes the running turn. `turnID` names the turn when the caller has already taken
    /// it out of `currentTurnID`, as a stop during the start of a turn does, so that the
    /// message on its way can no longer be sent.
    private func ownsTurnFinalization(_ turnID: UUID, generation: UUID, runtimeGeneration: UInt64) -> Bool {
        finishingTurnID == turnID && finishingGeneration == generation
            && runtimeTurnGeneration == runtimeGeneration
            && runtimeOwnerTurnID == turnID
            && (currentTurnID == nil || currentTurnID == turnID)
    }

    private func finishTurn(status: TurnStatus, turnID: UUID?) async {
        // An explicit nil is the caller's snapshot, never a later turn's identity.
        // Neither a stale completion nor an empty fallback may release another owner.
        guard finishingTurnID == nil, finishingGeneration == nil,
              runtimeOwnerTurnID == turnID,
              currentTurnID == nil || currentTurnID == turnID else { return }
        guard let turnID, let turn = turns.first(where: { $0.id == turnID }) else {
            guard currentTurnID == nil, closingTurnID == nil else { return }
            interruptWatchdog?.cancel()
            interruptWatchdog = nil
            headBudget?.cancel()
            headBudget = nil
            phase = .idle
            turnStartedAt = nil
            drainPendingSend()
            return
        }
        guard turn.status == .running else { return }
        let generation = UUID()
        let runtimeGeneration = runtimeTurnGeneration
        finishingTurnID = turnID
        finishingGeneration = generation
        closingTurnID = turnID
        defer {
            if ownsTurnFinalization(turnID, generation: generation, runtimeGeneration: runtimeGeneration) {
                finishingTurnID = nil
                finishingGeneration = nil
                if closingTurnID == turnID { closingTurnID = nil }
            }
        }
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        headBudget?.cancel()
        headBudget = nil
        let userStopped = userStoppedTurnID == turnID
        if userStopped { userStoppedTurnID = nil }
        // Moving the thread can happen while Git settles; its final checkpoint
        // still belongs to the checkout where this turn ran.
        let finalizationRoot: String?
        if let app, let thread = app.thread(threadID), let project = app.executionProject(for: thread) {
            finalizationRoot = thread.executionDirectory(projectPath: project.path)
        } else {
            finalizationRoot = nil
        }
        // Command diffs land before the turn's own summary counts them, and
        // while the turn is still current so the snapshots can be compared, including a
        // command's edits in another checkout it cd'd into.
        for id in Array(commandTrees.keys) + Array(foreignCommandBases.keys) { settleCommand(id) }
        guard ownsTurnFinalization(turnID, generation: generation, runtimeGeneration: runtimeGeneration) else { return }
        // A finished turn waits for its diffs; a stopped or failed one gives them three
        // seconds and lets the rest land on their own, so Stop never hangs on git.
        let settles = Array(commandSettles.values)
        commandSettles.removeAll()
        if status == .completed {
            for task in settles {
                await task.value
                guard ownsTurnFinalization(turnID, generation: generation, runtimeGeneration: runtimeGeneration) else { return }
            }
        } else {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for task in settles { await task.value } }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
        }
        guard ownsTurnFinalization(turnID, generation: generation, runtimeGeneration: runtimeGeneration) else { return }
        currentTurnID = nil
        flushDeltas()
        if thread?.provider != .omp {
            approvals.removeAll()
            questions.removeAll()
        }
        // One pass over the turn's rows: they are closed, and the files their tools
        // reported are collected for the summary below rather than scanned for again.
        var reportedEdits: [FileEdit] = []
        for entry in entries where entry.item.turnID == turnID {
            endStreaming(entry)
            guard case .tool(var call) = entry.item.content else { continue }
            if call.status == .running {
                call.finish(status == .completed ? .completed : .failed)
                entry.item.content = .tool(call)
                saveRevision += 1
            }
            reportedEdits.append(contentsOf: call.edits)
        }
        let providerDiff = currentProviderDiff
        let providerAnchor = currentProviderAnchor
        currentProviderDiff = nil
        currentProviderAnchor = nil
        updateTurn(turnID) {
            $0.status = status
            $0.completedAt = .now
            if let providerDiff { $0.providerDiff = providerDiff }
            if let providerAnchor { $0.providerAnchor = providerAnchor }
        }
        if let providerAnchor, thread?.providerResumeAt != nil {
            app?.updateThread(threadID) { $0.providerResumeAt = providerAnchor }
        }

        let providerPatch = providerDiff ?? turns.first(where: { $0.id == turnID })?.providerDiff ?? ""
        // Parsed off the main actor, and only once: a turn's patch can be large, and
        // this lands exactly as the reply appears.
        let providerFiles = providerPatch.isEmpty ? [] : await Self.parseDiff(providerPatch)
        guard ownsTurnFinalization(turnID, generation: generation, runtimeGeneration: runtimeGeneration) else { return }
        if let root = finalizationRoot {
            let git = Git(root)
            var endCheckpoint: String?
            var endSnapshot: CheckoutSnapshot?
            // Native steering/follow-ups create display groups without a Git
            // boundary. Their original admitted prompt still owns the known base.
            let checkpointTurn = ([turn] + nativeInputGroups.compactMap { id in turns.first { $0.id == id } })
                .first { $0.baseCheckpoint != nil }
            if let checkpointTurn {
                let ref = Git.checkpointRef(thread: threadID, turn: checkpointTurn.id, phase: "end")
                if let snapshot = try? await git.captureCheckpoint(ref) {
                    endCheckpoint = ref
                    endSnapshot = snapshot
                }
                guard ownsTurnFinalization(turnID, generation: generation, runtimeGeneration: runtimeGeneration) else { return }
            }
            // Only files this thread's agent edited count, never edits made elsewhere in
            // the repository meanwhile. A path outside the checkout is no part of the turn:
            // the agent writes to its own notes and settings too, and git cannot stage a
            // file it does not hold.
            var touched = Set<String>()
            for edit in reportedEdits {
                if let path = TouchedPaths.relative(edit.path, root: root) { touched.insert(path) }
            }
            // The provider's own repository diff is no part of a turn's record, because
            // it spans every file that changed in the checkout while the turn ran, another
            // chat's work included, and one such file was once merged out under a chat that
            // had changed nothing; a change of the turn that no edit reported is caught by
            // the merge's checkout sweep instead.
            let touchedPaths = touched.sorted()
            // One write of `turns`: every write re-evaluates the timeline body.
            updateTurn(turnID) {
                if let endCheckpoint { $0.endCheckpoint = endCheckpoint }
                $0.endSnapshot = endSnapshot
                $0.touchedPaths = touchedPaths
            }
            // The turn is done touching: the live set is folded in so it holds the turn's
            // finished paths for any head that asks afterwards what this turn changed
            // (see `hydraCurrentTurnTouchedPaths`). It is cleared in `startTurn`,
            // `install` and `revert`, not here.
            hydraCurrentTurnTouchedPaths.formUnion(touched)
            await finishNativeInputGroups(status: status, root: root, endCheckpoint: endCheckpoint, endSnapshot: endSnapshot)
        } else {
            await finishNativeInputGroups(status: status, root: nil, endCheckpoint: nil, endSnapshot: nil)
        }
        guard ownsTurnFinalization(turnID, generation: generation, runtimeGeneration: runtimeGeneration) else { return }
        nativePromptOutcomes[turnID] = nil
        diffRevision += 1
        let changes = FileChangeSummary(files: await parsedDiff(selection: turnID, providerFiles: providerFiles))
        guard ownsTurnFinalization(turnID, generation: generation, runtimeGeneration: runtimeGeneration) else { return }

        let summary = TurnSummary(
            turnID: turnID,
            status: status,
            duration: Date.now.timeIntervalSince(turn.startedAt),
            filesChanged: changes.files.count,
            additions: changes.additions,
            deletions: changes.deletions,
            changes: changes,
            fileAttributionVersion: TurnSummary.currentFileAttributionVersion
        )
        append(TimelineItem(turnID: turnID, content: .turnEnd(summary)))
        phase = .idle
        turnStartedAt = nil
        // The turn's own events shared one save every few seconds; whatever they left is
        // written here, so a finished turn is always on disk.
        saveNow()
        let budgetSpent = headBudgetSpent
        headBudgetSpent = false
        // Continuations can open a new turn synchronously while replaying events.
        // Release only this finalizer before handing them the runtime.
        finishingTurnID = nil
        finishingGeneration = nil
        closingTurnID = nil
        guard thread?.isArchived != true else {
            let continues = replayBackgroundTurn()
            app?.turnFinished(threadID, status: status, continues: continues, turnID: turnID, userStopped: userStopped)
            return
        }
        // The Return-while-running message jumps the queue: it goes right away
        // and anything queued waits for it. A reply that ends in a delegation block
        // sends the heads out instead, and their reports come back as a message of
        // their own; the lead is free meanwhile, so the next queued prompt starts on
        // it at once rather than waiting out the heads, and the reports follow that
        // turn. Either way the app hears whether a next turn is on its way, so
        // "finished" only sounds when nothing is.
        var continues: Bool
        if replayBackgroundTurn() {
            continues = true
        } else if pendingSend != nil {
            continues = drainPendingSend()
        } else if status == .completed, case let delegation = spawnDelegatedHeads(for: turnID), delegation != .none {
            continues = true
            if delegation == .headsOut { _ = drainFollowUps(after: status) }
        } else if status == .completed, flushHydraReports() {
            continues = true
        } else {
            // A turn that failed or was stopped with a block in its reply: the block leaves
            // the reply and a note says no heads went out, rather than the raw block
            // sitting there as if something were coming.
            if status != .completed { dropDelegationBlock(for: turnID, status: status) }
            continues = drainFollowUps(after: status)
        }
        // Reports that came in while this turn ran are heard whatever became of it. Only a
        // turn the user stopped is left alone, as their queued messages are: they are in
        // charge of the chat then, and the reports go out with their next word.
        if !continues, status != .interrupted, flushHydraReports() { continues = true }
        // Heads still out will report, and the lead will work again: the job is not
        // finished until it has heard from all of them.
        if !continues, status == .completed, let app, app.runningTivanoHeads(of: threadID) > 0 { continues = true }
        // A head stopped for its budget writes its report as its next turn, so its lead
        // hears what it managed rather than only that it was stopped.
        if budgetSpent {
            if status == .interrupted, thread?.hydra?.kind == .tivano {
                headReportsNext = true
                // This turn starts on its own (see autoStartedTurnToken).
                autoStartedTurnToken &+= 1
                Task { await ensureLoaded(); await startTurn(text: HydraBudget.finalNote, attachments: []) }
                continues = true
            }
        }
        app?.turnFinished(threadID, status: status, continues: continues, turnID: turnID, userStopped: userStopped)
        // The job is done: the lead has answered, every head is back and nothing is
        // waiting. With the setting on, the work goes out and lands by itself, whether
        // heads took part or the lead did it all; a job that changed no file is let be.
        // A merge while any head is still at work would commit its half-done files and
        // then, the head having finished before the next turn began, never come back for
        // the rest.
        if !continues, status == .completed,
           hydraPendingReports.isEmpty, hydraBatches.isEmpty, hydraWaiting.isEmpty,
           let app, let thread, app.hydraIsOn(thread), app.settings.hydraAutoMerge,
           app.runningHydraHeads(of: threadID) == 0 {
            Task { await app.autoMergeHydraWork(of: threadID) }
        }
    }

    /// Sends the message captured by Return while a turn ran, once the stop
    /// lands. Runs for any finish status: if the turn completed on its own in
    /// the meantime, the message still goes right away. Returns whether a turn starts.
    @discardableResult
    private func drainPendingSend() -> Bool {
        guard phase == .idle, let pending = pendingSend else { return false }
        pendingSend = nil
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pending.attachments.isEmpty else {
            scheduleSave()
            return false
        }
        if handleLocalCommand(text) { return false }
        Task { await ensureLoaded(); await startTurn(text: pending.text, attachments: pending.attachments) }
        return true
    }

    // MARK: - Hydra

    /// An idle provider may still have a report or a user message waiting to run.
    /// Those continuations must finish before its files take part in a merge.
    var isReadyForHydraMerge: Bool {
        phase == .idle && !isLoadingHistory && !isReverting && pendingSend == nil
            && turns.last?.status == .completed && !hasWorkingHeads
            && hydraPendingReports.isEmpty && hydraBatches.isEmpty && hydraWaiting.isEmpty
            && !hydraFlushScheduled
    }

    /// The auto-merge has landed these turns' work: the next merge starts from what came
    /// after them, rather than offering the same files again.
    func markHydraMerged(_ turnIDs: [UUID]) {
        let ids = Set(turnIDs)
        var changed = false
        for index in turns.indices where ids.contains(turns[index].id) && !turns[index].hydraMerged {
            turns[index].hydraMerged = true
            changed = true
        }
        guard changed else { return }
        saveRevision += 1
        saveNow()
    }

    /// The turns whose work has not been merged yet, oldest first.
    var hydraUnmergedTurns: [TurnRecord] {
        turns.filter { !$0.hydraMerged }
    }

    /// The auto-merge's latest outcome for this thread, kept for the lead's next message.
    func recordHydraMerge(_ record: HydraMergeRecord) {
        hydraMerges.append(record)
        if hydraMerges.count > 20 { hydraMerges.removeFirst(hydraMerges.count - 20) }
        saveRevision += 1
        saveNow()
    }

    /// How many distinct files the finished, unmerged turns of this thread touched.
    var hydraUnmergedFileCount: Int {
        Set(hydraUnmergedTurns.filter { $0.status != .running }.flatMap { $0.touchedPaths ?? [] }).count
    }

    /// The head a tool row in this timeline sent out, if any.
    func hydraHeads(forTool toolID: String) -> [UUID] {
        guard let app else { return hydraToolHeads[toolID] ?? [] }
        let owner = thread?.hydra?.kind == .native ? thread?.parentThreadID ?? threadID : threadID
        let nativeID = OMPAgentJournal.toolID(toolID)
        let saved = app.children(of: owner).filter {
            $0.id != threadID && $0.hydra?.toolUseID.map(OMPAgentJournal.toolID) == nativeID
        }.sorted { ($0.hydra?.index ?? 0) < ($1.hydra?.index ?? 0) }.map(\.id)
        return saved.isEmpty ? hydraToolHeads[toolID] ?? [] : saved
    }

    func hydraHead(forTool toolID: String) -> UUID? {
        hydraHeads(forTool: toolID).first
    }

    /// Captures-only mapping of a tool row to its head thread.
    func rehearseHydraHead(toolID: String, headID: UUID) {
        if !(hydraToolHeads[toolID] ?? []).contains(headID) { hydraToolHeads[toolID, default: []].append(headID) }
    }

    /// The app finished a head of this lead's (see `AppModel.finishHydraHead`): an older
    /// version's native head has its tool row completed; a Tivano-run head's report goes to
    /// the lead, once its batch is complete. A head reporting again (steered on from the
    /// panel) replaces any report of its own still waiting.
    func hydraHeadFinished(_ headID: UUID, info: HydraHeadInfo, status: HydraHeadInfo.Status, summary: String?, landing: HydraLanding? = nil, copyPath: String? = nil) {
        switch info.kind {
        case .native:
            flushFollowUpsIfIdle()
        case .tivano:
            let report = HydraReport(
                headIndex: info.index, task: info.task, origin: info.origin, status: status, text: summary ?? "",
                landing: landing, copyPath: copyPath, elapsed: Date.now.timeIntervalSince(info.startedAt), toolCalls: info.toolCalls
            )
            hydraPendingReports.removeAll { $0.headIndex == info.index }
            if let batchID = info.batchID, hydraBatches[batchID] != nil {
                hydraBatches[batchID]?.pending.remove(headID)
                hydraBatches[batchID]?.reports.removeAll { $0.headIndex == info.index }
                hydraBatches[batchID]?.reports.append(report)
            } else {
                hydraPendingReports.append(report)
            }
            // A finished head makes room: for a task still waiting in a batch first, then
            // for whatever the user queued while every head was busy.
            spawnWaitingHeads()
            dispatchQueuedFollowUps()
            settleBatches()
            // An idle lead hears at once; one the user stopped waits for their next word.
            if phase == .idle, thread?.lastStatus != .interrupted { flushHydraReports() }
            // After the reports: whatever is still queued behind an idle lead goes
            // next, rather than waiting out the heads still at work.
            flushFollowUpsIfIdle()
        }
    }

    /// A batch with every head back and nothing left to send out hands its reports over.
    private func settleBatches() {
        for (batchID, batch) in hydraBatches where batch.pending.isEmpty && !hydraWaiting.contains(where: { $0.batchID == batchID }) {
            hydraBatches[batchID] = nil
            hydraPendingReports += batch.reports.sorted { $0.headIndex < $1.headIndex }
        }
    }

    /// Sends the reports waiting on an idle lead as one message. Returns whether a turn
    /// starts. The reports stay put until the turn takes them: heads finishing together
    /// then go out as one message, instead of each starting a turn the next one cuts short.
    @discardableResult
    private func flushHydraReports() -> Bool {
        guard phase == .idle, !hydraFlushScheduled, !flushableHydraReports().isEmpty else { return false }
        hydraFlushScheduled = true
        // This turn starts on its own (see autoStartedTurnToken).
        autoStartedTurnToken &+= 1
        Task { await startHydraReportTurn() }
        return true
    }

    /// The reports an idle lead can hear now: every one waiting. A delegation's reports
    /// only get here once its whole batch is back (see `settleBatches`), and a head the
    /// user queued or sent out directly has nothing to do with a batch; neither waits on
    /// another delegation still out, which can mean waiting out a job of twenty minutes.
    private func flushableHydraReports() -> [HydraReport] {
        hydraPendingReports.sorted { $0.headIndex < $1.headIndex }
    }

    /// The turn `flushHydraReports` scheduled. A lead no longer idle (the user got a word
    /// in first) keeps the reports waiting for the end of that turn instead.
    private func startHydraReportTurn() async {
        // Cleared first and the reports left where they are: a turn that cannot run now
        // must be able to be asked for again, by the next head to finish or by the end of
        // whatever the lead is doing instead.
        hydraFlushScheduled = false
        guard phase == .idle, !isReverting, let app else { return }
        let reports = flushableHydraReports()
        guard !reports.isEmpty else { return }
        let sent = Set(reports.map(\.headIndex))
        hydraPendingReports.removeAll { sent.contains($0.headIndex) }
        let stillWorking = app.workingHydraHeadNames(of: threadID, excluding: sent)
        let text = HydraPrompts.reportMessage(reports, stillWorking: stillWorking, reviewsHeads: app.settings.hydraReviewHeads)
        await ensureLoaded()
        await startTurn(text: text, attachments: [], hydraHeads: reports.map(\.headIndex))
    }

    /// How many tasks one delegation block may send out. Well past what a lead writes in
    /// practice, and the pair's cap still decides how many run at a time.
    private static let maxDelegatedTasks = 32

    /// What a reply's delegation block led to, for the end of the turn.
    private enum DelegationOutcome {
        /// No block, or nothing came of it.
        case none
        /// Heads went out; the lead is free until they report.
        case headsOut
        /// The lead is being told something instead, in a turn of its own already on its way.
        case turnStarted
    }

    /// A reply row of a turn that did not finish, holding a block: the block leaves it,
    /// and the timeline says the heads never went out.
    private func dropDelegationBlock(for turnID: UUID, status: TurnStatus) {
        if let stream = hydraStream, stream.turnID == turnID, stream.sent > 0,
           let streamedEntry = entryIndex[stream.entryID],
           case .assistant(var streamedMessage) = streamedEntry.item.content {
            endDelegationStream()
            streamedMessage.text = HydraPrompts.withoutDelegationBlock(streamedMessage.text)
            if streamedMessage.text.isEmpty { streamedMessage.text = "Asked for heads." }
            streamedEntry.item.content = .assistant(streamedMessage)
            saveRevision += 1
            scheduleSave()
            settleBatches()
            appendHydraNote("Hydra sent \(stream.sent == 1 ? "one head" : "\(stream.sent) heads") before the turn \(status == .interrupted ? "was stopped" : "failed"); the rest of the block never went out. Ask again to send them.")
            return
        }
        if let stream = hydraStream, stream.turnID == turnID, stream.sent == 0 { endDelegationStream() }
        guard let entry = entries.last(where: { $0.turnID == turnID && $0.kind == .assistant && Self.holdsDelegationBlock($0) }),
              case .assistant(var message) = entry.item.content else { return }
        message.text = HydraPrompts.withoutDelegationBlock(message.text)
        if message.text.isEmpty { message.text = "Asked for heads." }
        entry.item.content = .assistant(message)
        saveRevision += 1
        scheduleSave()
        appendHydraNote("Hydra sent no heads: the turn \(status == .interrupted ? "was stopped" : "failed") before they could go out. Ask again to send them.")
        // The timeline note is for the UI; the lead hears it too, on its next turn.
        hydraBudget.noteDropped(HydraPrompts.interruptedBlockMessage(stopped: status == .interrupted))
    }

    private static func holdsDelegationBlock(_ entry: TimelineEntry) -> Bool {
        guard case .assistant(let message) = entry.item.content else { return false }
        return HydraPrompts.hasDelegationBlock(in: message.text)
    }

    /// A reply on any provider may end in a delegation block: its tasks go out as
    /// Tivano-run heads, up to the pair's limit at a time, and the block leaves the reply.
    /// A block Tivano cannot read leaves the reply as well, and the lead hears so in
    /// a turn of its own: a block never stays in a reply doing nothing.
    private func spawnDelegatedHeads(for turnID: UUID) -> DelegationOutcome {
        .none
    }

    /// The delegation card keeps its place for `HydraPrompts.delegationSentHold` once the
    /// heads are out, wearing its done wave. Then it fades where it stands, still holding
    /// its room (`hydra-leaving`), and only once it is gone from sight does the block leave
    /// the reply and the text below close up: two steps, so the card never fades over
    /// content that has already moved up under it.
    private func holdSentDelegationBlock(_ entryID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: HydraPrompts.delegationSentHold)
            guard let self, let entry = self.entryIndex[entryID],
                  case .assistant(var message) = entry.item.content,
                  HydraPrompts.hasSentDelegationBlock(in: message.text) else { return }
            message.text = HydraPrompts.markingDelegationBlockLeaving(message.text)
            withAnimation(.easeOut(duration: 0.4)) { entry.item.content = .assistant(message) }
            try? await Task.sleep(for: HydraPrompts.delegationLeaveFade)
            guard case .assistant(var faded) = entry.item.content,
                  HydraPrompts.hasSentDelegationBlock(in: faded.text) else { return }
            faded.text = HydraPrompts.withoutDelegationBlock(faded.text)
            if faded.text.isEmpty { faded.text = "Sent out heads." }
            withAnimation(Chrome.panelSlide) { entry.item.content = .assistant(faded) }
            self.saveRevision += 1
            self.scheduleSave()
        }
    }

    /// Tells the lead, in a turn of its own, that the block its reply ended in sent no heads
    /// out, and why: `message` is what it hears. Only so many times per request (see
    /// `HydraDelegationBudget.maxRefusals`): a lead that keeps answering with the same block
    /// would otherwise be answered with the same refusal, turn after turn, for as long as the
    /// app runs. Past the cap the block is dropped with a note in the timeline saying
    /// `dropped`, and the turn ends as a plain reply would — but the refusal also rides on
    /// the front of the lead's next turn, so a drop is never quieter than a refusal.
    private func refuseBlock(_ message: String, dropped: String) -> DelegationOutcome {
        guard hydraBudget.refuse(message) else {
            appendHydraNote("No heads went out\n\(dropped) The block was dropped from the reply.")
            return .none
        }
        Task { await ensureLoaded(); await startTurn(text: message, attachments: [], hydraHeads: []) }
        return .turnStarted
    }

    /// Heads go out as their entries close so the first is at work while the lead writes
    /// the rest; the batch is made on the first entry and the round counted then; the cap
    /// paces the rest through `hydraWaiting`; `spawnDelegatedHeads` finishes the block
    /// at the end of the turn.
    ///
    /// The block is read by `delegationParser`, which keeps its place in the row between
    /// flushes, so a long reply is walked once rather than from the top on every flush.
    /// `text` is the row's text as it stands; the parser takes only what has arrived since
    /// the last flush. Entries are held to once per parser: the count already out lives in
    /// `hydraStream`, so a re-read row cannot send a head twice.
    private func scanStreamedDelegations(entryID: String, turnID: UUID, text: String, isDelta: Bool = false) {
        return
    }

    /// Ends the streamed block and the reader that held its place. Called wherever the
    /// block is finished with (`dropDelegationBlock`, `spawnDelegatedHeads`, a new turn), so
    /// the next block is read by a parser that starts where that block does.
    private func endDelegationStream() {
        hydraStream = nil
        delegationParser = nil
    }

    /// Sends out delegated tasks still waiting, as far as the pair's cap allows; without
    /// a pair, or an uncapped one, all of them.
    private func spawnWaitingHeads(launch: HydraLaunch? = nil) {
        return
    }

    // MARK: - Timeline mutations

    /// A note from Hydra in the timeline, with no turn behind it: what it merged, what it
    /// could not. Its first line is its title. An `id` lets the note land under an identity
    /// the timeline is already drawing (the merging pill, see `hydraMergeNoteID`).
    func appendHydraNote(_ text: String, id: String? = nil) {
        append(TimelineItem(id: id ?? UUID().uuidString, turnID: nil, content: .user(UserMessage(text: text, hydraHeads: []))))
        app?.updateThread(threadID) { $0.updatedAt = .now }
        scheduleSave()
    }

    private func append(_ original: TimelineItem) {
        var item = original
        if case .notice = item.content, let nativeJournalEntryID {
            item.id = "omp-native-notice-\(nativeJournalEntryID)-\(nativeJournalNoticeIndex)"
            nativeJournalNoticeIndex += 1
        }
        if let nativeJournalDate { item.date = nativeJournalDate }
        if case .tool(var call) = item.content, let nativeJournalDate {
            call.startedAt = nativeJournalDate
            item.content = .tool(call)
        }
        for entry in entries.suffix(6) { endStreaming(entry) }
        if let last = entries.last, let merged = last.item.mergingConsecutiveNotice(item) {
            last.item = merged
            saveRevision += 1
            return
        }
        let entry = TimelineEntry(item)
        bindEntry(entry)
        entries.append(entry)
        if entry.kind == .todos { latestTodoEntry = entry }
        entryIndex[item.id] = entry
        saveRevision += 1
    }

    private func remove(_ id: String) {
        removeEntries { $0.id == id }
        entryIndex[id] = nil
        streamByteLengths[id] = nil
        saveRevision += 1
    }

    private func endStreaming(_ entry: TimelineEntry) {
        switch entry.item.content {
        case .assistant(var message) where message.isStreaming:
            message.isStreaming = false
            entry.item.content = .assistant(message)
        case .reasoning(var block) where block.isStreaming:
            block.isStreaming = false
            entry.item.content = .reasoning(block)
        case .plan(var plan) where plan.state == .drafting:
            plan.state = .proposed
            entry.item.content = .plan(plan)
        default:
            break
        }
    }

    private func queueDelta(_ id: String, _ kind: DeltaKind, _ text: String) {
        if entryIndex[id] == nil {
            switch kind {
            case .message:
                // Not until there is something to read: some providers open a text block
                // with an empty delta, and some punctuate a pause between tool calls with a
                // lone "."; either would leave a row with nothing on it behind.
                guard TextCleanup.hasSomethingToRead(text) else { return }
                append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .assistant(AssistantMessage(text: "", isStreaming: true))))
            case .reasoning:
                // Not until there is something to read: a redacted thinking block
                // only ever sends empty deltas and would leave a blank entry behind.
                guard !text.isEmpty else { return }
                append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .reasoning(ReasoningBlock(text: "", isStreaming: true))))
            case .plan:
                append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .plan(ProposedPlan(markdown: "", state: .drafting))))
            case .toolOutput:
                return
            }
        }
        guard !text.isEmpty else { return }
        // Prose is flattened as it streams, so a reply can never render an em dash.
        // Tool output is process text, not the model's own writing, and passes through.
        let prose = kind == .toolOutput ? text : TextCleanup.withoutEmDashes(text)
        pendingDeltas[id, default: PendingDelta(kind: kind, text: "")].text += prose
        if kind != .toolOutput {
            let base = streamByteLengths[id] ?? {
                switch entryIndex[id]?.item.content {
                case .assistant(let message): return message.text.utf8.count
                case .reasoning(let block): return block.text.utf8.count
                case .plan(let plan): return plan.markdown.utf8.count
                default: return 0
                }
            }()
            streamByteLengths[id] = base + prose.utf8.count
            pendingFlushBytes = max(pendingFlushBytes, base + prose.utf8.count)
        }
        let isHead = thread?.hydra != nil
        if isHead { StreamLoad.shared.noteStreaming(self) }
        var delay = Self.flushDelay(for: pendingFlushBytes, scrolling: ScrollActivity.shared.isScrolling)
        if isHead { delay = max(delay, StreamLoad.shared.headFlushDelayMilliseconds) }
        let remaining = Duration.milliseconds(delay) - (ContinuousClock.now - lastFlushAt)
        let firstVisible: Bool
        switch entryIndex[id]?.item.content {
        case .assistant(let message): firstVisible = message.text.isEmpty
        case .reasoning(let block): firstVisible = block.text.isEmpty
        case .plan(let plan): firstVisible = plan.markdown.isEmpty
        default: firstVisible = false
        }
        if firstVisible || remaining <= .zero {
            flushDeltas()
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            self?.flushDeltas()
        }
    }

    /// How long to wait before flushing deltas onto their rows: one display frame (16 ms)
    /// up to 8 KB of UTF-8, 45 ms up to 64 KB (roughly two bytes per prose character), 90 ms
    /// beyond. A frame's worth of tokens at a time is what makes a reply read as written
    /// rather than dropped in: each flush lands as a small chunk the veil dissolves in, and
    /// the parse only ever touches the block still being written.
    private nonisolated static func flushDelay(for length: Int?, scrolling: Bool) -> Int {
        let paced = switch length ?? 0 {
        case ..<8_192: 16
        case ..<65_536: 45
        default: 90
        }
        // Under a scrolling reader the row is not being read: it takes at most six
        // flushes a second then, so the frames of the scroll are not spent laying the
        // streaming text out again (in the chat and in every head panel at once).
        return scrolling ? max(paced, 160) : paced
    }


    /// How many runtimes are streaming onto the screen right now, so a head's flushes
    /// slow down as more heads talk at once. One head flushes at its own pace; with N
    /// heads streaming, each waits about N times `headFlushBudget`, which keeps the
    /// whole team to roughly one panel re-layout every `headFlushBudget` regardless of
    /// how many heads went out. A runtime that has not flushed for two seconds no longer
    /// counts, so a head that went quiet stops slowing the others.
    @MainActor
    final class StreamLoad {
        static let shared = StreamLoad()
        /// The interval the whole team of heads shares, in milliseconds.
        private static let headFlushBudget = 70
        private static let stale: Duration = .seconds(2)
        private var lastSeen: [ObjectIdentifier: ContinuousClock.Instant] = [:]

        func noteStreaming(_ runtime: ThreadRuntime) {
            lastSeen[ObjectIdentifier(runtime)] = .now
        }

        func forget(_ runtime: ThreadRuntime) {
            lastSeen[ObjectIdentifier(runtime)] = nil
        }

        /// Runtimes that flushed within the last two seconds.
        var streamingCount: Int {
            let now = ContinuousClock.now
            lastSeen = lastSeen.filter { now - $0.value < Self.stale }
            return lastSeen.count
        }

        /// The least a head waits between two flushes while `streamingCount` heads talk.
        var headFlushDelayMilliseconds: Int {
            max(45, streamingCount * Self.headFlushBudget)
        }

    }

    private func flushDeltas(scheduleSave: Bool = true) {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingDeltas.isEmpty else { return }
        let span = RuntimeMetrics.begin(.streamFlush)
        defer { RuntimeMetrics.end(span) }
        lastFlushAt = .now
        let deltas = pendingDeltas
        pendingDeltas.removeAll()
        pendingFlushBytes = 0
        var heard = false
        var streamedRows: [(id: String, delta: String)] = []
        for (id, delta) in deltas {
            // Appended in place (see `appendStreamed`): binding the payload out of the enum
            // copied the whole message on every flush.
            guard let entry = entryIndex[id], entry.item.content.appendStreamed(delta.text, kind: delta.kind) else { continue }
            saveRevision += 1
            if delta.kind != .plan { heard = true }
            if delta.kind == .message, entry.kind == .assistant { streamedRows.append((id, delta.text)) }
        }
        // Once per flush, not per word: a head still talking is a head still at work.
        if heard { noteHydraHeadEvent() }
        if let turnID = currentTurnID {
            for row in streamedRows {
                scanStreamedDelegations(entryID: row.id, turnID: turnID, text: row.delta, isDelta: true)
            }
        }
        if scheduleSave { self.scheduleSave() }
    }

    private func completeMessage(_ id: String, text: String) {
        streamByteLengths[id] = nil
        let text = TextCleanup.withoutEmDashes(text)
        guard let entry = entryIndex[id] else {
            guard TextCleanup.hasSomethingToRead(text) else { return }
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .assistant(AssistantMessage(text: text))))
            return
        }
        guard case .assistant(var message) = entry.item.content else { return }
        if !text.isEmpty { message.text = text }
        message.isStreaming = false
        if TextCleanup.hasSomethingToRead(message.text) {
            entry.item.content = .assistant(message)
            saveRevision += 1
            if let turnID = currentTurnID { scanStreamedDelegations(entryID: id, turnID: turnID, text: message.text) }
        } else {
            remove(id)
        }
        scheduleSave()
    }

    private func completeReasoning(_ id: String, text: String) {
        streamByteLengths[id] = nil
        let text = TextCleanup.withoutEmDashes(text)
        guard let entry = entryIndex[id], case .reasoning(var block) = entry.item.content else {
            guard !text.isEmpty else { return }
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .reasoning(ReasoningBlock(text: text))))
            return
        }
        if !text.isEmpty { block.text = text }
        block.isStreaming = false
        if !block.text.contains(where: { !$0.isWhitespace }) {
            remove(id)
        } else {
            entry.item.content = .reasoning(block)
            saveRevision += 1
        }
        scheduleSave()
    }

    private func completePlan(_ id: String, markdown: String) {
        let markdown = TextCleanup.withoutEmDashes(markdown)
        if let entry = entryIndex[id], case .plan(var plan) = entry.item.content {
            if !markdown.isEmpty { plan.markdown = markdown }
            plan.state = .proposed
            entry.item.content = .plan(plan)
            saveRevision += 1
        } else if !markdown.isEmpty {
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .plan(ProposedPlan(markdown: markdown, state: .proposed))))
        }
        scheduleSave()
    }

    private func upsertTool(_ id: String, _ call: ToolCall) {
        noteToolMayWrite(call.kind)
        recordCurrentTurnEdits(call.edits)
        var call = call
        call.edits = Self.capped(call.edits)
        guard let entry = entryIndex[id], case .tool(var existing) = entry.item.content else {
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .tool(call)))
            noteHydraHeadEvent(edits: call.edits.count, tool: true)
            return
        }
        if !call.title.isEmpty { existing.title = call.title }
        existing.detail = call.detail ?? existing.detail
        existing.kind = call.kind
        existing.toolName = call.toolName ?? existing.toolName
        existing.toolDevice = call.toolDevice ?? existing.toolDevice
        // Edits count once, when they first land on the call.
        let landed = !call.edits.isEmpty && existing.edits.isEmpty ? call.edits.count : 0
        if !call.edits.isEmpty { existing.edits = call.edits }
        if existing.status == .running, call.status != .running { existing.finish(call.status) }
        entry.item.content = .tool(existing)
        saveRevision += 1
        noteHydraHeadEvent(edits: landed)
    }

    /// Something happened on this runtime's own timeline, and it is a head's: its
    /// watchdog clock restarts and the edits that landed count (see
    /// `AppModel.startHydraWatchdog`). A head counts its tools here, where its own
    /// session reports them.
    private func noteHydraHeadEvent(edits: Int = 0, tool: Bool = false) {
        guard let info = thread?.hydra else { return }
        hydraLastEventAt = .now
        hydraEditCount += edits
        if tool, info.kind == .tivano { hydraToolCalls += 1 }
    }

    /// A tool that is not plainly a read can have written a file, which makes the tree a
    /// command left behind no answer for what is on disk now. Commands keep their own
    /// count in `watchCommand`, which knows whether this one can write at all.
    private func noteToolMayWrite(_ kind: ToolCall.Kind?) {
        guard let kind, kind != .read, kind != .search, kind != .web, kind != .command else { return }
        settledTree = nil
        treeEpoch += 1
    }

    private func applyToolUpdate(_ id: String, _ update: ToolUpdate) {
        if let edits = update.edits { recordCurrentTurnEdits(edits) }
        noteToolMayWrite(update.kind)
        if entryIndex[id] == nil {
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .tool(ToolCall(kind: update.kind ?? .other, title: update.title ?? "Tool"))))
        }
        guard let entry = entryIndex[id], case .tool(var call) = entry.item.content else { return }
        if let title = update.title, !title.isEmpty { call.title = title }
        if let detail = update.detail { call.detail = detail }
        if let kind = update.kind { call.kind = kind }
        if let references = update.fileReferences {
            call.fileReferences = references
            call.fileReference = references.count == 1 ? references.first : nil
        }
        var landed = 0
        if let edits = update.edits, !edits.isEmpty {
            if call.edits.isEmpty { landed = edits.count }
            call.edits = Self.capped(edits)
        }
        if let output = update.output { call.setOutput(output) }
        if let exitCode = update.exitCode { call.exitCode = exitCode }
        if let status = update.status {
            if status == .running { call.status = .running } else {
                call.finish(status)
                if let nativeJournalDate { call.finishedAt = nativeJournalDate }
            }
        }
        entry.item.content = .tool(call)
        saveRevision += 1
        noteHydraHeadEvent(edits: landed)
        scheduleSave()
    }

    // MARK: - Command edits

    /// Agents that edit files from the shell (python heredocs, sed -i, patch)
    /// never report an edit, so a command's row gets its edits from the
    /// working tree instead: a tree known to predate the command, another
    /// captured as it finishes, and the diff between the two. Git-backed projects only.
    ///
    /// Nothing is captured as the command starts. The agent runs the command itself,
    /// the moment its tool call arrives, and a heredoc is done in a blink while a
    /// snapshot of a big checkout takes seconds: a snapshot started here raced the
    /// command and, more often than not, already held its write. Before and after then
    /// matched, the row got no edits, the turn counted no file, and the lead's merge had
    /// nothing to take; a sibling chat's sweep landed the work under its own title
    /// instead. The "before" is now always a tree that was complete before the command
    /// began (see `treeBeforeCommand`).
    private func watchCommand(_ id: String, _ call: ToolCall) {
        // A command that cannot write needs no snapshots at all: reading the checkout is
        // most of what an agent runs, and each snapshot is seconds of git on a big tree.
        let isEval = call.ompTool == .eval
        guard commandTrees[id] == nil, foreignCommandBases[id] == nil,
              call.commandMayWriteFiles else { return }
        // Eval titles are captions, not shell commands or evidence of a cd.
        if !isEval, currentTurnID != nil, let root = workingRoot,
           let directory = ShellCommandKind.leadingDirectory(of: call.title, from: root),
           Self.isOutside(directory, root: root) {
            watchForeignCommand(id, directory: directory)
            return
        }
        guard repositoryGit != nil, let before = treeBeforeCommand() else { return }
        commandTrees[id] = Task<CheckoutSnapshot?, Never> { before }
        commandStarts[id] = .now
        settledTree = nil
        treeEpoch += 1
    }

    /// A tree-ish that stood complete before a command starting now: the tree the last
    /// command left when nothing has run since, else the last snapshot any command in
    /// this turn finished, else the turn's own start checkpoint, which the turn waited
    /// for before its first word reached the model. Each is older than the command, so
    /// a diff from it can only hold more than the command wrote, never less; what an
    /// earlier tool of the turn already reported is taken back out as the row settles.
    private func treeBeforeCommand() -> CheckoutSnapshot? {
        if let settled = settledTree, settled.epoch == treeEpoch { return settled.tree }
        if let latestTree { return latestTree }
        guard let currentTurnID, let turn = turns.first(where: { $0.id == currentTurnID }) else { return nil }
        return turn.baseSnapshot ?? nativeInputGroups.reversed().compactMap { id in
            turns.first(where: { $0.id == id })?.baseSnapshot
        }.first
    }

    /// Repository-relative paths that other rows of a turn already carry as edits, so a
    /// command settling against an older tree does not show the turn's earlier work as
    /// its own. A path the command also touched stays on the row that reported it first
    /// and still counts for the turn.
    private func attributedPaths(inTurnOf id: String, git: Git, repositoryRoot: URL) -> Set<String> {
        guard let turnID = entryIndex[id]?.item.turnID else { return [] }
        var paths = Set<String>()
        let runGroups = Set(nativeInputGroups + [currentTurnID].compactMap { $0 })
        let attributableGroups: Set<UUID> = usesNativeOMPQueue && runGroups.contains(turnID) ? runGroups : [turnID]
        for entry in entries where entry.id != id && entry.item.turnID.map(attributableGroups.contains) == true {
            guard case .tool(let call) = entry.item.content else { continue }
            for edit in call.edits {
                let trimmed = edit.path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let absolute = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") ? trimmed : (git.directory.path as NSString).appendingPathComponent(trimmed)
                if let relative = TouchedPaths.relative(absolute, root: repositoryRoot.path) { paths.insert(relative) }
            }
        }
        return paths
    }

    /// Whether a command's `cd` leaves the thread's checkout for another one. A folder
    /// inside it, the checkout itself under a symlinked name, or a folder above it (whose
    /// repository the checkout's own snapshots already span) is no other checkout: its
    /// edits must stay relative to the thread's root, where the turn and the merge count them.
    private static func isOutside(_ directory: String, root: String) -> Bool {
        let directory = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return directory != root && TouchedPaths.relative(directory, root: root) == nil
            && TouchedPaths.relative(root, root: directory) == nil
    }

    private func settleCommand(_ id: String) {
        if foreignCommandBases[id] != nil { return settleForeignCommand(id) }
        nativeBackgroundCommands[id] = nil
        let commandStart = commandStarts.removeValue(forKey: id)
        let commandTurnID = entryIndex[id]?.turnID ?? currentTurnID
        let turnStart = turns.first(where: { $0.id == commandTurnID })?.startedAt ?? .distantPast
        let owner = claimOwner
        guard let before = commandTrees.removeValue(forKey: id), let git = repositoryGit else { return }
        let epoch = treeEpoch
        commandSettles[id] = Task { [weak self] in
            guard let base = await before.value, let self else { return }
            guard let after = await captureTree(git).value else { return }
            latestTree = after
            // Nothing else started or ran alongside while the snapshot was taken, so it
            // still stands for the working tree and the next command starts from it.
            if treeEpoch == epoch, commandTrees.isEmpty { settledTree = (after, epoch) }
            guard let adjusted = try? await git.attributionBase(from: base, to: after),
                  adjusted != after.tree, let changed = try? await git.changedPaths(from: adjusted, to: after.tree) else { return }
            let repository = repositoryRoot(for: git)
            let attributed = attributedPaths(inTurnOf: id, git: git, repositoryRoot: await repository.value)
            // Only the files that are work: a head that builds in its copy leaves thousands of
            // compiler-cache records under build.noindex where the project's .gitignore missed
            // them, and a diff of all of those once put 7,632 edits and 7 MB on two rows, then
            // into the merge as strays. Listed first and diffed by name, they never get that far.
            var real = changed.filter { !$0.isEmpty && !TouchedPaths.isBuildOutput($0) && !attributed.contains($0) }
            let root = await repository.value.path
            real = await unclaimedCommandPaths(real, root: root, owner: owner, turnStart: turnStart, commandStart: commandStart)
            await attachCommandEdits(id, paths: real, git: git, from: adjusted, to: after.tree, repositoryRoot: repository.value, owner: owner)
        }
    }

    /// The files past which a command's row keeps counts alone: a codemod or a generator
    /// can rewrite hundreds of files, and a patch for each would put megabytes on the row
    /// and in the thread file. Every file still lands as an edit, so the turn and the merge
    /// count it; only the first ones carry the diff the row's edit lines open.
    private static let commandPatchLimit = 60

    /// Attaches every changed file, with patches for the first files and counts for the rest.
    private func attachCommandEdits(_ id: String, paths: [String], git: Git, from base: String, to after: String, repositoryRoot: URL, owner: UUID) async {
        guard !paths.isEmpty else { return }
        let patched = Array(paths.prefix(Self.commandPatchLimit))
        guard let patch = try? await git.diff(from: base, to: after, paths: patched) else { return }
        let absolutePaths = paths.map { repositoryRoot.appendingPathComponent($0).standardizedFileURL.path }
        let patchedPaths = Set(absolutePaths.prefix(patched.count))
        var byPath: [String: FileEdit] = [:]
        // A patch parser can leave Git's quoted filename escaped. Use the known paths
        // alone, and recover an unmatched file from NUL-separated numstat below.
        for edit in await Self.fileEdits(from: patch, repositoryRoot: repositoryRoot) where patchedPaths.contains(edit.path) {
            byPath[edit.path] = edit
        }
        let counted = zip(paths, absolutePaths).compactMap { path, absolute in byPath[absolute] == nil ? path : nil }
        if !counted.isEmpty {
            guard let counts = try? await git.lineCounts(from: base, to: after, paths: counted) else { return }
            for file in counts {
                let path = repositoryRoot.appendingPathComponent(file.path).standardizedFileURL.path
                byPath[path] = FileEdit(path: path, additions: file.additions, deletions: file.deletions)
            }
        }
        let edits = absolutePaths.compactMap { byPath[$0] }
        // Do not claim a complete command while recording only a partial file set.
        guard edits.count == paths.count, let entry = entryIndex[id], case .tool(var call) = entry.item.content else { return }
        // A provider that did report its edits keeps them.
        guard call.edits.allSatisfy({ $0.diff == nil }) else { return }
        call.edits = edits
        CheckoutClaims.claim(paths, root: repositoryRoot.path, owner: owner)
        if entry.turnID == currentTurnID { recordCurrentTurnEdits(edits) }
        entry.item.content = .tool(call)
        saveRevision += 1
        noteHydraHeadEvent(edits: edits.count)
        scheduleSave()
    }

    /// What a command that starts in another checkout is diffed from: that checkout's root,
    /// a tree of it, and whether the tree is its last commit rather than a snapshot of
    /// the working tree, in which case only files written since the command began are its.
    struct ForeignBase: Sendable {
        let root: URL
        let snapshot: CheckoutSnapshot
        let isCommit: Bool
    }

    /// A command that moves into another checkout before it writes (`cd ~/worktree &&
    /// python3 - <<'EOF'`): an agent that keeps its work in a worktree of its own edits
    /// there, and the thread's checkout never sees it change. That checkout is watched
    /// instead, from the last tree any command of the turn left there, else the one the
    /// turn took as it began, else its last commit, with the files limited to those
    /// written since the command started. Nothing is captured now, for the reason
    /// `watchCommand` gives. Its edits land on the row with absolute paths outside the
    /// thread's root, so they are no part of the turn's touched paths: a revert does not
    /// restore them and a Hydra merge does not take them.
    private func watchForeignCommand(_ id: String, directory: String) {
        commandStarts[id] = .now
        settledTree = nil
        treeEpoch += 1
        foreignCommandBases[id] = Task { [weak self] () -> ForeignBase? in
            guard let root = try? await Git(directory).repositoryRoot().standardizedFileURL, let self else { return nil }
            foreignRoots.insert(root.path)
            if let known = foreignTrees[root.path], let tree = await known.value {
                return ForeignBase(root: root, snapshot: tree, isCommit: false)
            }
            guard let head = try? await Git(root.path).headTree() else { return nil }
            return ForeignBase(root: root, snapshot: CheckoutSnapshot(tree: head, head: head), isCommit: true)
        }
    }

    private func settleForeignCommand(_ id: String) {
        nativeBackgroundCommands[id] = nil
        let commandStart = commandStarts.removeValue(forKey: id)
        let commandTurnID = entryIndex[id]?.turnID ?? currentTurnID
        let turnStart = turns.first(where: { $0.id == commandTurnID })?.startedAt ?? .distantPast
        let owner = claimOwner
        guard let pending = foreignCommandBases.removeValue(forKey: id) else { return }
        commandSettles[id] = Task { [weak self] in
            guard let base = await pending.value, let self else { return }
            let git = Git(base.root.path)
            let capture = captureTree(git)
            // The next command in that checkout starts from this one's tree.
            foreignTrees[base.root.path] = capture
            guard let after = await capture.value,
                  let adjusted = try? await git.attributionBase(from: base.snapshot, to: after),
                  adjusted != after.tree, let changed = try? await git.changedPaths(from: adjusted, to: after.tree) else { return }
            let attributed = attributedPaths(inTurnOf: id, git: git, repositoryRoot: base.root)
            var real = changed.filter { !$0.isEmpty && !TouchedPaths.isBuildOutput($0) && !attributed.contains($0) }
            // A diff from the last commit holds every uncommitted change in that copy,
            // earlier turns' included, and a chat running in that checkout may not have
            // claimed its writes yet: either way only what was written while this command ran.
            if base.isCommit || othersRunning(in: base.root.path), let commandStart {
                let root = base.root.path
                let candidates = real
                real = await Task.detached(priority: .utility) {
                    candidates.filter { path in
                        let file = (root as NSString).appendingPathComponent(path)
                        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                              let modified = attributes[.modificationDate] as? Date else { return false }
                        return modified >= commandStart.addingTimeInterval(-1)
                    }
                }.value
            }
            real = await unclaimedCommandPaths(real, root: base.root.path, owner: owner, turnStart: turnStart, commandStart: commandStart)
            await attachCommandEdits(id, paths: real, git: git, from: adjusted, to: after.tree, repositoryRoot: base.root, owner: owner)
        }
    }

    /// Whether another chat is running in `root` or a folder of it right now.
    private func othersRunning(in root: String) -> Bool {
        guard let app else { return false }
        let key = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return app.threads.contains { thread in
            guard thread.id != threadID, app.existingRuntime(for: thread.id)?.isRunning == true,
                  let project = app.executionProject(for: thread) else { return false }
            let other = URL(fileURLWithPath: thread.executionDirectory(projectPath: project.path)).standardizedFileURL.resolvingSymlinksInPath().path
            return other == key || TouchedPaths.relative(other, root: key) != nil
        }
    }

    /// One working-tree snapshot at a time for this thread, each waiting for the one
    /// before it: they are heavy, and a turn's commands would otherwise run several at
    /// once, with eight heads doing the same in the same checkout.
    private func captureTree(_ git: Git) -> Task<CheckoutSnapshot?, Never> {
        let previous = treeCaptures
        let capture = Task { () -> CheckoutSnapshot? in
            _ = await previous?.value
            return await Task.detached(priority: .utility) { try? await git.captureSnapshot() }.value
        }
        treeCaptures = capture
        return capture
    }

    private func recordCurrentTurnEdits(_ edits: [FileEdit]) {
        guard currentTurnID != nil, let root = workingRoot else { return }
        let paths = edits.compactMap { TouchedPaths.relative($0.path, root: root) }
        claimReportedPaths(paths, root: root)
        hydraCurrentTurnTouchedPaths.formUnion(paths)
    }

    private var claimOwner: UUID {
        guard let thread = app?.thread(threadID), thread.hydra != nil,
              thread.worktreePath == nil, let parentID = thread.parentThreadID else { return threadID }
        return parentID
    }

    private func claimReportedPaths(_ paths: [String], root: String) {
        let owner = claimOwner
        let repository = repositoryRoot(for: Git(root))
        Task {
            let repositoryRoot = await repository.value.path
            let relative = paths.compactMap {
                TouchedPaths.relative((root as NSString).appendingPathComponent($0), root: repositoryRoot)
            }
            CheckoutClaims.claim(relative, root: repositoryRoot, owner: owner)
        }
    }

    private func unclaimedCommandPaths(_ paths: [String], root: String, owner: UUID, turnStart: Date, commandStart: Date?) async -> [String] {
        // A checkout snapshot sees sibling writes too; their latest claim keeps them theirs.
        let foreign = CheckoutClaims.foreign(paths, root: root, owner: owner, since: turnStart)
        var own = paths.filter { !foreign.contains($0) }
        if CheckoutClaims.othersActive(root: root, owner: owner, since: turnStart), let commandStart {
            let candidates = own
            // An old before-tree can include writes finished before this command began.
            let earlier = await Task.detached(priority: .utility) {
                Set(candidates.filter { path in
                    let file = (root as NSString).appendingPathComponent(path)
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                          let modified = attributes[.modificationDate] as? Date else { return false }
                    return modified < commandStart.addingTimeInterval(-1)
                })
            }.value
            own.removeAll { earlier.contains($0) }
        }
        return own
    }

    /// The folder this thread's agent works in: its own copy, else an explicit Hydra
    /// checkout, else the project folder.
    private var workingRoot: String? {
        guard let app, let thread = app.thread(threadID), let project = app.executionProject(for: thread) else { return nil }
        return thread.executionDirectory(projectPath: project.path)
    }

    private var repositoryGit: Git? {
        guard let currentTurnID, let root = workingRoot else { return nil }
        let runGroups = Set(nativeInputGroups + [currentTurnID])
        guard turns.contains(where: { runGroups.contains($0.id) && $0.baseCheckpoint != nil }) else { return nil }
        return Git(root)
    }

    /// How much of a patch an edit carries. Past it the edit is stats only, so neither the
    /// timeline nor the thread file grows by the whole of a written file.
    private nonisolated static let editDiffLimit = 200_000

    /// Edits as a provider reported them, with an outsized patch dropped: a Write tool
    /// hands over the entire new file, which can be megabytes, and every save would then
    /// write all of it again. The same cap the edits taken from a command's diff have.
    private static func capped(_ edits: [FileEdit]) -> [FileEdit] {
        edits.map { edit in
            guard let diff = edit.diff, diff.utf8.count > editDiffLimit else { return edit }
            var capped = edit
            capped.diff = nil
            return capped
        }
    }

    /// One edit per file in a multi-file patch, with the file's own section as its diff.
    @concurrent
    nonisolated static func fileEdits(from patch: String, repositoryRoot: URL) async -> [FileEdit] {
        var sections: [String] = []
        var current: [Substring] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections.compactMap { section in
            guard let file = DiffParser.parse(section).first else { return nil }
            // Huge sections are stats only, so the thread file stays small.
            let diff = section.utf8.count <= editDiffLimit ? section : nil
            let path = URL(fileURLWithPath: file.path, relativeTo: repositoryRoot).standardizedFileURL.path
            return FileEdit(path: path, diff: diff, additions: file.additions, deletions: file.deletions)
        }
    }

    private func upsertTodoSnapshot(_ snapshot: TodoSnapshot, previous: [TodoStep]? = nil) {
        nativeTodoSnapshot = snapshot
        let steps = snapshot.displayed(after: previous ?? todoSteps)
        if nativeTodoSteps != steps { nativeTodoSteps = steps }
        let ownerTurnID = turnIDForNewRows ?? turns.last?.id
        // The row is remembered rather than searched for: a turn rewrites its list many
        // times, and the timeline behind it can hold thousands of rows. Without it, the
        // running turn's entries are the last ones, and an earlier turn ends the walk.
        if let id = todosEntryID, let entry = entryIndex[id],
           entry.item.turnID == ownerTurnID || entry.item.turnID == nil {
            let relinked = linkTodoEntry(entry, to: ownerTurnID)
            if case .todos(let existing) = entry.item.content, existing == steps {
                if relinked { scheduleSave() }
                return
            }
            entry.item.content = .todos(steps)
            saveRevision += 1
            scheduleSave()
            return
        }
        var existing: TimelineEntry?
        for entry in entries.reversed() {
            if let turnID = entry.item.turnID, turnID != ownerTurnID { break }
            if (entry.item.turnID == ownerTurnID || entry.item.turnID == nil), case .todos = entry.item.content { existing = entry; break }
        }
        if let entry = existing {
            todosEntryID = entry.id
            let relinked = linkTodoEntry(entry, to: ownerTurnID)
            if case .todos(let existing) = entry.item.content, existing == steps {
                if relinked { scheduleSave() }
                return
            }
            entry.item.content = .todos(steps)
            saveRevision += 1
        } else if !steps.isEmpty || latestTodoEntry != nil {
            // A clear in a later turn needs an empty snapshot too, or reopening
            // the thread would revive its preceding non-empty list in the chrome.
            let item = TimelineItem(turnID: ownerTurnID, content: .todos(steps))
            todosEntryID = item.id
            append(item)
        }
        scheduleSave()
    }

    private func linkTodoEntry(_ entry: TimelineEntry, to owner: UUID?) -> Bool {
        guard entry.turnID == nil, let owner else { return false }
        entry.item.turnID = owner
        markTurnDirty(owner)
        saveRevision += 1
        return true
    }

    private func appendNotice(_ level: Notice.Level, _ message: String) {
        appendNotice(Notice(level: level, message: message))
    }

    private func appendNotice(_ notice: Notice) {
        flushDeltas()
        append(TimelineItem(turnID: turnIDForNewRows, content: .notice(notice)))
        scheduleSave()
    }

    /// A terminal outcome repeats the last model/transport failure; it is not
    /// another attempt. Keep the diagnostic already reported within this turn.
    private func appendTerminalError(_ message: String) {
        let terminal = Notice(level: .error, message: message)
        if let currentTurnID, entries.reversed().contains(where: { entry in
            guard entry.turnID == currentTurnID, case .notice(let notice) = entry.item.content else { return false }
            return notice.level == .error && notice.hasSameDiagnostic(as: terminal)
        }) { return }
        appendNotice(terminal)
    }

    private func updateTurn(_ id: UUID, _ change: (inout TurnRecord) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
        saveRevision += 1
    }

    /// Names the chat the moment its first message goes in, so the row never sits at
    /// 'New thread' while a session starts. Only a chat with no name of its own is ever
    /// named here, so a later turn cannot overwrite a title.
    private func generateTitle(from text: String, attachments: [Attachment]) {
        guard let app, let thread = app.thread(threadID), !thread.hasCustomTitle else { return }
        guard turns.count == 1 || thread.title == ChatThread.untitled else { return }
        let names = attachments.map(\.name)
        let input = names.isEmpty ? text : text + "\nAttached: " + names.joined(separator: ", ")
        app.updateThread(threadID) { $0.title = TextCleanup.singleLine(text, limit: 48) }
        guard let engine = app.textEngine(preferring: thread.provider) else { return }
        let threadID = threadID
        Task {
            guard let title = await TextGeneration.threadTitle(for: input, engine: engine) else { return }
            app.updateThread(threadID) { thread in
                if !thread.hasCustomTitle { thread.title = title }
            }
        }
    }

    // MARK: - Persistence

    func scheduleSave() {
        guard persistenceEnabled, !historyRecoveryBlocked else { return }
        guard phase != .idle else {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
            return
        }
        // A running turn fires this after nearly every event it streams, and every save
        // rewrites the whole thread file, which runs to megabytes. While the turn runs its
        // events share one save every few seconds: the timer already running writes
        // whatever the thread holds by then, and `finishTurn` saves what is left. A long
        // thread waits longer, so no chat rewrites more than about 250 KB a second however
        // big it grows: five seconds up to a megabyte, twenty for five megabytes and more.
        guard saveTask == nil else { return }
        let bytes = DiskWriter.shared.lastWrittenSize(of: Storage.threadURL(threadID)) ?? 0
        let seconds = min(20, max(5, Double(bytes) / 250_000))
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() { saveNow(completion: nil) }

    func saveNow(completion: (@MainActor @Sendable (Bool) -> Void)?) {
        // The timer that calls this is finished the moment it runs, so its handle goes
        // whatever happens below. Left standing across a skipped save, `scheduleSave` would
        // see a task already over and return, and nothing would be written until the turn
        // ended: the five-second bound on what a crash costs is exactly this handle.
        saveTask?.cancel()
        saveTask = nil
        // A save before the history is installed would write an empty thread over the file.
        guard persistenceEnabled, !historyRecoveryBlocked, !isLoadingHistory, saveRetryTask == nil else { completion?(false); return }
        // The periodic save fires every few seconds while a turn runs, even when the
        // turn's events changed nothing since the last write: skip the snapshot then.
        // `finishTurn` and friends still land on disk, as their mutations bump the
        // revision before the save below.
        guard saveRevision != lastSavedRevision else { completion?(true); return }
        let snapshot = snapshotForSave()
        let revision = saveRevision
        let url = Storage.threadURL(threadID)
        DiskWriter.shared.writeThread(snapshot) { [weak self] success in
            let reason = DiskWriter.shared.lastWriteError(of: url) ?? Chrome.localized("the disk write failed")
            Task { @MainActor [weak self] in
                guard let self, self.persistenceEnabled else { completion?(false); return }
                defer { completion?(success) }
                if success {
                    self.lastSavedRevision = max(self.lastSavedRevision, revision)
                    for reference in snapshot.head.turnIndex ?? [] {
                        self.savedTurnRevisions[reference.id] = max(self.savedTurnRevisions[reference.id] ?? 0, reference.revision)
                    }
                    self.saveFailures = 0
                    self.saveRetryTask?.cancel()
                    self.saveRetryTask = nil
                    if let id = self.saveNoticeID {
                        self.remove(id)
                        self.saveNoticeID = nil
                        self.scheduleSave()
                    }
                } else if revision > self.lastSavedRevision {
                    if self.saveNoticeID == nil {
                        let item = TimelineItem(turnID: self.turnIDForNewRows, content: .notice(Notice(level: .warning, message: String(format: Chrome.localized("OMP GUI couldn't save this chat to disk (%@). It keeps trying."), reason))))
                        self.saveNoticeID = item.id
                        self.append(item)
                    }
                    guard self.saveRetryTask == nil else { return }
                    let delay = [2, 5, 15, 60][min(self.saveFailures, 3)]
                    self.saveFailures += 1
                    self.saveRetryTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled, let self else { return }
                        self.saveRetryTask = nil
                        self.saveNow()
                    }
                }
            }
        }
    }

    /// The current document, or nil when the last save already holds it: quit writes
    /// only the threads that changed.
    var hasUnsavedChanges: Bool {
        !historyRecoveryBlocked && !isLoadingHistory && saveRevision != lastSavedRevision
    }

    func unsavedSnapshot() -> ThreadSave? {
        guard !historyRecoveryBlocked, !isLoadingHistory, saveRevision != lastSavedRevision else { return nil }
        return snapshotForSave()
    }

    /// Whether dropping this runtime loses nothing the saved document does not hold: no
    /// turn or session, nothing typed or mid-edit, nothing queued or owed to the lead,
    /// no landing under way. Panel geometry and the head links of old tool rows are UI
    /// conveniences a fresh runtime starts without, as it does after a relaunch.
    var holdsOnlyPersistedState: Bool {
        !historyRecoveryBlocked && phase == .idle && session == nil && providerHistoryOperation == nil && !isReverting && nativeOperationCount == 0 && nativeRefreshCount == 0 && pendingSend == nil && !isLoadingHistory
            && !isDictating && !dictation.isBusy && dictation.recoveredTranscript == nil
            && draft.isEmpty && followUpEdit == nil && messageEdit == nil
            && ompGoalBudgetDraft.isEmpty && !ompGoalComposerWorking && ompGoalComposerSubmission == nil
            && sideQuestionDraft.text.isEmpty && !ompSideQuestion.blocksRecycling
            && approvals.isEmpty && questions.isEmpty
            && hydraPendingReports.isEmpty && hydraBatches.isEmpty && hydraWaiting.isEmpty
            && !hydraFlushScheduled && hydraLanding == nil && !isHydraMerging && headBudget == nil
            && commandTrees.isEmpty && foreignCommandBases.isEmpty && commandSettles.isEmpty
    }

    func cancelPersistence() {
        dictation.cancel()
        persistenceEnabled = false
        historyLoad?.cancel()
        historyLoad = nil
        saveRetryTask?.cancel()
        saveRetryTask = nil
        saveTask?.cancel()
        saveTask = nil
        flushTask?.cancel()
        flushTask = nil
    }

    private func updateItemPositionsIfNeeded() {
        guard itemPositionsInvalid else { return }
        // Positions remain stable when a row is deleted or inserted, so editing one
        // turn never makes all the following turn files dirty just to renumber them.
        var nextPositions = [Double?](repeating: nil, count: entries.count)
        var nextKnown: Double?
        for index in entries.indices.reversed() {
            nextPositions[index] = nextKnown
            if let position = itemPositions[entries[index].id] { nextKnown = position }
        }
        var previous = 0.0
        for (offset, entry) in entries.enumerated() {
            if let position = itemPositions[entry.id] {
                previous = position
            } else {
                let position = nextPositions[offset].map { previous + ($0 - previous) / 2 } ?? (previous + 1)
                itemPositions[entry.id] = position
                previous = position
            }
        }
        itemPositionsInvalid = false
    }

    private func snapshotForSave() -> ThreadSave {
        flushDeltas(scheduleSave: false)
        updateItemPositionsIfNeeded()
        var head = ThreadDocument(threadID: threadID)
        let finished = turns.filter { $0.status != .running && $0.id != currentTurnID && $0.id != finishingTurnID }
        let finishedIDs = Set(finished.map(\.id))
        var dirty: [UUID: StoredTurn] = [:]
        head.turnIndex = finished.map { turn in
            if turnRevisions[turn.id] == nil { markTurnDirty(turn.id) }
            let revision = turnRevisions[turn.id] ?? 0
            if savedTurnRevisions[turn.id] != revision {
                dirty[turn.id] = StoredTurn(turn: turn, items: [], itemPositions: [:])
            }
            return ThreadTurnReference(id: turn.id, revision: revision)
        }
        head.itemPositions = [:]
        for entry in entries {
            if let id = entry.turnID, finishedIDs.contains(id) {
                if dirty[id] != nil {
                    dirty[id]?.items.append(entry.item)
                    dirty[id]?.itemPositions[entry.id] = itemPositions[entry.id]
                }
            } else {
                head.items.append(entry.item)
                head.itemPositions?[entry.id] = itemPositions[entry.id]
            }
        }
        head.turns = turns.filter { !finishedIDs.contains($0.id) }
        head.usage = usage
        head.ompContext = savedOMPContext
        head.ompDebug = savedOMPDebug
        head.continuation = continuation
        head.followUps = followUps
        head.hydraMerges = hydraMerges
        return ThreadSave(head: head, dirtyTurns: dirty)
    }

    func snapshotForPersistence() -> ThreadDocument {
        flushDeltas(scheduleSave: false)
        var document = ThreadDocument(threadID: threadID)
        document.items = entries.map(\.item)
        document.turns = turns
        document.usage = usage
        document.ompContext = savedOMPContext
        document.ompDebug = savedOMPDebug
        document.continuation = continuation
        document.followUps = followUps
        document.hydraMerges = hydraMerges
        return document
    }

    private var savedOMPDebug: OMPDebugArchive? {
        guard thread?.provider == .omp, thread?.hydra?.kind != .native else { return nil }
        return ompDebug.archive
    }

    private var savedOMPContext: OMPContextCache? {
        guard thread?.provider == .omp, thread?.hydra?.kind != .native,
              let file = ompContextSessionFile, file == thread?.providerSessionID else { return nil }
        return OMPContextCache(sessionFile: file, snapshot: ompContext)
    }
    func stopOMPAgent(_ id: String, observationID: String?) async -> Bool {
        guard let omp = session as? OMPSession, let observationID,
              omp.agentMetadata[id]?.observationID == observationID else { return false }
        return await omp.stopAgent(id)
    }

    func updateOMPDelegationPreference(_ launch: HydraLaunch?) {
        guard let omp = session as? OMPSession, omp.isRunning else { return }
        do {
            try omp.updateDelegationPreference(launch)
            sessionSignature?.hydra = launch
        } catch { appendNotice(.error, error.localizedDescription) }
    }

    var isOMPAgentStopPending = false
    var ompAgentStopAcceptance: Bool?
    var isOMPAgentSteeringPending = false

    var nativeOMPAgentDetailsAvailable: Bool {
        guard let head = thread, let parentID = head.parentThreadID, let id = head.hydra?.nativeID,
              let observationID = head.hydra?.nativeObservationID,
              let omp = app?.existingRuntime(for: parentID)?.session as? OMPSession,
              omp.isRunning, omp.agentMetadata[id]?.observationID == observationID else { return false }
        return omp.agentDetails[id]?.sessionFile != nil
    }

    var canStopNativeOMPAgent: Bool { canControlNativeOMPAgent(steering: false) }
    var canSteerNativeOMPAgent: Bool { canControlNativeOMPAgent(steering: true) }

    private func canControlNativeOMPAgent(steering: Bool) -> Bool {
        guard let head = thread, head.hydra?.isFinished == false,
              let parentID = head.parentThreadID, let id = head.hydra?.nativeID,
              let observationID = head.hydra?.nativeObservationID,
              let omp = app?.existingRuntime(for: parentID)?.session as? OMPSession,
              omp.agentMetadata[id]?.observationID == observationID else { return false }
        return omp.canControlAgent(id, steering: steering)
    }

    var nativeOMPControlMessage: String {
        guard let info = thread?.hydra, !info.isFinished else {
            return AppText.localized("This head is no longer running in OMP.")
        }
        if let issue = info.providerHistoryIssue { return issue }
        if !info.canSteer {
            let support = thread?.parentThreadID.flatMap { app?.existingRuntime(for: $0)?.ompCapabilities["steer_subagent"] } ?? .unknown
            return support == .unsupported
                ? AppText.localized("This OMP version cannot send additional instructions to heads. Update OMP to enable this control.")
                : AppText.localized("This OMP process has not confirmed support for additional worker instructions.")
        }
        return AppText.localized("This head is no longer running in OMP.")
    }

    private static func ompSteeringText(_ text: String, attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return text }
        return text + "\n\nAttached files (use the native read tool to inspect them):\n" + attachments.map { "- \($0.path)" }.joined(separator: "\n")
    }

    func steerOMPAgent(_ id: String, observationID: String?, text: String) async throws {
        guard let omp = session as? OMPSession, let observationID,
              omp.agentMetadata[id]?.observationID == observationID else { throw ProviderError.notRunning }
        try await omp.steerAgent(id, message: text)
    }

    func beginOMPAgentTurn(_ brief: String?) {
        // Progress is not a durable prompt. Journal entries create timed turns.
        phase = .running
    }

    private struct NativeAgentSteeringDraft {
        var id: String
        var text: String
        var message: UserMessage
    }
    @ObservationIgnored private var nativeAgentSteeringDrafts: [NativeAgentSteeringDraft] = []
    @ObservationIgnored private var nativeAgentObservedUsers: [String: String] = [:]
    @ObservationIgnored private var nativeAgentInitialUserID: String?

    func recordNativeAgentSteeringAcceptance(outgoing: ComposerDraft, text: String, visibleNativeUsers: Set<String>) {
        let alreadyDelivered = nativeAgentObservedUsers.contains { id, delivered in
            id != nativeAgentInitialUserID && !visibleNativeUsers.contains("omp-native-user-" + id) && delivered == text
        }
        guard !alreadyDelivered else { return }
        let pending = NativeAgentSteeringDraft(id: "omp-steer-local-" + UUID().uuidString, text: text,
            message: UserMessage(text: outgoing.outgoingText, attachments: outgoing.attachments))
        nativeAgentSteeringDrafts.append(pending)
        append(TimelineItem(id: pending.id, turnID: currentTurnID, content: .user(pending.message)))
    }

    /// Accepted instructions can still be in OMP's queue, outside its journal.
    /// Keep those records across a reset and place them after the durable batch.
    func completeNativeAgentTranscript() {
        guard thread?.hydra?.kind == .native else { return }
        for pending in nativeAgentSteeringDrafts {
            remove(pending.id)
            append(TimelineItem(id: pending.id, turnID: currentTurnID, content: .user(pending.message)))
        }
        if let first = turns.first, !nativeUntimedTurns.contains(first.id), !nativeJournalEntries.isEmpty {
            app?.updateHydraHead(threadID) {
                $0.startedAt = first.startedAt
                $0.executionStartedAt = first.startedAt
                if $0.isFinished, let last = self.nativeJournalLastDate { $0.finishedAt = last; $0.executionFinishedAt = last }
            }
        }
        scheduleSave()
    }

    func receiveOMPEvent(_ event: ProviderEvent) {
        if thread?.hydra?.kind == .native {
            if case .ompAgentJournalEntry(let entry) = event { receiveNativeJournalEntry(entry); return }
            if case .turnCompleted(let status, _) = event { finishOMPAgentTurn(status); return }
            if case .contextUsageCleared = event {
                nativeAgentContextRevision &+= 1
                nativeAgentContext.usage = nil
            }
            if case .usage(let value) = event {
                // Journal occupancy was projected before decoding this entry.
                // Do not replace its validated count with the generic fallback.
                guard nativeJournalEntryID == nil else { return }
                nativeAgentContextRevision &+= 1
                let model = thread?.model
                let window = value.windowTokens ?? (model == nativeAgentContext.model ? nativeAgentContext.windowTokens : nil)
                nativeAgentContext = OMPAgentJournal.ContextReport(usage: value, model: model, windowTokens: window)
                if let displayed = displayedAgentUsage(nativeAgentContext) { handle(.usage(displayed)) }
                return
            }
        }
        guard thread?.hydra?.kind == .native,
              case .ompUserMessage(_, let nativeID?, let text, _, _) = event else { handle(event); return }
        let durableID = "omp-native-user-" + nativeID
        guard entryIndex[durableID] == nil else { return }
        flushDeltas()
        if currentTurnID == nil { rehearseTurn(nil) }
        let previouslyObserved = nativeAgentObservedUsers[nativeID] != nil
        if nativeAgentInitialUserID == nil { nativeAgentInitialUserID = nativeID }
        nativeAgentObservedUsers[nativeID] = text
        var message = UserMessage(text: text)
        // Match only a newly consumed exact instruction. Old journal entries
        // replayed after reset cannot consume another identical pending draft.
        if !previouslyObserved, nativeID != nativeAgentInitialUserID,
           let index = nativeAgentSteeringDrafts.firstIndex(where: { $0.text == text }) {
            let pending = nativeAgentSteeringDrafts.remove(at: index)
            message = pending.message
            remove(pending.id)
        }
        let item = TimelineItem(id: durableID, turnID: currentTurnID, content: .user(message))
        if let currentTurnID, turns.first(where: { $0.id == currentTurnID })?.userItemID == nil {
            updateTurn(currentTurnID) { $0.userItemID = durableID }
        }
        append(item)
        scheduleSave()
    }

    func endOMPAgentExecution() {
        phase = .idle
        scheduleSave()
    }

    func finishOMPAgentTurn(_ status: TurnStatus) {
        finishNativeTranscriptTurn(status, at: nativeJournalLastDate)
        endOMPAgentExecution()
        turnStartedAt = nil
    }

    private func finishNativeTranscriptTurn(_ status: TurnStatus, at date: Date?) {
        guard let id = currentTurnID, let turn = turns.first(where: { $0.id == id }) else { return }
        let end = date ?? turn.startedAt
        updateTurn(id) { $0.status = status; $0.completedAt = end }
        let summary = TurnSummary(turnID: id, status: status, duration: max(0, end.timeIntervalSince(turn.startedAt)),
            filesChanged: 0, additions: 0, deletions: 0, durationIsKnown: date != nil && !nativeUntimedTurns.contains(id))
        append(TimelineItem(id: "omp-turn-end-" + id.uuidString, turnID: id, date: end, content: .turnEnd(summary)))
        currentTurnID = nil
        turnStartedAt = nil
    }

    private func receiveNativeJournalEntry(_ entry: JSONValue) {
        guard nativeJournalEntries.count < OMPAgentJournal.maximumEntries else {
            nativeAgentHistoryIssue = AppText.localized("This worker journal exceeds the history display limit.")
            return
        }
        guard let entryID = entry["id"]?.string, nativeJournalEntries.insert(entryID).inserted,
              let file = thread?.providerSessionID else { return }
        nativeAgentContextRevision &+= 1
        if entry["activeLeafId"] == nil || entry["activeLeafId"]?.string == entryID {
            nativeAgentContext.observe(entry)
        }
        usage = displayedAgentUsage(nativeAgentContext)
        var message = entry["message"]
        if entry["type"]?.string == "custom_message",
           ["async-result", "irc:incoming"].contains(entry["customType"]?.string ?? "") {
            var custom = entry.object ?? [:]
            custom["role"] = .string("custom")
            message = .object(custom)
        }
        // OMP delivers agent:// instructions as visible custom messages, not
        // ordinary user entries. Use its structured body without the IRC envelope.
        if let incoming = message, incoming["role"]?.string == "custom",
           incoming["customType"]?.string == "irc:incoming" {
            guard incoming["display"]?.bool != false else { return }
            var instruction = incoming.object ?? [:]
            instruction["role"] = .string("user")
            if let text = incoming["details"]?["message"]?.string { instruction["content"] = .string(text) }
            message = .object(instruction)
        }
        let isTodo = entry["customType"]?.string == "user_todo_edit"
        if message == nil && isTodo { message = .object([:]) }
        guard let message else { return }
        let role = message["role"]?.string
        guard ["user", "assistant", "toolResult", "custom"].contains(role ?? "") || isTodo else { return }
        flushDeltas()
        let prefix = OMPAgentJournal.prefix(for: file)
        nativeJournalDate = OMPAgentJournal.date(entry)
        nativeJournalEntryID = prefix + "-" + entryID
        nativeJournalNoticeIndex = 0
        defer { nativeJournalDate = nil; nativeJournalEntryID = nil }
        if let date = nativeJournalDate { nativeJournalLastDate = date }
        if currentTurnID == nil {
            var turn = TurnRecord(index: (turns.map(\.index).max() ?? -1) + 1)
            turn.id = OMPAgentJournal.stableID(prefix + ":" + entryID)
            turn.startedAt = nativeJournalDate ?? nativeJournalLastDate ?? .now
            turn.nativeSessionFile = file
            turns.append(turn)
            currentTurnID = turn.id
            turnStartedAt = nativeJournalDate
            if nativeJournalDate == nil { nativeUntimedTurns.insert(turn.id) }
        }
        if nativeJournalDecoder == nil {
            let directory = thread.flatMap { head in app?.executionProject(for: head).map { head.executionDirectory(projectPath: $0.path) } } ?? ""
            let child = OMPEventDecoder(prefix: prefix, directory: directory, capturesSnapshots: false)
            child.onEvent = { [weak self] event in self?.receiveOMPEvent(event) }
            nativeJournalDecoder = child
        }
        switch role {
        case "user":
            receiveOMPEvent(.ompUserMessage(requestID: nil, nativeID: prefix + "-u-" + entryID,
                text: message["content"]?.string ?? ToolText.blocks(message["content"]),
                imageCount: message["content"]?.array?.filter { $0["type"]?.string == "image" }.count ?? 0))
        case "assistant":
            nativeJournalDecoder?.contextWindow = displayedContextUsage?.windowTokens
            nativeJournalDecoder?.handle(.object(["type": "message_end", "messageId": .string(entryID), "message": message]))
            for call in message["content"]?.array ?? [] where call["type"]?.string == "toolCall" {
                guard let id = call["id"]?.string, let name = call["name"]?.string else { continue }
                nativeJournalDecoder?.handle(.object(["type": "tool_execution_start", "toolCallId": .string(id),
                    "toolName": .string(name), "args": call["arguments"] ?? .object([:])]))
            }
            if let reason = message["stopReason"]?.string, ["stop", "error", "aborted"].contains(reason) {
                finishNativeTranscriptTurn(reason == "stop" ? .completed : reason == "error" ? .failed : .interrupted, at: nativeJournalDate)
            }
        case "toolResult":
            if let id = message["toolCallId"]?.string {
                nativeJournalDecoder?.handle(.object(["type": "tool_execution_end", "toolCallId": .string(id),
                    "toolName": message["toolName"] ?? .null, "result": message, "isError": message["isError"] ?? false]))
            }
        case "custom":
            nativeJournalDecoder?.handle(.object(["type": "message_end", "messageId": .string(entryID), "message": message]))
        default: break
        }
        if isTodo || role == "toolResult" {
            var isolated = entry.object ?? [:]
            isolated["parentId"] = .null
            if let snapshot = OMPTodoSnapshot.snapshot(from: .array([.object(isolated)])) { handle(.todoSnapshot(snapshot)) }
        }
    }

    func cancelNativeAgentHistoryRead() {
        nativeAgentHistoryRead?.cancel()
        nativeAgentHistoryRead = nil
        nativeAgentHistoryReadID = nil
        nativeAgentHistoryLoading = false
    }

    func loadNativeAgentHistory() async {
        guard thread?.hydra?.kind == .native, let file = thread?.providerSessionID,
              !nativeDetailConsumers.isEmpty, nativeAgentHistoryRead == nil else { return }
        let readID = UUID()
        let previous = nativeAgentHistorySnapshot.flatMap { $0.file == file ? $0.fingerprint : nil }
        nativeAgentHistoryReadID = readID
        // Cached content stays usable while an unchanged journal is checked in
        // the background. Only a real replacement invalidates its layout.
        nativeAgentHistoryLoading = previous == nil
        nativeAgentHistoryIssue = nil
        let read = Task { [weak self] in
            guard let self else { return }
            defer {
                if nativeAgentHistoryReadID == readID {
                    nativeAgentHistoryRead = nil; nativeAgentHistoryReadID = nil; nativeAgentHistoryLoading = false
                }
            }
            do {
                let reader = Task.detached(priority: .userInitiated) { try OMPAgentJournal.readIfChanged(file, since: previous) }
                let snapshot = try await withTaskCancellationHandler {
                    try await reader.value
                } onCancel: { reader.cancel() }
                guard !Task.isCancelled, nativeAgentHistoryReadID == readID, thread?.providerSessionID == file else { return }
                guard let snapshot else { return }
                await ensureLoaded()
                guard !Task.isCancelled, nativeAgentHistoryReadID == readID else { return }
                nativeAgentHistoryLoading = true
                // Let the chat publish its preparation state before replacing a
                // dense history, rather than exposing the partial replay.
                await Task.yield()
                guard !Task.isCancelled, nativeAgentHistoryReadID == readID else { return }
                resetNativeAgentTranscript()
                for (index, entry) in snapshot.entries.enumerated() {
                    if index.isMultiple(of: 24) {
                        await Task.yield()
                        guard !Task.isCancelled, nativeAgentHistoryReadID == readID else { return }
                    }
                    receiveNativeJournalEntry(entry)
                }
                if thread?.hydra?.isFinished == true {
                    let status: TurnStatus = thread?.hydra?.status == .completed ? .completed : thread?.hydra?.status == .failed ? .failed : .interrupted
                    finishOMPAgentTurn(status)
                }
                completeNativeAgentTranscript()
                nativeAgentHistorySnapshot = (file, snapshot.fingerprint)
                if nativeJournalEntries.isEmpty { nativeAgentHistoryIssue = AppText.localized("OMP has not saved any worker messages yet.") }
                scheduleSave()
            } catch {
                guard !Task.isCancelled, nativeAgentHistoryReadID == readID else { return }
                nativeAgentHistoryIssue = error.localizedDescription
            }
        }
        nativeAgentHistoryRead = read
        await read.value
    }

}

private extension TimelineItem.Content {
    /// Appends streamed text to the payload in place, and says whether the payload took it.
    /// Binding the payload out of the enum while the enum still holds it left two
    /// references, so every flush copied the whole message before appending; releasing
    /// the enum's reference first keeps the string unique and the append amortized
    /// O(delta). Written through the entry's `item`, this is still one observed mutation.
    mutating func appendStreamed(_ text: String, kind: ThreadRuntime.DeltaKind) -> Bool {
        switch (kind, self) {
        case (.message, .assistant(var message)):
            self = .todos([])
            message.text += text
            self = .assistant(message)
        case (.reasoning, .reasoning(var block)):
            self = .todos([])
            block.text += text
            self = .reasoning(block)
        case (.toolOutput, .tool(var call)):
            self = .todos([])
            call.appendOutput(text)
            self = .tool(call)
        case (.plan, .plan(var plan)):
            self = .todos([])
            plan.markdown += text
            self = .plan(plan)
        default:
            return false
        }
        return true
    }
}

// MARK: - Rehearsal

extension ThreadRuntime {
    /// Starts a turn with no provider behind it, for the website captures: the user message
    /// lands, the working line appears, and `rehearse(_:)` then feeds the events a provider
    /// would. `touchedPaths` and `providerDiff` give the turn a diff for the changes tab.
    func rehearseTurn(_ text: String?, touchedPaths: [String] = [], providerDiff: String? = nil,
                      baseCheckpoint: String? = nil, baseSnapshot: CheckoutSnapshot? = nil) {
        let turnIndex = (turns.map(\.index).max() ?? -1) + 1
        var turn = TurnRecord(index: turnIndex)
        turn.touchedPaths = touchedPaths.isEmpty ? nil : touchedPaths
        turn.providerDiff = providerDiff
        turn.baseCheckpoint = baseCheckpoint
        turn.baseSnapshot = baseSnapshot
        if let text {
            let userItem = TimelineItem(turnID: turn.id, content: .user(UserMessage(text: text)))
            turn.userItemID = userItem.id
            turns.append(turn)
            saveRevision += 1
            append(userItem)
        } else {
            turns.append(turn)
            saveRevision += 1
        }
        currentTurnID = turn.id
        hydraCurrentTurnTouchedPaths = Set(touchedPaths)
        phase = .running
        turnStartedAt = .now
        app?.updateThread(threadID) {
            $0.updatedAt = .now
            $0.lastStatus = .running
            $0.pendingResultTurnID = nil
            $0.hasUnread = false
            $0.unreadRevision = UUID()
        }
    }

    /// The brief a head was given, once the provider says what it was: a user message at
    /// the top of a timeline that started without one.
    func rehearseBrief(_ text: String) {
        guard let turn = turns.last, turn.userItemID == nil else { return }
        let userItem = TimelineItem(turnID: turn.id, content: .user(UserMessage(text: text)))
        updateTurn(turn.id) { $0.userItemID = userItem.id }
        let entry = TimelineEntry(userItem)
        insertEntry(entry, at: 0)
        entryIndex[userItem.id] = entry
        saveRevision += 1
        scheduleSave()
    }

    /// One provider event, through the same path a live session's events take.
    func rehearse(_ event: ProviderEvent) {
        handle(event)
    }

    /// Tells the changes tab and the diff panel that the turn's diff changed.
    func noteDiffChanged() {
        diffRevision += 1
    }

    /// Lazily migrate visible historical cards, including an explicitly empty summary
    /// left by the old worktree filter. The version prevents reparsing on every reopen.
    func refreshTurnChanges(turnID: UUID) async -> FileChangeSummary? {
        await ensureLoaded()
        guard let entry = entries.last(where: { $0.turnID == turnID && $0.kind == .turnEnd }),
              case .turnEnd(var summary) = entry.item.content,
              let turn = turns.first(where: { $0.id == turnID }), turn.status != .running else { return nil }
        if summary.fileAttributionVersion == TurnSummary.currentFileAttributionVersion, let changes = summary.changes {
            return changes
        }
        let hasEdits = entries.contains {
            guard $0.turnID == turnID, case .tool(let call) = $0.item.content else { return false }
            return !call.edits.isEmpty
        }
        let hasEvidence = hasEdits || turn.touchedPaths?.isEmpty == false || turn.providerDiff?.isEmpty == false
        // Some imported histories retain only their summary. Lack of edit evidence
        // cannot disprove those saved files or reconstruct their patches.
        let changes = hasEvidence ? FileChangeSummary(files: await parsedDiff(selection: turnID))
            : summary.changes ?? FileChangeSummary(files: [])
        // A native branch/history replacement may have removed this card while Git ran.
        guard !Task.isCancelled, entryIndex[entry.id] === entry,
              case .turnEnd(let current) = entry.item.content, current == summary else { return nil }
        summary.changes = changes
        summary.filesChanged = changes.files.count
        summary.additions = changes.additions
        summary.deletions = changes.deletions
        summary.fileAttributionVersion = TurnSummary.currentFileAttributionVersion
        entry.item.content = .turnEnd(summary)
        scheduleSave()
        return changes
    }
}
