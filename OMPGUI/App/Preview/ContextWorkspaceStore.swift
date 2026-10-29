import Foundation
import Observation

/// Metadata survives same-workspace tab visits; hidden panes own no polling or
/// large journal indexes. Every publication is fenced by visibility and file.
@MainActor @Observable
final class ContextWorkspaceStore {
    enum RefreshTrigger: Equatable { case initial, automatic, completion, manual }
    private(set) var live: OMPContextLiveInspection?
    private(set) var saved: OMPContextSavedInspection?
    private(set) var updatedAt: Date?
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var isManuallyRefreshing = false
    private(set) var isPresented = false
    var expandedCategories: Set<String> = []
    @ObservationIgnored private let reader = OMPContextInspectionReader()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var currentFile: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var readTrigger: RefreshTrigger?
    @ObservationIgnored private var pendingManualRefresh = false
    @ObservationIgnored private var pendingCompletionRefresh = false
    @ObservationIgnored private weak var runtime: ThreadRuntime?

    isolated deinit { task?.cancel(); polling?.cancel() }

    var canAutomaticallyRefresh: Bool {
        isPresented && runtime?.thread?.isArchived != true
            && (runtime?.isRunning == true || runtime?.hasNativeWork == true)
    }

    func present(_ runtime: ThreadRuntime) {
        self.runtime = runtime
        if !isPresented {
            isPresented = true
            refresh(.initial)
            updateActivity()
        }
    }

    func updateActivity() {
        guard canAutomaticallyRefresh else {
            let needsCompletionRead = polling != nil && isPresented
            polling?.cancel(); polling = nil
            if readTrigger == .automatic {
                generation &+= 1; task?.cancel(); task = nil
                isRefreshing = false; readTrigger = nil
            }
            if needsCompletionRead { refresh(.completion) }
            return
        }
        guard polling == nil else { return }
        refresh()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                guard canAutomaticallyRefresh else { updateActivity(); return }
                refresh()
            }
        }
    }

    func suspend() {
        isPresented = false; generation &+= 1
        polling?.cancel(); polling = nil; task?.cancel(); task = nil
        isRefreshing = false; isManuallyRefreshing = false
        readTrigger = nil; pendingManualRefresh = false; pendingCompletionRefresh = false
        let reader = reader
        Task { await reader.release() }
    }

    func refresh(_ trigger: RefreshTrigger = .automatic) {
        guard isPresented, let runtime else { return }
        guard trigger != .automatic || canAutomaticallyRefresh else { return }
        let file = runtime.thread?.providerSessionID
        if file != currentFile {
            generation &+= 1; task?.cancel(); task = nil; isRefreshing = false; isManuallyRefreshing = false
            readTrigger = nil; pendingManualRefresh = false; pendingCompletionRefresh = false
            live = nil; saved = nil; updatedAt = nil; error = nil; currentFile = file
        }
        guard !isRefreshing else {
            if trigger == .manual {
                isManuallyRefreshing = true
                // Saved-only reads cannot replace an explicit native refresh.
                if readTrigger == .initial || readTrigger == .completion { pendingManualRefresh = true }
                else { readTrigger = .manual }
            }
            if trigger == .completion { pendingCompletionRefresh = true }
            return
        }
        generation &+= 1
        let expected = generation
        isRefreshing = true
        isManuallyRefreshing = trigger == .manual
        readTrigger = trigger
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == expected {
                    let followUp: RefreshTrigger? = pendingManualRefresh ? .manual : (pendingCompletionRefresh ? .completion : nil)
                    pendingManualRefresh = false; pendingCompletionRefresh = false
                    isRefreshing = false; task = nil; readTrigger = nil
                    if let followUp, isPresented { refresh(followUp) }
                    else { isManuallyRefreshing = false }
                }
            }
            var issues: [String] = []
            var nextLive: OMPContextLiveInspection?
            var nativeReadSucceeded = false
            var awaitingJournal = false
            // Only an existing normal chat may resume for a read. Historical
            // workers and archived chats always use their saved native journal.
            if (readTrigger == .manual || canAutomaticallyRefresh || (readTrigger == .completion && runtime.activeOMPSession != nil)),
               runtime.thread?.isArchived != true, runtime.thread?.hydra?.kind != .native,
               runtime.canInspectOMPContext, file != nil || runtime.activeOMPSession != nil,
               runtime.ompContext.pendingCommand == nil, !runtime.isReverting {
                do {
                    nextLive = try await runtime.inspectOMPContext(allowResume: readTrigger != .completion)
                    nativeReadSucceeded = true
                } catch is CancellationError { return }
                catch { issues.append(error.localizedDescription) }
            }
            guard isPresented, generation == expected, !Task.isCancelled,
                  runtime.thread?.providerSessionID == file else { return }
            if nativeReadSucceeded { live = nextLive }
            else if runtime.activeOMPSession == nil { live = nil }
            if let file {
                do {
                    let awaitingFirstSave = saved == nil && runtime.thread?.isArchived != true
                        && runtime.turns.allSatisfy { $0.status == .running }
                    let next = try await reader.read(file, awaitingFirstSave: awaitingFirstSave)
                    guard isPresented, generation == expected, !Task.isCancelled,
                          runtime.thread?.providerSessionID == file else { return }
                    saved = next
                    if let live, live.sessionID != next.journal.sessionID { self.live = nil }
                } catch is CancellationError { return }
                catch OMPContextInspectionReader.ReadError.awaitingFirstSave { awaitingJournal = true }
                catch let failure as OMPSessionRecordError { issues.append(Chrome.localized(failure.title)) }
                catch { issues.append(error.localizedDescription) }
            }
            guard isPresented, generation == expected, !Task.isCancelled else { return }
            error = issues.isEmpty ? nil : issues.joined(separator: "\n")
            if issues.isEmpty && (!awaitingJournal || nativeReadSucceeded) { updatedAt = .now }
        }
    }
}

