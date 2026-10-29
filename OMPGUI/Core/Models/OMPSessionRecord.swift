import Foundation

enum OMPSessionRecordKind: String, CaseIterable, Sendable {
    case user, response, tool, request, context, configuration, usage, other

    var title: String {
        switch self {
        case .user: "User messages"
        case .response: "Model responses"
        case .tool: "Tool calls"
        case .request: "Model requests"
        case .context: "Context changes"
        case .configuration: "Configuration changes"
        case .usage: "Model usage"
        case .other: "Other records"
        }
    }

    var symbol: String {
        switch self {
        case .user: "person"
        case .response: "message"
        case .tool: "wrench.and.screwdriver"
        case .request: "arrow.up.arrow.down"
        case .context: "arrow.triangle.branch"
        case .configuration: "slider.horizontal.3"
        case .usage: "chart.bar"
        case .other: "ellipsis"
        }
    }
}

enum OMPSessionRecordStatus: String, CaseIterable, Sendable {
    case completed, failed, cancelled, running, interrupted, observed, unrecorded

    var title: String {
        switch self {
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .running: "Running"
        case .interrupted: "Interrupted"
        case .observed: "Observed"
        case .unrecorded: "Result not recorded"
        }
    }
}

enum OMPSessionRecordSortOrder: String, CaseIterable, Sendable {
    case oldestFirst, newestFirst

    var title: String {
        switch self {
        case .oldestFirst: "Time: oldest first"
        case .newestFirst: "Time: newest first"
        }
    }

    var previousPageTitle: String { self == .oldestFirst ? "Older records" : "Newer records" }
    var nextPageTitle: String { self == .oldestFirst ? "Newer records" : "Older records" }
}

/// A bounded display projection. Native payloads and file offsets stay in the reader.
struct OMPSessionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let entryID: String
    let kind: OMPSessionRecordKind
    var status: OMPSessionRecordStatus?
    let title: String
    let summary: String
    let timestamp: Date?
    let model: String?
    let toolCallID: String?
    let duration: Double?
    let tokens: Int?
    var isFinalReply = false
    var roundID: String?
    var roundNumber: Int?
    /// Only native assistant tool blocks have a known response parent.
    var parentRecordID: String?

    var symbol: String {
        isFinalReply ? "ellipsis.message" : kind.symbol
    }
}

struct OMPSessionRecordFilter: Equatable, Sendable {
    var query = ""
    var kind: OMPSessionRecordKind?
    var status: OMPSessionRecordStatus?

    func matches(_ record: OMPSessionRecord) -> Bool {
        if let kind, record.kind != kind { return false }
        if let status, record.status != status { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || [record.title, record.summary, record.model ?? "", record.toolCallID ?? "", record.entryID]
            .contains { $0.localizedStandardContains(needle) }
    }
}

enum OMPSessionDetailSection: String, CaseIterable, Hashable, Sendable {
    case message, thinking, input, executionStart, output, result, requestContext, requestPayload, requestOptions, responses, requestOutput, requestError, payloads, capture, metadata

    var title: String {
        switch self {
        case .message: "Message"
        case .thinking: "Thinking"
        case .input: "Tool input"
        case .executionStart: "Tool execution started"
        case .output: "Tool output"
        case .result: "Result details"
        case .metadata: "Record metadata"
        case .requestContext: "Request context"
        case .requestPayload: "Request payload"
        case .requestOptions: "Request options"
        case .responses: "Provider responses"
        case .requestOutput: "Request output"
        case .requestError: "Request error"
        case .payloads: "Payload revisions"
        case .capture: "Capture metadata"
        }
    }
}

enum OMPSessionDetailKey: Hashable, Sendable {
    case field(String), index(Int)
    var title: String {
        switch self { case .field(let name): name; case .index(let index): "[\(index)]" }
    }
}

struct OMPSessionDetailAddress: Equatable, Sendable {
    var section: OMPSessionDetailSection?
    var path: [OMPSessionDetailKey] = []
    var page = 0
}

struct OMPSessionDetailRow: Identifiable, Equatable, Sendable {
    let key: OMPSessionDetailKey
    let preview: String
    var path: [OMPSessionDetailKey] = []
    var valueKind: OMPSessionDetailValueKind = .scalar
    var count = 0
    var isExpanded = false
    var text: String?
    var page = 0
    var pageCount = 1
    var loadedCount = 0
    var ancestorContinuations: [Bool] = []
    var isLastSibling = true
    var id: [OMPSessionDetailKey] { path.isEmpty ? [key] : path }
    var depth: Int { max(0, path.count - 1) }
    var canExpand: Bool { count > 0 && valueKind != .scalar && path.count < 16 }
    var showsChildPaging: Bool { isExpanded && valueKind != .text && pageCount > 1 }
}

enum OMPSessionDetailValueKind: Equatable, Sendable {
    case scalar, object, array, text
}

struct OMPSessionDetailExpansion: Equatable, Sendable {
    static let maximumBranches = 64
    var paths: Set<[OMPSessionDetailKey]> = []
    /// Each branch selects its own bounded field or text page.
    var pages: [[OMPSessionDetailKey]: Int] = [:]
    /// A one-shot request, resolved by the reader within the visible budgets.
    var expandAll = false
}

struct OMPSessionRecordDetail: Equatable, Sendable {
    let record: OMPSessionRecord
    let sections: [OMPSessionDetailSection]
    let address: OMPSessionDetailAddress
    let rows: [OMPSessionDetailRow]
    let text: String?
    let pageCount: Int
    var isLimited = false
    var viewMode = OMPSessionRecordViewMode.tree
    var expandedPaths: Set<[OMPSessionDetailKey]> = []
    /// Only explicit copy requests populate this; displayed snapshots never retain it.
    var jsonCopy: String?

