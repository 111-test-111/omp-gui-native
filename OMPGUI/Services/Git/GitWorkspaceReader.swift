import Foundation
import Darwin

enum GitStatisticsTotal: Sendable {
    case read
    case reuse(GitLineStatistics?)
}

/// Cheap inputs, separate from native line counting. Keep the previous paths in
/// the metadata read so staging a reverted path away can still reuse its total.
struct GitStatisticsInputs: Equatable, Sendable {
    let location: GitRepositoryLocation
    let head: String?
    let index: String?
    let indexMetadata: PreviewFileMetadata?
    let files: [GitBrowseFile]
    let paths: Set<String>
    let metadata: [String: PreviewFileMetadata?]
    let attributePaths: Set<String>
    let attributes: [String: PreviewFileMetadata?]
    let submodules: [String: String]
    var configuration: String

    func canReuseTotal(_ previous: Self) -> Bool {
        location == previous.location && head == previous.head && configuration == previous.configuration
            && paths.isSubset(of: previous.paths) && attributePaths.isSubset(of: previous.attributePaths)
            && previous.paths.allSatisfy { metadata[$0] == previous.metadata[$0] }
            && previous.attributePaths.allSatisfy { attributes[$0] == previous.attributes[$0] }
            && previous.paths.allSatisfy { submodules[$0] == previous.submodules[$0] }
    }

    func canReuseRows(_ previous: Self) -> Bool {
        canReuseTotal(previous) && files == previous.files
            && (index != nil && previous.index != nil ? index == previous.index : indexMetadata == previous.indexMetadata)
    }
}

struct GitWorkspaceReading: Sendable {
    var locate: @Sendable (String) async throws -> GitRepositoryLocation?
    var status: @Sendable (GitRepositoryLocation) async throws -> GitWorkspaceStatus
    var source: @Sendable (GitRepositoryLocation, String?) async throws -> GitHistorySource
    var history: @Sendable (GitRepositoryLocation, [String], Int, Int) async throws -> GitHistoryPage
    var details: @Sendable (GitRepositoryLocation, String, String?) async throws -> GitCommitDetails
    var diff: @Sendable (GitRepositoryLocation, GitFileComparison) async throws -> DiffFile
    var statistics: @Sendable (GitRepositoryLocation, GitFileComparison) async throws -> GitLineStatistics = { _, _ in throw GitBrowseError.malformed }
    var statisticsInputs: @Sendable (GitRepositoryLocation, GitWorkspaceStatus, [String]) async throws -> GitStatisticsInputs = GitWorkspaceReader.statisticsInputs
    var workspaceStatistics: @Sendable (GitRepositoryLocation, GitWorkspaceStatus, GitStatisticsTotal) async throws -> GitWorkspaceStatistics = { _, _, _ in throw GitBrowseError.malformed }

    static let live = GitWorkspaceReading(locate: GitWorkspaceReader.locate, status: GitWorkspaceReader.status,
        source: GitWorkspaceReader.source, history: GitWorkspaceReader.history, details: GitWorkspaceReader.details,
        diff: GitWorkspaceReader.diff, statistics: GitWorkspaceReader.statistics,
        workspaceStatistics: GitWorkspaceReader.workspaceStatistics)
}

/// Never writes repository data. Net counts use a disposable index/object store;
/// complete-record parsers reject bounded tails and replacement UTF-8.
enum GitWorkspaceReader {
    static let maximumResultBytes = 8 * 1_024 * 1_024
    static let maximumPatchBytes = PreviewFileDiff.maximumPatchBytes
    static let pageSize = 100
    static let maximumCommits = 2_000

    private static func run(_ git: Git, _ arguments: [String], input: Data? = nil,
                            limit: Int = maximumResultBytes, allowsDifference: Bool = false,
                            environment: [String: String] = [:]) async throws -> ShellResult {
        let result = try await git.run(["--no-pager", "-c", "core.fsmonitor=false"] + arguments,
            environment: ["LC_ALL": "C", "GIT_PAGER": "cat"].merging(environment) { _, value in value },
            input: input, timeout: 20, lane: .read, outputLimit: limit + 1)
        try Task.checkCancellation()
        guard result.stdout.count <= limit else { throw GitBrowseError.tooLarge }
        if !allowsDifference || result.status != 1 { try Git.check(result) }
        return result
    }

