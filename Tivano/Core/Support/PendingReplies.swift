import Foundation

/// Replies waiting on a request id. The id is registered before `send` runs, so a fast
/// reply can't arrive before anyone is waiting for it.
@MainActor
final class PendingReplies<Value: Sendable> {
    private var continuations: [String: CheckedContinuation<Value, Error>] = [:]

    /// Without a `timeoutValue`, a timeout throws `CancellationError`.
    func register(
        _ id: String,
        timeout: Duration? = nil,
        timeoutValue: Value? = nil,
        send: () -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                send()
                guard let timeout else { return }
                Task {
                    try? await Task.sleep(for: timeout)
                    if let timeoutValue {
                        self.resolve(id, timeoutValue)
                    } else {
                        self.fail(id, CancellationError())
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    @discardableResult
    func resolve(_ id: String, _ value: Value) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func fail(_ id: String, _ error: Error) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    func resolveAll(_ value: Value) {
        let waiting = Array(continuations.values)
        continuations.removeAll()
        for continuation in waiting { continuation.resume(returning: value) }
    }

    func failAll(_ error: Error) {
        let waiting = Array(continuations.values)
        continuations.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
    }
}
