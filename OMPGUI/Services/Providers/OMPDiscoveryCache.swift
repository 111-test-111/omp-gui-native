import Foundation

struct OMPDiscoveryContext: Equatable, Sendable {
    var executable: URL
    var environment: [String: String]
    var directory: URL?
}

/// Coalesces discovery reads, never execution. Retains one successful context,
/// expires quickly, and cannot republish a value invalidated by a config write.
@MainActor
final class OMPDiscoveryCache<Value: Sendable> {
    private var cached: (context: OMPDiscoveryContext, at: ContinuousClock.Instant, value: Value)?
    private var flight: (id: UUID, context: OMPDiscoveryContext, generation: Int, task: Task<Value, Error>)?
    private var generation = 0
    private let lifetime: Duration

    init(lifetime: Duration = .seconds(15)) { self.lifetime = lifetime }

    func invalidate() {
        generation &+= 1
        cached = nil
    }

    func value(for context: OMPDiscoveryContext, force: Bool = false,
               load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let flight, flight.context == context, flight.generation == generation { return try await flight.task.value }
        if !force, let cached, cached.context == context, cached.at.duration(to: .now) < lifetime { return cached.value }
        let id = UUID(), revision = generation
        let task = Task { try await load() }
        flight = (id, context, revision, task)
        defer { if flight?.id == id { flight = nil } }
        let result = try await task.value
        if revision == generation, flight?.id == id { cached = (context, .now, result) }
        return result
    }
}