    private static func line(_ git: Git, _ arguments: [String]) async throws -> String {
        let value = try GitWorkspaceParser.text(await run(git, arguments, limit: 64 * 1_024).stdout)
        guard value.hasSuffix("\n") else { throw GitBrowseError.malformed }
        return String(value.dropLast()) // A path's own whitespace/newlines are data.
    }

    @concurrent static func locate(_ directory: String) async throws -> GitRepositoryLocation? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitBrowseError.missingRepository
        }
        let git = Git(directory)
        let inside = try await git.run(["rev-parse", "--is-inside-work-tree"], environment: ["LC_ALL": "C"],
                                       timeout: 15, lane: .read, outputLimit: 65_537)
        try Task.checkCancellation()
        if !inside.succeeded {
            if inside.errorOutput.contains("not a git repository") { return nil }
            try Git.check(inside)
        }
        guard inside.trimmedOutput == "true" else { return nil }
        let root = try await line(git, ["rev-parse", "--path-format=absolute", "--show-toplevel"])
        let gitDir = try await line(git, ["rev-parse", "--absolute-git-dir"])
        let common = try await line(git, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let index = try await line(git, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
        return .init(root: URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath(),
                     gitDirectory: URL(fileURLWithPath: gitDir).standardizedFileURL.resolvingSymlinksInPath(),
                     commonDirectory: URL(fileURLWithPath: common).standardizedFileURL.resolvingSymlinksInPath(),
                     // Canonicalize its parent, not the index leaf: aliases of
                     // the same worktree must compare equal, while a symlink
                     // index must remain detectable by write authorization.
                     indexFile: URL(fileURLWithPath: index).deletingLastPathComponent().standardizedFileURL
                        .resolvingSymlinksInPath().appendingPathComponent(URL(fileURLWithPath: index).lastPathComponent))
    }

    private static func validate(_ location: GitRepositoryLocation) async throws {
        let current = try await line(Git(location.root.path), ["rev-parse", "--absolute-git-dir"])
        guard URL(fileURLWithPath: current).standardizedFileURL.resolvingSymlinksInPath() == location.gitDirectory else {
            throw GitBrowseError.missingRepository
        }
    }

    private static func head(_ git: Git) async throws -> String? {
        let result = try await run(git, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], limit: 4_096, allowsDifference: true)
        if result.status == 1 { return nil }
        let value = result.trimmedOutput
        guard GitBrowseError.isObjectID(value) else { throw GitBrowseError.malformed }
        return value
    }

    private static func stamp(_ url: URL) -> PreviewFileMetadata? {
        var value = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { return nil }
        return PreviewFileMetadata(value)
    }

    private static func changePaths(_ status: GitWorkspaceStatus) -> Set<String> {
        Set(status.files.flatMap { [$0.path] + [$0.oldPath].compactMap { $0 } })
    }

    private static func attributePaths(_ paths: Set<String>) -> Set<String> {
        var result: Set<String> = [".gitattributes"]
        for path in paths {
            var directory = (path as NSString).deletingLastPathComponent
            while !directory.isEmpty && directory != "." {
                result.insert(directory + "/.gitattributes")
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        return result
    }

    @concurrent static func statisticsInputs(_ location: GitRepositoryLocation, _ expected: GitWorkspaceStatus,
                                            _ previousPaths: [String]) async throws -> GitStatisticsInputs {
        try await validate(location)
        let git = Git(location.root.path)
        let indexBefore = stamp(location.indexFile)
        let paths = changePaths(expected)
        let allPaths = paths.union(previousPaths)
        guard allPaths.count <= 160_000 else { throw GitBrowseError.tooLarge }
        for path in allPaths { _ = try GitWorkspaceParser.path(path) }
        // Git resolves includes, worktree/global configuration and conditional
        // includes itself. Keep only a digest, not credentials/config values.
        let configuration = try await run(git, ["config", "--null", "--list"]).stdout
        let external = try await run(git, ["config", "--null", "--path", "--get", "core.attributesfile"],
                                     limit: 65_536, allowsDifference: true)
        var globalAttributes: Set<String> = [location.commonDirectory.appendingPathComponent("info/attributes").path]
        if external.status == 0 {
            let value = try GitWorkspaceParser.text(external.stdout)
            guard value.hasSuffix("\0") else { throw GitBrowseError.malformed }
            let path = String(value.dropLast())
            if !path.isEmpty {
                globalAttributes.insert((path.hasPrefix("/") ? URL(fileURLWithPath: path) : location.root.appendingPathComponent(path)).standardizedFileURL.path)
            }
        } else {
            let environment = LoginEnvironment.current
            if let config = environment["XDG_CONFIG_HOME"], !config.isEmpty {
                globalAttributes.insert(URL(fileURLWithPath: config).appendingPathComponent("git/attributes").path)
            } else if let home = environment["HOME"] {
                globalAttributes.insert(URL(fileURLWithPath: home).appendingPathComponent(".config/git/attributes").path)
            }
        }
        let currentAttributes = Set(attributePaths(paths).map { location.root.appendingPathComponent($0).path }).union(globalAttributes)
        let allAttributes = Set(attributePaths(allPaths).map { location.root.appendingPathComponent($0).path }).union(globalAttributes)
        let metadata = Dictionary(uniqueKeysWithValues: allPaths.map { ($0, stamp(location.root.appendingPathComponent($0))) })
        let attributes = Dictionary(uniqueKeysWithValues: allAttributes.map { path -> (String, PreviewFileMetadata?) in
            let url = URL(fileURLWithPath: path)
            // A common explicit empty attributes file. macOS advances this
            // device's mtime/ctime on writes, although its contents stay empty.
            return (path, url.resolvingSymlinksInPath().path == "/dev/null" ? nil : PreviewFileMetadata.read(url))
        })
        var submodules: [String: String] = [:]
        for path in allPaths {
            let directory = location.root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                let commit = try await head(Git(directory.path))
                // C compares the submodule HEAD to the superproject's index;
                // it changes on staging. The inner dirty flags do not.
                let dirty = expected.files.first { $0.path == path && $0.submodule.hasPrefix("S") }?.submodule.dropFirst(2) ?? ".."
                submodules[path] = (commit ?? "unborn") + ":" + dirty
            }
        }
        if let revision = expected.revision {
            guard try GitWorkspaceIndex.revision(location, head: expected.head) == revision else { throw GitBrowseError.changedDuringRead }
        }
        guard stamp(location.indexFile) == indexBefore, try await head(git) == expected.head else { throw GitBrowseError.changedDuringRead }
        try await validate(location)
        return .init(location: location, head: expected.head, index: expected.revision?.index, indexMetadata: indexBefore,
                     files: expected.files, paths: paths, metadata: metadata, attributePaths: currentAttributes,
                     attributes: attributes, submodules: submodules, configuration: GitWorkspaceIndex.digest(configuration))
    }

    @concurrent static func status(_ location: GitRepositoryLocation) async throws -> GitWorkspaceStatus {
        try await validate(location)
        let git = Git(location.root.path)
        // Unsupported index layouts remain browsable, but cannot authorize a
        // mutation. Never manufacture a revision from truncated index bytes.
        let before = try? GitWorkspaceIndex.revision(location, head: nil)
        var status = try GitWorkspaceParser.status(await run(git, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]).stdout)
        for (file, title) in [("MERGE_HEAD", "Merge in progress"), ("rebase-merge", "Rebase in progress"),
                              ("rebase-apply", "Rebase in progress"), ("CHERRY_PICK_HEAD", "Cherry-pick in progress"),
                              ("REVERT_HEAD", "Revert in progress"), ("BISECT_LOG", "Bisect in progress")] {
            if FileManager.default.fileExists(atPath: location.gitDirectory.appendingPathComponent(file).path), !status.operations.contains(title) {
                status.operations.append(title)
            }
        }
        try await validate(location)
        guard try await head(git) == status.head else { throw GitBrowseError.changedDuringRead }
        if let before, let after = try? GitWorkspaceIndex.revision(location, head: status.head) {
            guard before.index == after.index, before.headFile == after.headFile else { throw GitBrowseError.changedDuringRead }
            status.revision = after
        }
        return status
    }

    @concurrent static func source(_ location: GitRepositoryLocation, _ head: String?) async throws -> GitHistorySource {
        try await validate(location)
        let git = Git(location.root.path)
        let raw = try await run(git, ["for-each-ref", "--sort=refname",
            "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(objecttype)%00%(*objecttype)",
            "refs/heads", "refs/remotes", "refs/tags"])
        let text = try GitWorkspaceParser.text(raw.stdout)
        var references: [GitHistoryReference] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { throw GitBrowseError.malformed }
            let name = fields[0]
            guard ["refs/heads/", "refs/remotes/", "refs/tags/"].contains(where: name.hasPrefix) else { throw GitBrowseError.malformed }
            let commit: String
            if fields[3] == "commit" { commit = fields[1] }
            else if fields[4] == "commit" { commit = fields[2] }
            else if fields[3] == "tag" {
                // Nested annotated tags need recursive peeling; blob/tree tags
                // are valid references but cannot be revision-walk starting tips.
                let peeled = try await git.run(["rev-parse", "--verify", "--quiet", "--end-of-options", name + "^{commit}"],
                                               timeout: 15, lane: .read, outputLimit: 4_097)
                if peeled.status == 1 { continue }
                try Git.check(peeled)
                commit = peeled.trimmedOutput
            } else { continue }
            guard GitBrowseError.isObjectID(commit) else { throw GitBrowseError.malformed }
            references.append(.init(name: name, commit: commit))
            guard references.count <= 10_000 else { throw GitBrowseError.tooLarge }
        }
        if let head { guard GitBrowseError.isObjectID(head) else { throw GitBrowseError.malformed } }
        try await validate(location)
        return .init(head: head, references: references)
    }

    @concurrent static func history(_ location: GitRepositoryLocation, _ tips: [String], _ offset: Int, _ count: Int) async throws -> GitHistoryPage {
        guard offset >= 0, count > 0, count <= maximumCommits, tips.allSatisfy(GitBrowseError.isObjectID) else { throw GitBrowseError.malformed }
        guard !tips.isEmpty else { return .init(commits: [], hasMore: false) }
        try await validate(location)
        let result = try await run(Git(location.root.path), ["log", "--topo-order", "--no-decorate", "--no-show-signature",
            "--encoding=UTF-8", "-z", "--format=%H%x00%P%x00%an%x00%at%x00%s", "--skip=\(offset)", "--max-count=\(count + 1)", "--stdin", "--"],
            input: Data((tips.joined(separator: "\n") + "\n").utf8))
        let commits = try GitWorkspaceParser.history(result.stdout)
        try await validate(location)
        return .init(commits: Array(commits.prefix(count)), hasMore: commits.count > count)
    }

    @concurrent static func details(_ location: GitRepositoryLocation, _ commit: String, _ selectedParent: String?) async throws -> GitCommitDetails {
        guard GitBrowseError.isObjectID(commit) else { throw GitBrowseError.malformed }
        try await validate(location)
        let git = Git(location.root.path)
        let record = try await run(git, ["show", "--no-patch", "--no-show-signature", "--encoding=UTF-8", "-z",
                                      "--format=%H%x00%P%x00%an%x00%at%x00%s", commit, "--"])
        guard let entry = try GitWorkspaceParser.history(record.stdout).first else { throw GitBrowseError.malformed }
        let parent = selectedParent ?? entry.parents.first
        if let parent { guard entry.parents.contains(parent) else { throw GitBrowseError.malformed } }
        let message = try GitWorkspaceParser.text(await run(git, ["show", "--no-patch", "--no-show-signature",
            "--encoding=UTF-8", "--format=format:%B", commit, "--"], limit: 65_536).stdout)
        var arguments = ["diff-tree", "--no-commit-id", "--no-ext-diff", "--no-textconv", "--find-renames=50%", "-r", "--raw", "--no-abbrev", "-z"]
        if let parent { arguments += [parent, commit] } else { arguments += ["--root", commit] }
        arguments.append("--")
        let files = try GitWorkspaceParser.changedFiles(await run(git, arguments).stdout)
        try await validate(location)
        return .init(commit: entry, message: message, parent: parent, files: files)
    }

    /// Both the patch and the line counts use exactly the same Git comparison,
    /// including the old blob of a rename and the selected merge parent.
    private static func comparisonData(_ location: GitRepositoryLocation, _ comparison: GitFileComparison,
                                       statistics: Bool) async throws -> Data {
        try await validate(location)
        let git = Git(location.root.path)
        let file = comparison.file
        _ = try GitWorkspaceParser.path(file.path)
        if let old = file.oldPath { _ = try GitWorkspaceParser.path(old) }
        let index = location.indexFile
        let url = location.root.appendingPathComponent(file.path)
        let indexStamp = stamp(index)
        let fileStamp = stamp(url)
        let headBefore = file.side == .index ? try await head(git) : nil
        var arguments = ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/"]
        var allowsDifference = false
        switch file.side {
        case .index:
            // Viewing the new side of a rename against HEAD keeps its old
            // source blob, independent of other rename candidates in the index.
            if let old = file.oldPath, !file.submodule.hasPrefix("S") {
                guard let headBefore else { throw GitBrowseError.changedDuringRead }
                arguments += [headBefore + ":" + old, ":" + file.path]
            } else if let old = file.oldPath {
                arguments += ["--cached", "--find-renames=50%", "--", old, file.path]
            } else { arguments += ["--cached"] + [headBefore].compactMap { $0 } + ["--", file.path] }
        case .working:
            arguments += ["--", file.path]
        case .untracked:
            arguments += ["--no-index", "--", "/dev/null", url.path]
            allowsDifference = true
        case .conflict:
            let stages = try await run(git, ["--literal-pathspecs", "ls-files", "--unmerged", "-z", "--", file.path])
            guard try GitWorkspaceParser.conflictOursPaths(stages.stdout).contains(file.path) else { throw GitBrowseError.missingConflictSide }
            arguments += ["--ours", "--", file.path]
        case .commit:
            guard let commit = comparison.commit, GitBrowseError.isObjectID(commit),
                  comparison.parent.map(GitBrowseError.isObjectID) ?? true else { throw GitBrowseError.malformed }
            if let parent = comparison.parent, let old = file.oldPath, !file.submodule.hasPrefix("S") {
                arguments += [parent + ":" + old, commit + ":" + file.path]
            } else if let parent = comparison.parent, let old = file.oldPath {
                arguments += ["--find-renames=50%", parent, commit, "--", old, file.path]
            } else if let parent = comparison.parent {
                arguments += [parent, commit, "--", file.path]
            } else {
                arguments = ["--literal-pathspecs", "show", "--format=", "--no-show-signature", "--no-ext-diff", "--no-textconv", "--no-color",
                             "--no-renames", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", commit, "--", file.path]
            }
        }
        if statistics { arguments.insert(contentsOf: ["--numstat", "-z"], at: 2) }
        let result = try await run(git, arguments, limit: statistics ? maximumResultBytes : maximumPatchBytes, allowsDifference: allowsDifference)
        guard file.side == .commit || (stamp(index) == indexStamp && stamp(url) == fileStamp) else {
            throw GitBrowseError.changedDuringRead
        }
        if file.side == .index, try await head(git) != headBefore { throw GitBrowseError.changedDuringRead }
        try await validate(location)
        return result.stdout
    }

    @concurrent static func statistics(_ location: GitRepositoryLocation, _ comparison: GitFileComparison) async throws -> GitLineStatistics {
        let entries = try GitWorkspaceParser.numstat(await comparisonData(location, comparison, statistics: true))
        // A type change can have two records, and an unmerged path can prepend
        // a zero-count record. Accept those only for the same selected path.
        guard Set(entries.map(\.path)).count <= 1 else { throw GitBrowseError.malformed }
        return try entries.reduce(GitLineStatistics()) { try $0.adding($1.statistics) }
    }

    @concurrent static func diff(_ location: GitRepositoryLocation, _ comparison: GitFileComparison) async throws -> DiffFile {
        let patch = try await comparisonData(location, comparison, statistics: false)
        let file = comparison.file
        // `git diff --ours` can put "* Unmerged path ..." before its patch.
        // Parse real file headers directly: the hunk-only convenience wrapper
        // would synthesize an empty first file in front of that diagnostic.
        let files = DiffParser.parse(try GitWorkspaceParser.text(patch))
        guard files.count <= 1 else { throw GitBrowseError.malformed }
        var parsed = files.first ?? DiffFile(path: file.path, change: .modified, isBinary: false, hunks: [])
        parsed.path = file.path
        if let old = file.oldPath { parsed.oldPath = old; parsed.change = file.status == "C" ? .added : .renamed }
        if file.side == .untracked || file.status == "A" { parsed.change = .added }
        if file.status == "D" { parsed.change = .deleted }
        return parsed
    }

    /// Batch the common tracked comparisons. Only untracked files and renamed
    /// blobs need individual reads, with a bounded number of child tasks. Never
    /// build a total by summing only the visible/filtered subset of the list.
    @concurrent static func workspaceStatistics(_ location: GitRepositoryLocation, _ expected: GitWorkspaceStatus,
                                                total: GitStatisticsTotal = .read) async throws -> GitWorkspaceStatistics {
        guard try await status(location) == expected else { throw GitBrowseError.changedDuringRead }
        let git = Git(location.root.path)
        let paths = Set(expected.files.flatMap { [$0.path] + [$0.oldPath].compactMap { $0 } })
        let stamps = Dictionary(uniqueKeysWithValues: paths.map { ($0, stamp(location.root.appendingPathComponent($0))) })
        let indexStamp = stamp(location.indexFile)
        let options = ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                       "--no-renames", "--submodule=short", "--numstat", "-z"]
        func counts(_ arguments: [String]) async throws -> [String: GitLineStatistics] {
            let entries = try GitWorkspaceParser.numstat(await run(git, arguments).stdout)
            var values: [String: GitLineStatistics] = [:]
            for entry in entries {
                _ = try GitWorkspaceParser.path(entry.path)
                guard entry.oldPath == nil else { throw GitBrowseError.malformed }
                values[entry.path] = try (values[entry.path] ?? .init()).adding(entry.statistics)
            }
            return values
        }
        var files: [String: GitLineStatistics] = [:]
        let staged = expected.files.filter { $0.side == .index && $0.oldPath == nil }
        if !staged.isEmpty {
            let values = try await counts(options + ["--cached"] + [expected.head].compactMap { $0 } + ["--"])
            for file in staged { files[file.id] = values[file.path] ?? .init() }
        }
        let working = expected.files.filter { $0.side == .working || $0.side == .conflict }
        if !working.isEmpty {
            let values = try await counts(options + ["--ours", "--"])
            let conflicts = working.filter { $0.side == .conflict }
            let ours: Set<String>
            if conflicts.isEmpty { ours = [] }
            else {
                ours = try GitWorkspaceParser.conflictOursPaths(await run(git, ["ls-files", "--unmerged", "-z"]).stdout)
            }
            for file in working where file.side != .conflict || ours.contains(file.path) {
                files[file.id] = values[file.path] ?? .init()
            }
        }
        let individual = expected.files.filter { $0.side == .untracked || ($0.side == .index && $0.oldPath != nil) }
        try await withThrowingTaskGroup(of: (String, GitLineStatistics?).self) { group in
            var iterator = individual.makeIterator()
            func enqueue(_ file: GitBrowseFile) {
                group.addTask {
                    do { return (file.id, try await statistics(location, .init(file: file))) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (file.id, nil) }
                }
            }
            for _ in 0..<4 { if let file = iterator.next() { enqueue(file) } }
            while let (id, value) = try await group.next() {
                files[id] = value
                if let file = iterator.next() { enqueue(file) }
            }
        }
        let net: GitLineStatistics?
        switch total {
        case .reuse(let value): net = value
        case .read:
            do { net = try await netStatistics(location, expected) }
            catch is CancellationError { throw CancellationError() }
            catch { net = nil }
        }
        guard stamp(location.indexFile) == indexStamp,
              paths.allSatisfy({ stamp(location.root.appendingPathComponent($0)) == stamps[$0]! }),
              try await status(location) == expected else { throw GitBrowseError.changedDuringRead }
        return .init(files: files, total: net)
    }

    /// Compare HEAD blobs to the actual files using a disposable index. Adding
    /// new paths with intent-to-add lets native rename detection work before
    /// staging as well as afterward. No real index, objects or hooks are written.
    private static func netStatistics(_ location: GitRepositoryLocation, _ expected: GitWorkspaceStatus) async throws -> GitLineStatistics {
        let paths = changePaths(expected)
        guard !paths.isEmpty else { return .init() }
        let git = Git(location.root.path)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("omp-git-statistics-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let objects = temporary.appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let index = temporary.appendingPathComponent("index")
        let realObjects = try await line(git, ["rev-parse", "--path-format=absolute", "--git-path", "objects"])
        // Git's alternates path list accepts C-quoted entries, including colon,
        // Unicode, tabs and newlines in a worktree's actual path.
        let quoted = "\"" + realObjects.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\t", with: "\\t") + "\""
        let inherited = LoginEnvironment.current["GIT_ALTERNATE_OBJECT_DIRECTORIES"].flatMap { $0.isEmpty ? nil : $0 }
        let environment = ["GIT_INDEX_FILE": index.path, "GIT_OBJECT_DIRECTORY": objects.path,
                           "GIT_ALTERNATE_OBJECT_DIRECTORIES": quoted + (inherited.map { ":" + $0 } ?? "")]
        let prefix = ["-c", "core.hooksPath=/dev/null", "-c", "core.splitIndex=false", "-c", "core.sparseCheckout=false",
                      "-c", "index.sparse=false", "-c", "core.untrackedCache=false", "--literal-pathspecs"]
        _ = try await run(git, prefix + ["read-tree", "--empty"], environment: environment)
        let treePaths = paths.union(attributePaths(paths))
        var entries: [String: GitWorkspaceParser.TreeEntry] = [:]
        if let head = expected.head {
            var batch: [String] = [], bytes = 0
            func readBatch(_ batch: [String]) async throws {
                let result = try await run(git, ["--literal-pathspecs", "ls-tree", "-r", "-z", head, "--"] + batch)
                for entry in try GitWorkspaceParser.treeEntries(result.stdout) where treePaths.contains(entry.path) {
                    entries[entry.path] = entry
                }
            }
            for path in treePaths.sorted() {
                let size = path.utf8.count + 1
                if bytes + size > 32_768, !batch.isEmpty { try await readBatch(batch); batch = []; bytes = 0 }
                batch.append(path); bytes += size
            }
            if !batch.isEmpty { try await readBatch(batch) }
        }
        if !entries.isEmpty {
            let input = entries.values.sorted { $0.path < $1.path }.map { $0.mode + " " + $0.object + "\t" + $0.path + "\0" }.joined()
            _ = try await run(git, prefix + ["update-index", "-z", "--index-info"], input: Data(input.utf8), environment: environment)
            // Preserve HEAD's attribute fallback without counting sparse/missing
            // attribute files outside the actual changed-path set as deletions.
            let attributesOnly = Set(entries.keys).subtracting(paths)
            if !attributesOnly.isEmpty {
                _ = try await run(git, prefix + ["update-index", "--skip-worktree", "-z", "--stdin"],
                                  input: Data((attributesOnly.sorted().joined(separator: "\0") + "\0").utf8), environment: environment)
            }
        }
        let added = paths.filter { entries[$0] == nil && stamp(location.root.appendingPathComponent($0)) != nil }
        if !added.isEmpty {
            _ = try await run(git, prefix + ["add", "--intent-to-add", "--force", "--pathspec-from-file=-", "--pathspec-file-nul"],
                              input: Data((added.sorted().joined(separator: "\0") + "\0").utf8), environment: environment)
        }
        guard let metadata = stamp(index), metadata.byteCount <= GitWorkspaceIndex.maximumBytes else { throw GitBrowseError.tooLarge }
        let result = try await run(git, prefix + ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames=50%",
                                               "--submodule=short", "--numstat", "-z", "--"], environment: environment)
        return try GitWorkspaceParser.numstat(result.stdout).reduce(GitLineStatistics()) { try $0.adding($1.statistics) }
    }
}
