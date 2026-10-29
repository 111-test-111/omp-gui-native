import Foundation

enum OMPSessionRecordViewMode: String, CaseIterable, Sendable {
    case tree, flat
    var title: String { self == .tree ? "Tree view" : "Flat view" }
}

struct OMPSessionRecordTreeRow: Identifiable, Equatable, Sendable {
    let record: OMPSessionRecord
    let depth: Int
    var ancestorContinuations: [Bool] = []
    var isLastSibling = true
    var childCount = 0
    var isExpanded = false
    var isContext = false
    var isSessionEvents = false
    var continuationParentID: String?
    var canLoadMore = true
    var page = 0
    var pageCount = 1
    var id: String { continuationParentID.map { $0 + ":tree-more" } ?? record.id }
}

/// Groups the complete current ancestry before filtering or paging. Timestamps
/// order siblings, but never infer ownership or reverse a round's execution.
enum OMPSessionRecordTree {
    static let roundPageSize = 20
    static let childPageSize = 40
    static let maximumRows = 480

    struct Page: Sendable {
        var rows: [OMPSessionRecordTreeRow]
        var totalRounds: Int
        var totalRoots: Int
        var totalMatches: Int
        var page: Int
        var expanded: Set<String>
    }

    static func page(records: [OMPSessionRecord], filter: OMPSessionRecordFilter,
                     order: OMPSessionRecordSortOrder, page: Int, anchor: String?,
                     expanded: Set<String>?, collapsed: Set<String> = [], childPages: [String: Int], sessionID: String) -> Page {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let eventID = sessionID + "session-events"
        var roots = records.filter { $0.kind == .user }
            .sorted { ($0.roundNumber ?? 0) < ($1.roundNumber ?? 0) }
        let events = records.filter { $0.roundID == nil }
        if let first = events.first {
            roots.insert(.init(id: eventID, entryID: "", kind: .other, title: "Session events", summary: "",
                               timestamp: first.timestamp, model: nil, toolCallID: nil, duration: nil, tokens: nil), at: 0)
        }
        var children: [String: [OMPSessionRecord]] = [:]
        var parents: [String: String] = [:]
        for record in records where record.kind != .user {
            let response = record.parentRecordID.flatMap { byID[$0] }
            let parent = response?.roundID == record.roundID ? response?.id : nil
            let parentID = parent ?? record.roundID ?? eventID
            children[parentID, default: []].append(record)
            parents[record.id] = parentID
        }
        let matches = Set(records.filter(filter.matches).map(\.id))
        var included = matches
        var requiredParents: Set<String> = []
        for id in matches {
            var current = parents[id]
            while let parent = current {
                included.insert(parent); requiredParents.insert(parent); current = parents[parent]
            }
        }
        let hasFilter = filter.kind != nil || filter.status != nil || !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        roots = roots.filter { included.contains($0.id) }
        if order == .newestFirst { roots.reverse() }
        var anchorRoot = anchor
        while let id = anchorRoot, let parent = parents[id] { anchorRoot = parent }
        let anchoredPage = anchorRoot.flatMap { id in roots.firstIndex { $0.id == id } }.map { $0 / roundPageSize }
        let lastPage = max(0, (roots.count - 1) / roundPageSize)
        let currentPage = min(lastPage, max(0, anchoredPage ?? page))
        let visibleRoots = Array(roots.dropFirst(currentPage * roundPageSize).prefix(roundPageSize))
        var open = expanded ?? []
        if expanded == nil, let latest = visibleRoots.max(by: { ($0.roundNumber ?? 0) < ($1.roundNumber ?? 0) }) {
            open.insert(latest.id)
            for child in children[latest.id] ?? [] where children[child.id]?.isEmpty == false { open.insert(child.id) }
        }
        // Search opens only the required ancestor paths; it does not overwrite
        // the user's normal expanded/collapsed state when the filter is cleared.
        var effectiveOpen = open
        if hasFilter { effectiveOpen.formUnion(requiredParents); effectiveOpen.subtract(collapsed) }
        var rows: [OMPSessionRecordTreeRow] = []
        func append(_ record: OMPSessionRecord, depth: Int, ancestors: [Bool], last: Bool, reservedRoots: Int) {
            let descendants = (children[record.id] ?? []).filter { included.contains($0.id) }
            let isOpen = effectiveOpen.contains(record.id)
            rows.append(.init(record: record, depth: depth, ancestorContinuations: ancestors, isLastSibling: last,
                              childCount: descendants.count, isExpanded: isOpen, isContext: !matches.contains(record.id),
                              isSessionEvents: record.id == eventID))
            guard isOpen, !descendants.isEmpty else { return }
            let pageCount = max(1, (descendants.count + childPageSize - 1) / childPageSize)
            let childPage = min(pageCount - 1, max(0, childPages[record.id] ?? 0))
            let batch = descendants.dropFirst(childPage * childPageSize).prefix(childPageSize)
            var consumed = 0
            for child in batch {
                // Leave room for remaining roots and each active continuation.
                guard rows.count < maximumRows - reservedRoots - depth - 2 else { break }
                let final = consumed + 1 == batch.count && pageCount == 1
                append(child, depth: depth + 1, ancestors: ancestors + [!last], last: final, reservedRoots: reservedRoots)
                consumed += 1
            }
            if pageCount > 1 || consumed < batch.count {
                rows.append(.init(record: record, depth: depth + 1, ancestorContinuations: ancestors + [!last],
                                  childCount: descendants.count, continuationParentID: record.id,
                                  canLoadMore: consumed == batch.count, page: childPage, pageCount: pageCount))
            }
        }
        for (index, record) in visibleRoots.enumerated() {
            append(record, depth: 0, ancestors: [], last: true, reservedRoots: visibleRoots.count - index - 1)
        }
        return .init(rows: rows, totalRounds: roots.filter { $0.kind == .user }.count, totalRoots: roots.count,
                     totalMatches: matches.count, page: currentPage, expanded: open)
    }
}
