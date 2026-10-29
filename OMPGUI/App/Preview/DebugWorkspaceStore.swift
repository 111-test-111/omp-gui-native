import Foundation
import Observation

/// A mounted inspector owns its reads. All requests are serialized, and every
/// continuation is fenced by the stop token and the selected frame.
@MainActor @Observable
final class DebugWorkspaceStore {
    struct Node: Identifiable {
        var id: String
        var variable: OMPDebugVariable
        var depth: Int
        var ancestors: Set<Int>
        var isScope = false
        var children: [String]?
        var loading = false
        var limited = false
        var error: String?
        var canExpand: Bool { variable.reference > 0 && depth < 8 && !ancestors.contains(variable.reference) }
    }

    private(set) var frames: [OMPDebugFrame] = []
    private(set) var selectedFrameID: Int?
    private(set) var loading = false
    private(set) var loadingScopes = false
    private(set) var limitedStack = false
    private(set) var limitedVariables = false
    private(set) var error: String?
    private(set) var nodes: [String: Node] = [:]
    private(set) var expanded: Set<String> = []
    private var roots: [String] = []
    @ObservationIgnored private weak var session: OMPSession?
    @ObservationIgnored private var snapshot = OMPDebugSnapshot()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var retained = false

    var rows: [Node] {
        var result: [Node] = []
        func visit(_ ids: [String]) {
            for id in ids {
                guard result.count < 1000, let node = nodes[id] else { continue }
                result.append(node)
                if expanded.contains(id) { visit(node.children ?? []) }
            }
        }
        visit(roots)
        return result
    }

    func bind(_ session: OMPSession?, snapshot: OMPDebugSnapshot) {
        let reuse = retained && self.snapshot.inspectionKey != nil && self.snapshot.inspectionKey == snapshot.inspectionKey
        stop(keepingValues: reuse)
        guard snapshot.canInspect, let session else { stop(); return }
        self.session = session; self.snapshot = snapshot
        retained = false
        if reuse && !frames.isEmpty {
            if roots.isEmpty, let frame = selectedFrameID {
                enqueue { [weak self] generation in await self?.loadScopes(frame, generation: generation) }
            }
            return
        }
        loading = true
        enqueue { [weak self] generation in
            guard let self else { return }
            do {
                let result = try await session.inspectDebug("stack", snapshot: snapshot)
                guard isCurrent(generation) else { return }
                var seen = Set<Int>()
                frames = (result["frames"]?.array ?? []).prefix(64).compactMap(OMPDebugFrame.init).filter { seen.insert($0.id).inserted }
                limitedStack = result["limited"]?.bool == true
                loading = false
                if let first = frames.first {
                    selectedFrameID = first.id
                    await loadScopes(first.id, generation: generation)
                }
            } catch {
                guard isCurrent(generation) else { return }
                loading = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func selectFrame(_ id: Int) {
        guard frames.contains(where: { $0.id == id }), selectedFrameID != id else { return }
        selectedFrameID = id
        clearVariables()
        loadingScopes = true
        enqueue { [weak self] generation in await self?.loadScopes(id, generation: generation) }
    }

    func toggle(_ id: String) {
        guard let node = nodes[id], node.canExpand else { return }
        if expanded.remove(id) != nil { return }
        expanded.insert(id)
        guard node.children == nil, !node.loading else { return }
        nodes[id]?.loading = true
        let frame = selectedFrameID
        enqueue { [weak self] generation in
            guard let self, isCurrent(generation), frame == selectedFrameID, expanded.contains(id), let session else {
                self?.nodes[id]?.loading = false
                return
            }
            do {
                var fields: [String: JSONValue] = ["reference": .int(node.variable.reference)]
                if let frame { fields["frameID"] = .int(frame) }
                let result = try await session.inspectDebug("variables", snapshot: snapshot, fields: fields)
                guard isCurrent(generation), frame == selectedFrameID else { return }
                let values = Array((result["variables"]?.array ?? []).prefix(min(200, max(0, 1000 - nodes.count))))
                var children: [String] = []
                for (index, value) in values.enumerated() {
                    let childID = id + "/" + String(index)
                    nodes[childID] = Node(id: childID, variable: OMPDebugVariable(value), depth: node.depth + 1,
                        ancestors: node.ancestors.union([node.variable.reference]))
                    children.append(childID)
                }
                nodes[id]?.children = children
                nodes[id]?.limited = result["limited"]?.bool == true || values.count < (result["variables"]?.array?.count ?? 0)
                nodes[id]?.loading = false
                nodes[id]?.error = nil
                if nodes[id]?.limited == true { limitedVariables = true }
            } catch {
                guard isCurrent(generation), frame == selectedFrameID else { return }
                nodes[id]?.loading = false
                if !(error is CancellationError) { nodes[id]?.error = error.localizedDescription }
            }
        }
    }

    func stop(keepingValues: Bool = false) {
        generation = UUID()
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); tail = nil; session = nil
        retained = keepingValues
        if keepingValues {
            loading = false; loadingScopes = false
            for id in nodes.keys { nodes[id]?.loading = false }
            return
        }
        frames = []; selectedFrameID = nil; loading = false; limitedStack = false; error = nil
        clearVariables()
    }

    private func clearVariables() {
        nodes = [:]; roots = []; expanded = []; loadingScopes = false; limitedVariables = false
    }

    private func loadScopes(_ frameID: Int, generation: UUID) async {
        guard isCurrent(generation), selectedFrameID == frameID, let session else { return }
        loadingScopes = true; error = nil
        do {
            let result = try await session.inspectDebug("scopes", snapshot: snapshot, fields: ["frameID": .int(frameID)])
            guard isCurrent(generation), selectedFrameID == frameID else { return }
            clearVariables()
            for (index, value) in (result["scopes"]?.array ?? []).prefix(32).enumerated() {
                let id = String(frameID) + ":" + String(index)
                nodes[id] = Node(id: id, variable: OMPDebugVariable(value), depth: 0, ancestors: [], isScope: true)
                roots.append(id)
            }
            limitedVariables = result["limited"]?.bool == true
        } catch {
            guard isCurrent(generation), selectedFrameID == frameID else { return }
            loadingScopes = false
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func isCurrent(_ value: UUID) -> Bool { generation == value && !Task.isCancelled }

    private func enqueue(_ operation: @escaping @MainActor (UUID) async -> Void) {
        let id = UUID(), expected = generation, previous = tail
        let task = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self, isCurrent(expected) else { return }
            await operation(expected)
            tasks[id] = nil
        }
        tasks[id] = task; tail = task
    }
}
