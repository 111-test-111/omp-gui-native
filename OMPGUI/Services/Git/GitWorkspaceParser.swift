import Foundation

enum GitWorkspaceParser {
    struct NumstatEntry: Equatable, Sendable {
        let path: String
        let oldPath: String?
        let statistics: GitLineStatistics
    }

    struct TreeEntry: Equatable, Sendable {
        let path: String
        let mode: String
        let object: String
    }

    static func text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw GitBrowseError.malformed }
        return text
    }

    static func status(_ data: Data) throws -> GitWorkspaceStatus {
        let text = try text(data)
        guard text.isEmpty || text.hasSuffix("\0") else { throw GitBrowseError.malformed }
        var tokens = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if tokens.last == "" { tokens.removeLast() }
        var result = GitWorkspaceStatus()
        var sawHead = false, sawBranch = false
        var index = 0
        while index < tokens.count {
            let record = tokens[index]
            index += 1
            if record.hasPrefix("# branch.oid ") {
                let value = String(record.dropFirst(13))
                guard value == "(initial)" || GitBrowseError.isObjectID(value) else { throw GitBrowseError.malformed }
                result.head = value == "(initial)" ? nil : value
                sawHead = true
            } else if record.hasPrefix("# branch.head ") {
                let value = String(record.dropFirst(14))
                result.branch = value == "(detached)" ? nil : value
                sawBranch = true
            } else if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst(18))
            } else if record.hasPrefix("# branch.ab ") {
                let fields = record.dropFirst(12).split(separator: " ")
                guard fields.count == 2, fields[0].hasPrefix("+"), fields[1].hasPrefix("-"),
                      let ahead = Int(fields[0].dropFirst()), let behind = Int(fields[1].dropFirst()), ahead >= 0, behind >= 0 else {
                    throw GitBrowseError.malformed
                }
                result.ahead = ahead; result.behind = behind
            } else if record.hasPrefix("# ") || record.hasPrefix("! ") {
                continue
            } else if record.hasPrefix("? ") {
                let path = try path(String(record.dropFirst(2)))
                result.files.append(.init(path: path, status: "?", side: .untracked))
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") || record.hasPrefix("u ") {
                let kind = record.first!
                let fieldCount = kind == "1" ? 8 : kind == "2" ? 9 : 10
                let fields = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == fieldCount + 1, fields[1].count == 2, fields[2].count == 4 else {
                    throw GitBrowseError.malformed
                }
                let currentPath = try path(fields[fieldCount])
                var oldPath: String?
                if kind == "2" {
                    guard index < tokens.count else { throw GitBrowseError.malformed }
                    oldPath = try path(tokens[index]); index += 1
                }
                let xy = Array(fields[1])
                if kind == "u" {
                    guard ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(fields[1]) else { throw GitBrowseError.malformed }
                    result.files.append(.init(path: currentPath, oldPath: oldPath, status: fields[1], side: .conflict, submodule: fields[2]))
                } else {
                    let valid = Set(".MADRCUT")
                    guard xy.allSatisfy(valid.contains) else { throw GitBrowseError.malformed }
                    if xy[0] != "." {
                        result.files.append(.init(path: currentPath, oldPath: oldPath, status: String(xy[0]), side: .index, submodule: fields[2]))
                    }
                    if xy[1] != "." {
                        result.files.append(.init(path: currentPath, status: String(xy[1]), side: .working, submodule: fields[2]))
                    }
                }
            } else { throw GitBrowseError.malformed }
            guard result.files.count <= 40_000 else { throw GitBrowseError.tooLarge }
        }
        guard sawHead, sawBranch else { throw GitBrowseError.malformed }
        return result
    }

    static func history(_ data: Data) throws -> [GitBrowseCommit] {
        let text = try text(data)
        guard text.isEmpty || text.hasSuffix("\0") else { throw GitBrowseError.malformed }
        var fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }
        guard fields.count.isMultiple(of: 5) else { throw GitBrowseError.malformed }
        return try stride(from: 0, to: fields.count, by: 5).map { offset in
            let id = fields[offset]
            let parents = fields[offset + 1].split(separator: " ").map(String.init)
            guard GitBrowseError.isObjectID(id), parents.allSatisfy(GitBrowseError.isObjectID),
                  let seconds = Int64(fields[offset + 3]) else { throw GitBrowseError.malformed }
            return GitBrowseCommit(id: id, parents: parents, author: fields[offset + 2],
                                   date: Date(timeIntervalSince1970: Double(seconds)), subject: fields[offset + 4])
        }
    }

    static func changedFiles(_ data: Data) throws -> [GitBrowseFile] {
        let text = try text(data)
        guard text.isEmpty || text.hasSuffix("\0") else { throw GitBrowseError.malformed }
        var tokens = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if tokens.last == "" { tokens.removeLast() }
        var files: [GitBrowseFile] = []
        var cursor = 0
        while cursor < tokens.count {
            let header = tokens[cursor]; cursor += 1
            var status = header
            var submodule = "N..."
            if header.hasPrefix(":") {
                let fields = header.dropFirst().split(separator: " ")
                guard fields.count == 5 else { throw GitBrowseError.malformed }
                status = String(fields[4])
                if fields[0] == "160000" || fields[1] == "160000" { submodule = "S..." }
            }
            guard let kind = status.first, "MADRCTUXB".contains(kind), cursor < tokens.count else { throw GitBrowseError.malformed }
            let first = try path(tokens[cursor]); cursor += 1
            var oldPath: String?
            var current = first
            if kind == "R" || kind == "C" {
                guard cursor < tokens.count else { throw GitBrowseError.malformed }
                oldPath = first; current = try path(tokens[cursor]); cursor += 1
            }
            files.append(.init(path: current, oldPath: oldPath, status: String(kind), side: .commit, submodule: submodule))
            guard files.count <= 20_000 else { throw GitBrowseError.tooLarge }
        }
        return files
    }

    /// `--numstat -z` leaves tabs/newlines in paths intact. A rename/copy has
    /// an empty path in its header followed by two separately terminated paths.
    static func numstat(_ data: Data) throws -> [NumstatEntry] {
        let text = try text(data)
        guard text.isEmpty || text.hasSuffix("\0") else { throw GitBrowseError.malformed }
        var tokens = text.split(separator: "\0", omittingEmptySubsequences: false)
        if tokens.last == "" { tokens.removeLast() }
        var entries: [NumstatEntry] = []
        var cursor = 0
        while cursor < tokens.count {
            let fields = tokens[cursor].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            cursor += 1
            guard fields.count == 3 else { throw GitBrowseError.malformed }
            let statistics: GitLineStatistics
            if fields[0] == "-", fields[1] == "-" { statistics = .init(isBinary: true) }
            else {
                guard !fields[0].isEmpty, !fields[1].isEmpty,
                      fields[0].utf8.allSatisfy({ (48...57).contains($0) }),
                      fields[1].utf8.allSatisfy({ (48...57).contains($0) }),
                      let added = Int(fields[0]), let deleted = Int(fields[1]) else { throw GitBrowseError.malformed }
                statistics = .init(additions: added, deletions: deleted)
            }
            var path = String(fields[2])
            var oldPath: String?
            if path.isEmpty {
                guard cursor + 1 < tokens.count, !tokens[cursor].isEmpty, !tokens[cursor + 1].isEmpty else {
                    throw GitBrowseError.malformed
                }
                oldPath = String(tokens[cursor]); path = String(tokens[cursor + 1]); cursor += 2
            }
            // No-index output may use an absolute path. Its caller already owns
            // the exact comparison; these labels are never used as pathspecs.
            entries.append(.init(path: path, oldPath: oldPath, statistics: statistics))
            guard entries.count <= 40_000 else { throw GitBrowseError.tooLarge }
        }
        return entries
    }

    static func conflictOursPaths(_ data: Data) throws -> Set<String> {
        let text = try text(data)
        guard text.isEmpty || text.hasSuffix("\0") else { throw GitBrowseError.malformed }
        var paths: Set<String> = []
        for token in text.split(separator: "\0") {
            let fields = token.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw GitBrowseError.malformed }
            let metadata = fields[0].split(separator: " ")
            guard metadata.count == 3, GitBrowseError.isObjectID(String(metadata[1])),
                  ["1", "2", "3"].contains(metadata[2]) else { throw GitBrowseError.malformed }
            let path = try path(String(fields[1]))
            if metadata[2] == "2" { paths.insert(path) }
        }
        return paths
    }

    static func treeEntries(_ data: Data) throws -> [TreeEntry] {
        let text = try text(data)
        guard text.isEmpty || text.hasSuffix("\0") else { throw GitBrowseError.malformed }
        var tokens = text.split(separator: "\0", omittingEmptySubsequences: false)
        if tokens.last == "" { tokens.removeLast() }
        return try tokens.map { token in
            let fields = token.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw GitBrowseError.malformed }
            let header = fields[0].split(separator: " ")
            guard header.count == 3, ["100644", "100755", "120000", "160000"].contains(header[0]),
                  header[1] == (header[0] == "160000" ? "commit" : "blob"),
                  GitBrowseError.isObjectID(String(header[2])) else { throw GitBrowseError.malformed }
            return .init(path: try path(String(fields[1])), mode: String(header[0]), object: String(header[2]))
        }
    }

    static func path(_ value: String) throws -> String {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0"),
              !value.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw GitBrowseError.malformed }
        return value
    }
}
