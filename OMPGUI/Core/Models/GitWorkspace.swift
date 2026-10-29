import Foundation

extension Notification.Name {
    static let gitWorkspaceDidWrite = Notification.Name("dev.ompgui.git-workspace-did-write")
}

struct GitRepositoryLocation: Hashable, Sendable {
    let root: URL
    let gitDirectory: URL
    let commonDirectory: URL
    let indexFile: URL

    init(root: URL, gitDirectory: URL, commonDirectory: URL, indexFile: URL? = nil) {
        self.root = root; self.gitDirectory = gitDirectory; self.commonDirectory = commonDirectory
        self.indexFile = indexFile ?? gitDirectory.appendingPathComponent("index")
    }
}

struct GitWorkspaceRevision: Equatable, Sendable {
    let head: String?
    let headFile: String
    let index: String?
    let reference: String?
}

struct GitCommitReview: Equatable, Sendable {
    let revision: GitWorkspaceRevision
    let files: [GitBrowseFile]
    let branch: String?
}

struct GitCommitReceipt: Equatable, Sendable {
    let id: String
}

enum GitWriteError: LocalizedError, Sendable {
    case busy, changed, unsupportedIndex, operation, nothingStaged, invalidMessage, activeTask
    case uncertain
    case committed(String)

    var errorDescription: String? {
        let key: String = switch self {
        case .busy: "Another Git operation holds this worktree's index. Wait for it to finish, then refresh."
        case .changed: "The branch or staged contents changed. Refresh and review them before trying again."
        case .unsupportedIndex: "This index cannot be updated safely here. Use Git in a terminal."
        case .operation: "Finish the ongoing Git operation or resolve conflicts in a terminal before staging or committing here."
        case .nothingStaged: "Stage changes before committing."
        case .invalidMessage: "Enter a commit message of at most 64 KiB without NUL characters."
        case .activeTask: "An OMP task is active in this worktree. Wait for it to finish before staging or committing."
        case .uncertain: "The commit result could not be confirmed. Your message is kept. Inspect Git history before making another commit."
        case .committed: "Git created commit %@, but its hooks changed the reviewed contents or the index could not be synchronized. Inspect the commit and staging in a terminal before continuing."
        }
        let text = Bundle.main.localizedString(forKey: key, value: nil, table: "Localizable")
        if case .committed(let id) = self { return String(format: text, String(id.prefix(8))) }
        return text
    }

    var requiresInspection: Bool {
        switch self { case .uncertain, .committed: true; default: false }
    }
}

enum GitBrowseMode: String, CaseIterable, Sendable {
    case changes, history
    var title: String { self == .changes ? "Changes" : "History" }
    var symbol: String { self == .changes ? "plusminus" : "point.3.connected.trianglepath.dotted" }
}

enum GitChangeGroup: String, CaseIterable, Sendable {
    case all, conflicts, unstaged, staged, untracked
    var title: String {
        switch self {
        case .all: "All changes"
        case .conflicts: "Conflicts"
        case .unstaged: "Unstaged changes"
        case .staged: "Staged changes"
        case .untracked: "Untracked files"
        }
    }
}

enum GitChangeSide: String, Hashable, Sendable {
    case index, working, untracked, conflict, commit
    var title: String {
        switch self {
        case .index: "HEAD → Index"
        case .working: "Index → Working tree"
        case .untracked: "New file → Working tree"
        case .conflict: "Index stage 2 → Working tree"
        case .commit: "Parent → Commit"
        }
    }
}

struct GitBrowseFile: Hashable, Identifiable, Sendable {
    let path: String
    var oldPath: String?
    let status: String
    let side: GitChangeSide
    var submodule: String = "N..."
    var id: String { side.rawValue + ":" + path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Native numstat counts. Binary contents have no line count; zero is only the
/// count of text lines, never a substitute for an unavailable read.
struct GitLineStatistics: Equatable, Sendable {
    var additions = 0
    var deletions = 0
    var isBinary = false

    func adding(_ other: Self) throws -> Self {
        let (added, addedOverflow) = additions.addingReportingOverflow(other.additions)
        let (deleted, deletedOverflow) = deletions.addingReportingOverflow(other.deletions)
        guard !addedOverflow, !deletedOverflow else { throw GitBrowseError.tooLarge }
        return .init(additions: added, deletions: deleted, isBinary: isBinary || other.isBinary)
    }
}

struct GitWorkspaceStatistics: Equatable, Sendable {
    /// Keys include the comparison side, so a partially staged path has two
    /// independent entries. A missing entry means its count is unavailable.
    let files: [String: GitLineStatistics]
    /// HEAD → working tree, including new files; independent of staging.
    let total: GitLineStatistics?
}

struct GitWorkspaceStatus: Equatable, Sendable {
    var branch: String?
    var head: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var files: [GitBrowseFile] = []
    var operations: [String] = []
    /// Complete index bytes and the worktree's own HEAD, captured around status.
    /// A missing revision permits browsing, never a write.
    var revision: GitWorkspaceRevision?
    var changedFileCount: Int { Set(files.map(\.path)).count }

    func files(in group: GitChangeGroup) -> [GitBrowseFile] {
        files.filter {
            switch group {
            case .all: true
            case .conflicts: $0.side == .conflict
            case .unstaged: $0.side == .working
            case .staged: $0.side == .index
            case .untracked: $0.side == .untracked
            }
        }
    }
}

struct GitHistoryReference: Hashable, Identifiable, Sendable {
    let name: String
    let commit: String
    var id: String { name }
    var title: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }
}

struct GitHistorySource: Equatable, Sendable {
    let head: String?
    let references: [GitHistoryReference]
    var tips: [String] { Array(Set(references.map(\.commit) + [head].compactMap { $0 })).sorted() }
    func tips(for reference: String?) -> [String] {
        guard let reference else { return tips }
        if reference == "HEAD" { return [head].compactMap { $0 } }
        return references.first { $0.name == reference }.map { [$0.commit] } ?? []
    }
}

struct GitBrowseCommit: Hashable, Identifiable, Sendable {
    let id: String
    let parents: [String]
    let author: String
    let date: Date
    let subject: String
    var shortID: String { String(id.prefix(8)) }
}

struct GitHistoryPage: Sendable {
    let commits: [GitBrowseCommit]
    let hasMore: Bool
}

struct GitCommitDetails: Equatable, Sendable {
    let commit: GitBrowseCommit
    let message: String
    let parent: String?
    let files: [GitBrowseFile]
}

struct GitFileComparison: Hashable, Sendable {
    let file: GitBrowseFile
    var commit: String?
    var parent: String?
}

enum GitBrowseRoute: Hashable, Sendable {
    case compose
    case commit(String)
    case file(GitFileComparison)
}

enum GitBrowseError: LocalizedError, Sendable {
    case malformed
    case tooLarge
    case changedDuringRead
    case missingConflictSide
    case missingRepository

    var errorDescription: String? {
        let key: String = switch self {
        case .malformed: "Git returned data that could not be read safely."
        case .tooLarge: "This Git result exceeds the browser's size limit. Narrow the scope or open the repository externally."
        case .changedDuringRead: "The repository changed during this read. Refresh to read its current state."
        case .missingConflictSide: "This conflict has no index stage 2. Open the working file to inspect its conflict markers."
        case .missingRepository: "This worktree is no longer available."
        }
        return Bundle.main.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
