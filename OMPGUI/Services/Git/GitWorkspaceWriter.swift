import Darwin
import Foundation

struct GitWritePermission: Sendable {
    let check: @MainActor @Sendable () -> Bool
    static let allowed = GitWritePermission(check: { true })
}

struct GitWorkspaceWriting: Sendable {
    var stage: @Sendable (GitRepositoryLocation, GitWorkspaceRevision, [GitBrowseFile], Bool, GitWritePermission) async throws -> Void
    var patch: @Sendable (GitRepositoryLocation, GitWorkspaceRevision) async throws -> String
    var commit: @Sendable (GitRepositoryLocation, GitWorkspaceRevision, String, GitWritePermission) async throws -> GitCommitReceipt

    static let live = GitWorkspaceWriting(stage: GitWorkspaceWriter.stage, patch: GitWorkspaceWriter.patch,
                                          commit: GitWorkspaceWriter.commit)
}

private actor GitWorktreeWrites {
    static let shared = GitWorktreeWrites()
    private var active: Set<String> = []

    func perform<T: Sendable>(_ location: GitRepositoryLocation, operation: @Sendable () async throws -> T) async throws -> T {
        let key = location.gitDirectory.path
        guard active.insert(key).inserted else { throw GitWriteError.busy }
        defer { active.remove(key) }
        return try await operation()
    }
}

/// Native Git operates on a private, complete copy of the reviewed index while
/// the real index.lock excludes other Git writers. Publication replaces only
/// the index; no reset/checkout/discard ever writes working files. A submitted
/// commit is inspected even when Git exits unsuccessfully or times out.
enum GitWorkspaceWriter {
    private final class IndexTransaction: Sendable {
        let location: GitRepositoryLocation
        let candidate: URL
        let lock: URL
        let fd: Int32
        let inode: ino_t

        init(_ location: GitRepositoryLocation) throws {
            self.location = location
            candidate = location.indexFile.deletingLastPathComponent().appendingPathComponent("index.omp-gui-" + UUID().uuidString)
            lock = URL(fileURLWithPath: location.indexFile.path + ".lock")
            fd = lock.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            guard fd >= 0 else { throw GitWriteError.busy }
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                Darwin.close(fd); unlink(lock.path); throw GitWriteError.unsupportedIndex
            }
            inode = info.st_ino
        }

        deinit {
            Darwin.close(fd)
            var info = stat()
            if lstat(lock.path, &info) == 0, info.st_ino == inode { unlink(lock.path) }
            unlink(candidate.path)
            unlink(candidate.path + ".lock")
        }

        func copyIndex() throws {
            if let data = try GitWorkspaceIndex.read(location.indexFile) {
                guard FileManager.default.createFile(atPath: candidate.path, contents: data,
                                                     attributes: [.posixPermissions: 0o600]) else { throw GitWriteError.unsupportedIndex }
            }
        }

