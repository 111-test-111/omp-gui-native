import Foundation
import Observation

@MainActor
@Observable
final class UsageSettingsStore {
    private(set) var statistics = UsageStatistics()
    private(set) var loadedAt: Date?
    private(set) var loadedRange: UsageRange = .month
    private(set) var snapshotRevision: UInt64 = 0
    /// Replays charts only for entry, a new period or a manual refresh. Ordinary
    /// live updates interpolate their values without restarting the reveal.
    private(set) var presentationRevision: UInt64 = 0
    private(set) var isLoading = false
    private(set) var unreadableFiles = 0
    private(set) var limited = false
    @ObservationIgnored private var cache: [UUID: UsageHistoryReader.CachedThread] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastForceID = 0

    func refresh(model: AppModel, range: UsageRange, forceID: Int = 0) async {
        let force = forceID != lastForceID
        generation += 1
        let current = generation
        isLoading = true
        defer { if generation == current { isLoading = false } }
        // Coalesce a burst of response/metadata changes while the page is visible.
        if loadedAt != nil && !force {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let threads = model.threads
        let projects = model.projects
        // Array snapshots are COW; decoding/projection stays on the utility task.
        let live = Dictionary(model.liveRuntimes.filter { !$0.isLoadingHistory }
            .map { ($0.threadID, $0.turns) }, uniquingKeysWith: { _, last in last })
        let previous = force ? [:] : cache
        let now = Date.now
        let work = Task.detached(priority: .utility) {
            let read = try UsageHistoryReader.read(threads: threads, live: live, cached: previous)
            try Task.checkCancellation()
            let statistics = UsageStatistics.build(read.snapshots, projects: projects, range: range, now: now)
            return (read, statistics)
        }
        do {
            let (read, next) = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            guard !Task.isCancelled, generation == current else { return }
            if loadedAt == nil || loadedRange != range || force { presentationRevision &+= 1 }
            lastForceID = forceID
            cache = read.cache
            statistics = next
            loadedRange = range
            unreadableFiles = read.unreadableFiles
            limited = read.limited
            loadedAt = now
            snapshotRevision &+= 1
        } catch {
            // Cancellation preserves the last accepted snapshot. Reader failures
            // are accounted for per file and published with that snapshot.
        }
    }
}
