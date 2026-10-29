import Foundation

/// Reads only this edition's GUI library. It never discovers external CLI histories,
/// launches OMP, or imports another application's accounting/preferences.
enum UsageHistoryReader {
    static let maxThreads = 2_000
    static let maxTurns = 50_000
    static let maxFileBytes = 32 * 1_024 * 1_024
    static let maxReadBytes = 256 * 1_024 * 1_024

    struct Fingerprint: Equatable, Sendable {
        let modified: Date?
        let size: Int
        let inode: UInt64
    }

    struct CachedThread: Sendable {
        let fingerprint: Fingerprint
        let turns: [UsageTurn]
    }

    struct Result: Sendable {
        var snapshots: [UsageThreadSnapshot] = []
        var cache: [UUID: CachedThread] = [:]
        var unreadableFiles = 0
        var limited = false
    }

    private struct Head: Decodable {
        let threadID: UUID
        let turnIndex: [ThreadTurnReference]?
        let turns: [UsageTurn]?
    }

    private struct Stored: Decodable { let turn: UsageTurn }
    private struct TurnFile: Decodable { let revisions: [String: Stored] }
    private struct BudgetExceeded: Error {}

    static func read(threads: [ChatThread], live: [UUID: [TurnRecord]],
                     cached: [UUID: CachedThread] = [:]) throws -> Result {
        var result = Result()
        var readBytes = 0
        var turnCount = 0
        let sources = threads.filter { $0.provider == .omp }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
        result.limited = sources.count > maxThreads
        for thread in sources.prefix(maxThreads) {
            try Task.checkCancellation()
            guard turnCount < maxTurns else { result.limited = true; break }
            let remaining = maxTurns - turnCount
            let turns: [UsageTurn]
            if let current = live[thread.id] {
                // A fully loaded runtime owns the complete current list, including
                // unsaved updates, removals and transcript replacements. Never add
                // the same on-disk turn to its in-memory copy.
                turns = current.suffix(remaining).map(UsageTurn.init)
                result.limited = result.limited || current.count > remaining
            } else {
                turns = try DiskWriter.shared.readSynchronously {
                    let url = Storage.threadURL(thread.id)
                    do {
                        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                        let fingerprint = Fingerprint(modified: attributes[.modificationDate] as? Date,
                                                      size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                                                      inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
                        if let hit = cached[thread.id], hit.fingerprint == fingerprint {
                            if hit.turns.count <= remaining { result.cache[thread.id] = hit }
                            else { result.limited = true }
                            return Array(hit.turns.suffix(remaining))
                        }
                        let head = try JSONDecoder.storage.decode(Head.self, from: readFile(url, bytes: &readBytes))
                        guard head.threadID == thread.id else { throw CocoaError(.fileReadCorruptFile) }
                        var gathered = Array((head.turns ?? []).suffix(remaining))
                        let embedded = Set(gathered.map(\.id))
                        let references = (head.turnIndex ?? []).filter { !embedded.contains($0.id) }
                        let available = remaining - gathered.count
                        let truncated = (head.turns ?? []).count + references.count > remaining
                        result.limited = result.limited || truncated
                        let failuresBefore = result.unreadableFiles
                        for reference in references.suffix(available) {
                            try Task.checkCancellation()
                            do {
                                let data = try readFile(Storage.turnURL(thread.id, reference.id), bytes: &readBytes)
                                let file = try JSONDecoder.storage.decode(TurnFile.self, from: data)
                                guard let turn = file.revisions[String(reference.revision)]?.turn,
                                      turn.id == reference.id else { throw CocoaError(.fileReadCorruptFile) }
                                gathered.append(turn)
                            } catch is CancellationError { throw CancellationError() }
                            catch is BudgetExceeded { result.limited = true; break }
                            catch { result.unreadableFiles += 1 }
                        }
                        if result.unreadableFiles == failuresBefore && !result.limited {
                            result.cache[thread.id] = CachedThread(fingerprint: fingerprint, turns: gathered)
                        }
                        return gathered
                    } catch is CancellationError { throw CancellationError() }
                    catch is BudgetExceeded { result.limited = true; return [] }
                    catch let error as CocoaError where error.code == .fileReadNoSuchFile && !thread.hasStartedTurn {
                        return []
                    } catch { result.unreadableFiles += 1; return [] }
                }
            }
            turnCount += turns.count
            result.snapshots.append(UsageThreadSnapshot(thread: thread, turns: turns))
        }
        return result
    }

    private static func readFile(_ url: URL, bytes: inout Int) throws -> Data {
        try Task.checkCancellation()
        let remaining = min(maxFileBytes, maxReadBytes - bytes)
        guard remaining > 0 else { throw BudgetExceeded() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: remaining + 1) ?? Data()
        bytes += data.count
        guard data.count <= remaining else { throw BudgetExceeded() }
        return data
    }
}