/// The panel and exports must agree on which occupancy is authoritative.
/// A revision-validated historical journal supersedes unversioned runtime caches,
/// including an explicit unknown after compaction or a model change.
struct ContextWorkspaceOccupancy {
    let live: OMPContextLiveInspection?
    let usesSavedResponse: Bool
    let used: Int?
    let window: Int?
    let model: String?
    let source: String
    let sourceTitle: String

    @MainActor init(runtime: ThreadRuntime, state: ContextWorkspaceStore, live override: OMPContextLiveInspection? = nil) {
        let working = runtime.isRunning || runtime.hasNativeWork
        let historical = runtime.thread?.isArchived == true || (runtime.thread?.hydra?.kind == .native && !working)
        usesSavedResponse = override == nil && state.saved != nil
            && (historical || (runtime.ompContextIsCached && runtime.activeOMPSession == nil && !working))
        live = override ?? (usesSavedResponse ? nil : state.live)
        if let live {
            used = live.usedTokens; window = live.windowTokens; model = live.model ?? runtime.thread?.model
        } else if usesSavedResponse, let saved = state.saved {
            let response = saved.journal.response
            used = response.usage?.usedTokens
            window = response.usage?.windowTokens ?? response.windowTokens ?? runtime.nativeAgentContextWindow
            model = response.model ?? runtime.thread?.model
        } else {
            used = runtime.displayedContextUsage?.usedTokens ?? runtime.ompContext.usedTokens
                ?? state.saved?.journal.response.usage?.usedTokens
            window = runtime.displayedContextUsage?.windowTokens ?? runtime.ompContext.windowTokens ?? runtime.nativeAgentContextWindow
            model = state.saved?.journal.response.model ?? runtime.thread?.model
        }
        if let live {
            source = live.anchored ? "provider_anchored_estimate" : "local_estimate"
            sourceTitle = live.anchored ? "Provider-anchored estimate" : "Local estimate"
        } else if used == nil {
            source = "unavailable"; sourceTitle = "Unknown"
        } else if historical || usesSavedResponse {
            source = "saved_response"; sourceTitle = "Latest saved response"
        } else if runtime.ompContextIsCached {
            source = "saved_context"; sourceTitle = "Saved context snapshot"
        } else {
            source = "native_usage"; sourceTitle = "OMP context usage"
        }
    }
}