    /// Copy exactly the bounded, visible fragment, never the original journal.
    var copyText: String {
        text ?? rows.map { String(repeating: "  ", count: viewMode == .tree ? $0.depth : 0) + "\($0.key.title): \($0.text ?? $0.preview)" }.joined(separator: "\n")
    }

    /// Continuations belong after their visible subtree, never between a
    /// parent header and its first child.
    var outlineRows: [OMPSessionDetailOutlineRow] {
        var result: [OMPSessionDetailOutlineRow] = []
        var pending: [OMPSessionDetailRow] = []
        for row in rows {
            while let parent = pending.last, parent.depth >= row.depth {
                result.append(.init(row: pending.removeLast(), isContinuation: true))
            }
            result.append(.init(row: row))
            if row.showsChildPaging { pending.append(row) }
        }
        result.append(contentsOf: pending.reversed().map { .init(row: $0, isContinuation: true) })
        return result
    }
}

struct OMPSessionDetailOutlineRow: Identifiable, Sendable {
    struct ID: Hashable { let path: [OMPSessionDetailKey]; let continuation: Bool }
    let row: OMPSessionDetailRow
    var isContinuation = false
    var id: ID { .init(path: row.path, continuation: isContinuation) }
}

struct OMPSessionRecordRequest: Sendable {
    let file: String
    var filter = OMPSessionRecordFilter()
    var sortOrder = OMPSessionRecordSortOrder.oldestFirst
    var page = 0
    var anchor: String?
    var selectedID: String?
    var address = OMPSessionDetailAddress()
    // The low-level reader retains its original flat default for callers that
    // explicitly consume record pages. The pane chooses tree mode by default.
    var viewMode = OMPSessionRecordViewMode.flat
    var expandedRecordIDs: Set<String>?
    var collapsedRecordIDs: Set<String> = []
    var childPages: [String: Int] = [:]
    var detailExpansion = OMPSessionDetailExpansion()
    var detailViewMode = OMPSessionRecordViewMode.tree
    var includeJSON = false
}

struct OMPSessionRecordPage: Sendable {
    static let size = 80
    let records: [OMPSessionRecord]
    let total: Int
    let page: Int
    let detail: OMPSessionRecordDetail?
    var captureWarning: Bool = false
    var treeRows: [OMPSessionRecordTreeRow] = []
    var totalRounds: Int?
    var totalRoots: Int?
    var expandedRecordIDs: Set<String> = []
    var pageCount: Int {
        if let totalRoots { return max(1, (totalRoots + OMPSessionRecordTree.roundPageSize - 1) / OMPSessionRecordTree.roundPageSize) }
        return max(1, (total + Self.size - 1) / Self.size)
    }
}

struct OMPSessionRecordSource: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let file: String
    var isAgent = false
    var personaIndex: Int?
}

protocol OMPSessionRecordReading: Sendable {
    func read(_ request: OMPSessionRecordRequest) async throws -> OMPSessionRecordPage
    func release() async
}

enum OMPSessionRecordError: Error, Equatable {
    case outsideStore, unavailable, tooLarge, invalidJournal, changed, jsonCopyTooLarge

    var title: String {
        switch self {
        case .outsideStore: "This session is outside the OMP GUI session folder."
        case .unavailable: "The session file is unavailable."
        case .tooLarge: "This session exceeds the history reader limit."
        case .invalidJournal: "The session history is damaged or unsupported."
        case .changed: "The session changed while reading. Refresh to retry."
        case .jsonCopyTooLarge: "This detail exceeds the JSON copy limit."
        }
    }
}
