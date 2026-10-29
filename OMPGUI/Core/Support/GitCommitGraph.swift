import Foundation

/// Maple's lane/merge-node presentation inspired this row-local layout.
/// See THIRD_PARTY_NOTICES.md for Pool Camacho's MIT attribution.
/// Pending parents survive the page boundary. Appending commits never changes
/// a previously laid-out row, even when a parent was not on that page yet.
struct GitCommitGraph: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let fromLane: Int
        let toLane: Int
        let fromY: Double
        let toY: Double
        let colorLane: Int
    }

    struct Row: Equatable, Sendable {
        let commitID: String
        let lane: Int
        let isMerge: Bool
        let segments: [Segment]
    }

    let rows: [Row]
    let laneCount: Int
    let pendingParents: [String?]

    static let empty = GitCommitGraph(rows: [], laneCount: 1, pendingParents: [])

    static func build(_ commits: [GitBrowseCommit]) throws -> Self {
        var lanes: [String?] = []
        var rows: [Row] = []
        var seen = Set<String>()
        var maximum = 1
        var segmentCount = 0
        for commit in commits {
            try Task.checkCancellation()
            guard commit.parents.count <= 512 else { throw GitBrowseError.tooLarge }
            guard seen.insert(commit.id).inserted,
                  commit.parents.allSatisfy({ $0 != commit.id && !seen.contains($0) }) else {
                throw GitBrowseError.malformed // Requires child-before-parent ordering.
            }
            let matching = lanes.indices.filter { lanes[$0] == commit.id }
            let node: Int
            if let first = matching.first { node = first }
            else if let free = lanes.firstIndex(of: nil) { node = free }
            else { node = lanes.count; lanes.append(nil) }
            var segments: [Segment] = []
            for lane in lanes.indices where lanes[lane] != nil {
                if lanes[lane] == commit.id {
                    segments.append(.init(fromLane: lane, toLane: node, fromY: 0, toY: 0.5, colorLane: node))
                } else {
                    segments.append(.init(fromLane: lane, toLane: lane, fromY: 0, toY: 1, colorLane: lane))
                }
            }
            for lane in matching { lanes[lane] = nil }
            for (index, parent) in commit.parents.enumerated() {
                let target: Int
                if let existing = lanes.firstIndex(where: { $0 == parent }) { target = existing }
                else if index == 0, lanes[node] == nil { target = node; lanes[node] = parent }
                else if let free = lanes.firstIndex(of: nil) { target = free; lanes[free] = parent }
                else { target = lanes.count; lanes.append(parent) }
                segments.append(.init(fromLane: node, toLane: target, fromY: 0.5, toY: 1, colorLane: target))
            }
            maximum = max(maximum, max(node + 1, lanes.count))
            segmentCount += segments.count
            guard maximum <= 512, segmentCount <= 200_000 else { throw GitBrowseError.tooLarge }
            rows.append(.init(commitID: commit.id, lane: node, isMerge: commit.parents.count > 1, segments: segments))
        }
        return .init(rows: rows, laneCount: maximum, pendingParents: lanes)
    }
}