        func publish() throws {
            guard let data = try GitWorkspaceIndex.read(candidate, missing: false) else { throw GitWriteError.unsupportedIndex }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            var original = stat()
            if lstat(location.indexFile.path, &original) == 0 {
                guard original.st_mode & S_IFMT == S_IFREG else { throw GitWriteError.unsupportedIndex }
                guard fchmod(fd, original.st_mode & 0o777) == 0 else { throw GitWriteError.unsupportedIndex }
            }
            var locked = stat()
            guard fsync(fd) == 0, lstat(lock.path, &locked) == 0, locked.st_ino == inode,
                  rename(lock.path, location.indexFile.path) == 0 else { throw GitWriteError.unsupportedIndex }
        }
    }

    private static func run(_ location: GitRepositoryLocation, _ arguments: [String], index: URL? = nil,
                            input: Data? = nil, environment: [String: String] = [:], timeout: TimeInterval = 30,
                            limit: Int = GitWorkspaceReader.maximumResultBytes) async throws -> ShellResult {
        var extra = ["LC_ALL": "C", "GIT_PAGER": "cat", "GIT_EDITOR": "true", "GIT_NO_LAZY_FETCH": "1"]
        if let index { extra["GIT_INDEX_FILE"] = index.path }
        extra.merge(environment) { _, value in value }
        let result = try await Git(location.root.path).run(["--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false",
                                                          "-c", "core.splitIndex=false"] + arguments,
            environment: extra, input: input, timeout: timeout, lane: .read, outputLimit: limit + 1)
        guard result.stdout.count <= limit else { throw GitBrowseError.tooLarge }
        try Git.check(result)
        return result
    }

    private static func preflight(_ location: GitRepositoryLocation, _ expected: GitWorkspaceRevision) async throws -> GitWorkspaceStatus {
        guard try await GitWorkspaceReader.locate(location.root.path) == location else { throw GitBrowseError.missingRepository }
        let status = try await GitWorkspaceReader.status(location)
        guard status.revision == expected else { throw GitWriteError.changed }
        guard status.operations.isEmpty, !status.files.contains(where: { $0.side == .conflict }) else { throw GitWriteError.operation }
        return status
    }

    @concurrent static func stage(_ location: GitRepositoryLocation, _ expected: GitWorkspaceRevision,
                                 _ files: [GitBrowseFile], _ unstaging: Bool,
                                 allowed: GitWritePermission = .allowed) async throws {
        try await GitWorktreeWrites.shared.perform(location) {
            let transaction = try IndexTransaction(location)
            let status = try await preflight(location, expected)
            guard await allowed.check() else { throw GitWriteError.activeTask }
            guard !files.isEmpty, files.allSatisfy({ file in
                status.files.contains(file) && (unstaging ? file.side == .index : file.side == .working || file.side == .untracked)
            }) else { throw GitWriteError.changed }
            let paths = try Set(files.flatMap { file -> [String] in
                let path = try GitWorkspaceParser.path(file.path)
                if let old = file.oldPath, file.status == "R" { return [try GitWorkspaceParser.path(old), path] }
                return [path]
            }).sorted()
            let input = Data((paths.joined(separator: "\0") + "\0").utf8)
            guard input.count <= GitWorkspaceReader.maximumResultBytes else { throw GitBrowseError.tooLarge }
            try transaction.copyIndex()
            let arguments: [String]
            if !unstaging { arguments = ["add", "--all", "--pathspec-from-file=-", "--pathspec-file-nul"] }
            else if let head = expected.head {
                arguments = ["restore", "--staged", "--source=" + head, "--pathspec-from-file=-", "--pathspec-file-nul"]
            } else {
                arguments = ["rm", "--cached", "--force", "--ignore-unmatch", "--pathspec-from-file=-", "--pathspec-file-nul"]
            }
            _ = try await run(location, arguments, index: transaction.candidate, input: input)
            _ = try await preflight(location, expected)
            guard await allowed.check() else { throw GitWriteError.activeTask }
            try Task.checkCancellation()
            try transaction.publish()
        }
    }

    @concurrent static func patch(_ location: GitRepositoryLocation, _ expected: GitWorkspaceRevision) async throws -> String {
        try await GitWorktreeWrites.shared.perform(location) {
            let transaction = try IndexTransaction(location)
            _ = try await preflight(location, expected)
            try transaction.copyIndex()
            let result = try await run(location, ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--submodule=short"]
                                        + [expected.head].compactMap { $0 } + ["--"],
                                       index: transaction.candidate, limit: GitWorkspaceReader.maximumPatchBytes)
            _ = try await preflight(location, expected)
            return try GitWorkspaceParser.text(result.stdout)
        }
    }

    @concurrent static func commit(_ location: GitRepositoryLocation, _ expected: GitWorkspaceRevision,
                                  _ message: String, allowed: GitWritePermission = .allowed) async throws -> GitCommitReceipt {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !message.utf8.contains(0), message.utf8.count <= 65_536 else { throw GitWriteError.invalidMessage }
        return try await GitWorktreeWrites.shared.perform(location) {
            let transaction = try IndexTransaction(location)
            let status = try await preflight(location, expected)
            guard status.files.contains(where: { $0.side == .index }) else { throw GitWriteError.nothingStaged }
            try transaction.copyIndex()
            let tree = try await run(location, ["write-tree"], index: transaction.candidate).trimmedOutput
            guard GitBrowseError.isObjectID(tree) else { throw GitBrowseError.malformed }
            if let head = expected.head {
                let base = try await run(location, ["rev-parse", "--verify", head + "^{tree}"]).trimmedOutput
                guard tree != base else { throw GitWriteError.nothingStaged }
            }
            _ = try await preflight(location, expected)
            guard await allowed.check() else { throw GitWriteError.activeTask }
            try Task.checkCancellation()
            let action = "omp-gui-commit-" + UUID().uuidString
            var failure: (any Error)?
            do {
                _ = try await run(location, ["commit", "--file=-", "--cleanup=verbatim", "--no-status"],
                                  index: transaction.candidate, input: Data(message.utf8),
                                  environment: ["GIT_REFLOG_ACTION": action], timeout: 120, limit: 65_536)
            } catch { failure = error }

            // Do not infer rollback from an exit status: a post-commit hook or
            // process timeout can occur after the reference was advanced.
            let after: GitWorkspaceStatus
            do { after = try await GitWorkspaceReader.status(location) }
            catch { throw GitWriteError.uncertain }
            guard let id = after.head, id != expected.head else {
                if let failure { throw failure }
                throw GitWriteError.uncertain
            }
            guard after.revision?.reference == expected.reference else { throw GitWriteError.uncertain }
            let record: String
            do { record = try await run(location, ["show", "--no-patch", "--no-show-signature", "--format=%T%x00%P", id, "--"]).trimmedOutput }
            catch { throw GitWriteError.uncertain }
            let fields = record.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2, fields[1] == (expected.head ?? "") else { throw GitWriteError.uncertain }
            if failure != nil {
                let log = try? await run(location, ["reflog", "-1", "--format=%gs", "HEAD"]).trimmedOutput
                guard log?.hasPrefix(action + ":") == true else { throw GitWriteError.uncertain }
            }
            // Preserve native hook index changes just as `git commit` does.
            // A hook-expanded commit is explicitly reported for inspection,
            // never mistaken for the exact reviewed commit or auto-retried.
            do {
                guard try GitWorkspaceIndex.read(location.indexFile).map(GitWorkspaceIndex.digest) == expected.index else {
                    throw GitWriteError.changed
                }
                try transaction.publish()
            } catch { throw GitWriteError.committed(id) }
            guard fields[0] == tree else { throw GitWriteError.committed(id) }
            return .init(id: id)
        }
    }
}
