import Foundation
import Synchronization

/// The process owns only the conversations it edits, not the whole library.
final class ThreadAccess: Sendable {
    static let shared = ThreadAccess()
    private struct Owned: Sendable { let group: UUID; let lease: SharedLibraryLease }
    private struct State { var leases: [UUID: Owned] = [:]; var families: [UUID: UUID] = [:] }
    private let state = Mutex(State())

    func setFamilies(_ families: [UUID: UUID]) { state.withLock { $0.families = families } }

    func owns(_ id: UUID) -> Bool {
        CaptureRun.isEnabled || state.withLock { $0.leases[id] != nil }
    }

    func ownsFamily(_ group: UUID) -> Bool { state.withLock { $0.leases.values.contains { $0.group == group } } }

    func claim(_ id: UUID, group: UUID? = nil) throws -> Bool {
        if CaptureRun.isEnabled { return true }
        return try state.withLock { state in
            if state.leases[id] != nil { return false }
            let group = group ?? state.families[id] ?? id
            let lease = try state.leases.values.first { $0.group == group }?.lease
                ?? SharedLibraryLease(at: Self.url(group))
            state.leases[id] = Owned(group: group, lease: lease)
            return true
        }
    }

    func isOwnedElsewhere(_ id: UUID) -> Bool {
        if owns(id) { return false }
        do {
            let group = state.withLock { $0.families[id] ?? id }
            let probe = try SharedLibraryLease(at: Self.url(group))
            return withExtendedLifetime(probe) { false }
        } catch { return true }
    }

    var ownedIDs: [UUID] { state.withLock { Array($0.leases.keys) } }

    /// Caller must drain its queued document writes before releasing ownership.
    func release(_ id: UUID) { state.withLock { $0.leases[id] = nil } }

    func withWritePermission<Result>(for id: UUID, _ operation: () throws -> Result) rethrows -> Result? {
        if CaptureRun.isEnabled { return try operation() }
        return try state.withLock { state in
            guard state.leases[id] != nil else { return nil }
            return try operation()
        }
    }

    private static func url(_ id: UUID) -> URL {
        Storage.root.appendingPathComponent("edit-locks/\(id.uuidString).lock")
    }
}
