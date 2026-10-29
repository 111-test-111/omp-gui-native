import Foundation

/// Replies waiting on a request id. The id is registered before `send` runs, so a fast
/// reply can't arrive before anyone is waiting for it.
@MainActor
final class PendingReplies<Value: Sendable> {
    private struct Reply {
        var generation: UUID
        var continuation: CheckedContinuation<Value, Error>
        var timeout: Task<Void, Never>?
    }
    private var continuations: [String: Reply] = [:]

    enum RegistrationError: LocalizedError {
        case duplicateID
        var errorDescription: String? { AppText.localized("A request with this ID is already pending.") }
    }

    /// Without a `timeoutValue`, a timeout throws `CancellationError`.
    func register(
        _ id: String,
        timeout: Duration? = nil,
        timeoutValue: Value? = nil,
        send: () -> Void
    ) async throws -> Value {
        let generation = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard continuations[id] == nil else {
                    continuation.resume(throwing: RegistrationError.duplicateID)
                    return
                }
                let timer = timeout.map { duration in
                    Task { [weak self] in
                        do { try await Task.sleep(for: duration) } catch { return }
                        guard let self, continuations[id]?.generation == generation else { return }
                        if let timeoutValue {
                            resolve(id, timeoutValue)
                        } else {
                            fail(id, CancellationError())
                        }
                    }
                }
                continuations[id] = Reply(generation: generation, continuation: continuation, timeout: timer)
                send()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, continuations[id]?.generation == generation else { return }
                fail(id, CancellationError())
            }
        }
    }

    @discardableResult
    func resolve(_ id: String, _ value: Value) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.timeout?.cancel()
        continuation.continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func fail(_ id: String, _ error: Error) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.timeout?.cancel()
        continuation.continuation.resume(throwing: error)
        return true
    }

    func resolveAll(_ value: Value) {
        let waiting = Array(continuations.values)
        continuations.removeAll()
        for reply in waiting {
            reply.timeout?.cancel()
            reply.continuation.resume(returning: value)
        }
    }

    func failAll(_ error: Error) {
        let waiting = Array(continuations.values)
        continuations.removeAll()
        for reply in waiting {
            reply.timeout?.cancel()
            reply.continuation.resume(throwing: error)
        }
    }
}
