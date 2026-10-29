import Foundation
import Observation

/// Prepared historical data belongs to the workspace, so returning to a step
/// never renders a provisional action name. No cached value grants live reads.
@MainActor @Observable
final class DebugHistoryStore {
    typealias Reader = @Sendable (String, OMPDebugRecord) async -> OMPDebugHistory.Detail?
    struct Entry {
        var detail: OMPDebugHistory.Detail?
        var phase: String
        var cost: Int
    }
    private(set) var sessionFile: String?
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let reader: Reader
    @ObservationIgnored private var preparedRuns: [String] = []

    init(reader: @escaping Reader = { file, record in await OMPDebugHistory.read(sessionFile: file, record: record) }) {
        self.reader = reader
    }

    func prepareRun(_ run: OMPDebugRun, runtime: ThreadRuntime) async {
        guard !preparedRuns.contains(run.id) else { return }
        await runtime.prepareDebugRun(run.id)
        guard !Task.isCancelled else { return }
        preparedRuns.append(run.id)
        preparedRuns = Array(preparedRuns.suffix(32))
    }

    func entry(for record: OMPDebugRecord, sessionFile: String?) -> Entry? {
        guard self.sessionFile == sessionFile, let value = entries[record.id], value.phase == record.phase else { return nil }
        return value
    }

    func resolvedRecord(_ record: OMPDebugRecord, sessionFile: String?) -> OMPDebugRecord? {
        guard record.details == nil, record.phase != "state", record.phase != "begin", sessionFile != nil else { return record }
        guard let entry = entry(for: record, sessionFile: sessionFile) else { return nil }
        var resolved = record
        resolved.details = entry.detail?.details
        resolved.session = entry.detail?.session ?? record.session
        return resolved
    }

    func recover(_ record: OMPDebugRecord, sessionFile: String?) async {
        guard record.details == nil, record.phase != "state", record.phase != "begin", let sessionFile else { return }
        if self.sessionFile != sessionFile {
            generation &+= 1; entries.removeAll(); order.removeAll(); self.sessionFile = sessionFile
        }
        if entry(for: record, sessionFile: sessionFile) != nil {
            order.removeAll { $0 == record.id }; order.append(record.id)
            return
        }
        let expected = generation
        let value = await reader(sessionFile, record)
        guard !Task.isCancelled, generation == expected, self.sessionFile == sessionFile else { return }
        let metadata = (value?.session).flatMap { try? JSONEncoder().encode($0).count } ?? 0
        let cost = (value?.details.cost ?? 0) + (value?.cwd?.utf8.count ?? 0) + metadata + record.id.utf8.count + 256
        entries[record.id] = Entry(detail: value, phase: record.phase, cost: cost)
        order.removeAll { $0 == record.id }; order.append(record.id)
        var total = entries.values.reduce(0) { $0 + $1.cost }
        while order.count > 128 || total > 1024 * 1024 {
            guard !order.isEmpty else { break }
            total -= entries.removeValue(forKey: order.removeFirst())?.cost ?? 0
        }
    }
}
