import Foundation
import CoreFoundation
import Synchronization

/// A known-schema snapshot plus a short cross-process read/merge/write transaction.
/// Unknown fields are retained; deletions beat stale edits; conflicting edits fail closed.
final class SharedJSONFile: Sendable {
    private struct State { var baseline: Data?; var existed = false }
    private let state = Mutex(State())
    let url: URL

    init(_ url: URL) { self.url = url }

    func remember(_ knownSnapshot: Data, existed: Bool) {
        state.withLock { $0 = State(baseline: knownSnapshot, existed: existed) }
    }

    @discardableResult
    func save(_ local: Data, validate: (Data) throws -> Void = { _ in }) throws -> Data {
        try state.withLock { state in
            guard let baseline = state.baseline else { throw SharedJSONConflict(path: "uninitialized snapshot") }
            // Verified against macOS flock(2): separate opens cooperate across processes.
            let lease = try SharedLibraryLease(at: url.appendingPathExtension("lock"), wait: true)
            defer { withExtendedLifetime(lease) {} }
            let exists = FileManager.default.fileExists(atPath: url.path)
            guard exists || !state.existed else { throw SharedJSONConflict(path: "removed file") }
            let remote = exists ? try Data(contentsOf: url) : baseline
            let merged = try JSONMerge.merge(baseline: baseline, local: local, remote: remote)
            try validate(merged)
            if !exists || merged != remote { try merged.write(to: url, options: .atomic) }
            // The next delta is relative to what THIS caller holds, not another process's additions.
            state = State(baseline: local, existed: true)
            return merged
        }
    }
}

struct SharedJSONConflict: LocalizedError {
    let path: String
    var errorDescription: String? {
        String(format: AppText.localized("Another edition changed the same data (%@). Your write was not applied. Refresh and try again."), path)
    }
}

/// Identity-aware three-way merge. No timestamp-based last-writer-wins.
enum JSONMerge {
    static func merge(baseline: Data, local: Data, remote: Data) throws -> Data {
        let options: JSONSerialization.ReadingOptions = [.fragmentsAllowed]
        let base = try JSONSerialization.jsonObject(with: baseline, options: options)
        let local = try JSONSerialization.jsonObject(with: local, options: options)
        let remote = try JSONSerialization.jsonObject(with: remote, options: options)
        guard let value = try merge(base, local, remote, path: "$"), JSONSerialization.isValidJSONObject(value) else {
            throw SharedJSONConflict(path: "root")
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    }

    private static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            if let l = lhs as? [String: Any], let r = rhs as? [String: Any] {
                return l.count == r.count && l.allSatisfy { key, value in equal(value, r[key]) }
            }
            if let l = lhs as? [Any], let r = rhs as? [Any] {
                return l.count == r.count && zip(l, r).allSatisfy { equal($0, $1) }
            }
            if let l = lhs as? NSNumber, let r = rhs as? NSNumber {
                return (CFGetTypeID(l) == CFBooleanGetTypeID()) == (CFGetTypeID(r) == CFBooleanGetTypeID()) && l.isEqual(r)
            }
            return (lhs as AnyObject).isEqual(rhs)
        default: return false
        }
    }

    private static func merge(_ base: Any?, _ local: Any?, _ remote: Any?, path: String) throws -> Any? {
        if equal(base, local) { return remote }
        if equal(base, remote) || equal(local, remote) { return local }
        // An entity removed by either process must not be resurrected by a stale edit.
        if base != nil, local == nil || remote == nil { return nil }
        if let local = local as? [String: Any], let remote = remote as? [String: Any] {
            let base = base as? [String: Any] ?? [:]
            var result: [String: Any] = [:]
            for key in Set(base.keys).union(local.keys).union(remote.keys) {
                result[key] = try merge(base[key], local[key], remote[key], path: path + "." + key)
            }
            return result
        }
        if let local = local as? [Any], let remote = remote as? [Any] {
            let base = base as? [Any] ?? []
            for key in ["id", "catalogID"] {
                guard let b = indexed(base, key), let l = indexed(local, key), let r = indexed(remote, key) else { continue }
                let order = ids(remote, key) + ids(local, key).filter { r[$0] == nil }
                return try order.compactMap { id in try merge(b[id], l[id], r[id], path: path + "/" + id) }
            }
        }
        throw SharedJSONConflict(path: path)
    }

    private static func indexed(_ list: [Any], _ key: String) -> [String: Any]? {
        var result: [String: Any] = [:]
        for value in list {
            guard let value = value as? [String: Any], let id = value[key] as? String, result[id] == nil else { return nil }
            result[id] = value
        }
        return result
    }
    private static func ids(_ list: [Any], _ key: String) -> [String] {
        list.compactMap { ($0 as? [String: Any])?[key] as? String }
    }
}

struct SharedFileStamp: Equatable, Sendable {
    let modified: Date
    let inode: UInt64
    let size: UInt64
    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? UInt64,
              let size = attributes[.size] as? UInt64 else { return nil }
        self.modified = modified; self.inode = inode; self.size = size
    }
}
