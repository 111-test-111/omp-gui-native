import Foundation
import Synchronization

// Only app-wide presentation and persistence plumbing is stubbed. The store,
// model, resolver, loader, vnode watcher, actions and reader state are production.
// Historical debug inspection is outside the standalone file-store checks.
@MainActor final class DebugHistoryStore {}
@MainActor final class SessionHistoryStore { func suspend() {} }
@MainActor final class ContextWorkspaceStore { func suspend() {} }

// Chromium ownership is exercised by workspace-browser against the app module.
// This headless store check keeps only the registry's conversation identity and
// records close requests; it must never link or initialize the CEF runtime.
@MainActor final class BrowserWorkspaceStore {}
@MainActor final class BrowserWorkspaceRegistry {
    static let shared = BrowserWorkspaceRegistry()
    private var workspaces: [UUID: BrowserWorkspaceStore] = [:]
    private(set) var closedPanels: Set<UUID> = []

    func workspace(for id: UUID) -> BrowserWorkspaceStore {
        if let workspace = workspaces[id] { return workspace }
        let workspace = BrowserWorkspaceStore()
        workspaces[id] = workspace
        return workspace
    }

    func closePanel(for id: UUID) { closedPanels.insert(id) }
}

enum Chrome {
    static func localized(_ key: String) -> String { key }
}

enum StoragePaths {
    static var root: URL { fatalError("Headless checks require an explicit temporary persistence URL.") }
}

final class PreviewChecksReadGate: Sendable {
    private let entered = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)
    var hasEntered: Bool { entered.withLock { $0 } }

    func wait() {
        entered.withLock { $0 = true }
        guard semaphore.wait(timeout: .now() + 5) == .success else { fatalError("Restore-read gate timed out.") }
    }

    func release() { semaphore.signal() }
}

final class DiskWriter: Sendable {
    static let shared = DiskWriter()
    private let queue = DispatchQueue(label: "omp.headless-preview-checks.persistence")
    private let allowedRoot = Mutex<URL?>(nil)
    private let gate = Mutex<PreviewChecksReadGate?>(nil)
    private let writeCounts = Mutex<[URL: Int]>([:])
    private let failures = Mutex<[String]>([])

    func configure(root: URL) { allowedRoot.withLock { $0 = root } }
    var errors: [String] { failures.withLock { $0 } }
    func writes(to url: URL) -> Int { writeCounts.withLock { $0[url] ?? 0 } }

    func pauseReads() -> PreviewChecksReadGate {
        let next = PreviewChecksReadGate()
        gate.withLock { $0 = next }
        return next
    }

    func releaseReads(_ held: PreviewChecksReadGate) {
        gate.withLock { if $0 === held { $0 = nil } }
        held.release()
    }

    func readSynchronously<Value>(_ read: () -> Value) -> Value {
        queue.sync {
            gate.withLock { $0 }?.wait()
            return read()
        }
    }

    func encodeAndWrite<Value: Encodable & Sendable>(_ value: Value, to url: URL) {
        queue.async { [self] in _ = write(value, to: url) }
    }

    @discardableResult
    func writeSynchronously<Value: Encodable & Sendable>(_ value: Value, to url: URL) -> Bool {
        queue.sync { write(value, to: url) }
    }

    func waitForQueuedWrites() { queue.sync {} }

    private func write<Value: Encodable>(_ value: Value, to url: URL) -> Bool {
        guard let root = allowedRoot.withLock({ $0 }), url.isFileURL, url.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            fatalError("A headless check attempted to write outside its temporary root.")
        }
        do {
            try JSONEncoder.storage.encode(value).write(to: url, options: .atomic)
            writeCounts.withLock { $0[url, default: 0] += 1 }
            return true
        } catch {
            failures.withLock { $0.append(error.localizedDescription) }
            return false
        }
    }
}
