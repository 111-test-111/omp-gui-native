import Foundation

struct PreviewFileDiffLocation: Hashable, Sendable {
    let root: URL
    let path: String
}

struct PreviewFileDiffWatch: Sendable {
    let url: URL
    let revision: String?
}

enum PreviewFileDiffError: Error, LocalizedError {
    case tooLarge

    var errorDescription: String? {
        Bundle.main.localizedString(forKey: "This file's diff exceeds the 4 MiB preview limit.",
                                    value: nil, table: "Localizable")
    }
}

enum PreviewFileDiffResult: Sendable {
    case unchanged
    case ignored
    case changed(DiffFile)
}

/// Read-only, literal single-file comparisons. No index, checkpoint or tree is
/// written, and external diff/textconv drivers are never executed.
enum PreviewFileDiff {
    static let maximumPatchBytes = 4 * 1_024 * 1_024

    static func locate(_ url: URL, workingDirectory: String) async throws -> PreviewFileDiffLocation? {
        let project = Git(workingDirectory)
        guard await project.isRepository() else { return nil }
        try Task.checkCancellation()
        let projectRoot = try await project.repositoryRoot().resolvingSymlinksInPath()
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(projectRoot.path + "/") else { return nil }
        // A nested repository/submodule has its own HEAD. Linked worktrees use
        // their own index and HEAD through Git's normal repository discovery.
        let git = Git(file.deletingLastPathComponent().path)
        let root = try await git.repositoryRoot().resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return PreviewFileDiffLocation(root: root, path: String(file.path.dropFirst(root.path.count + 1)))
    }

    static func load(_ location: PreviewFileDiffLocation) async throws -> PreviewFileDiffResult {
        let git = Git(location.root.path)
        let head = try await git.run(["rev-parse", "--verify", "--quiet", "HEAD"], timeout: 15, outputLimit: 4_096)
        try Task.checkCancellation()
        if !head.succeeded, head.status != 1 { try Git.check(head) }
        if head.succeeded {
            let patch = try await patch(git, ["HEAD", "--", location.path])
            if !patch.isEmpty {
                return .changed(try await parse(patch, path: location.path))
            }
            let tracked = try await git.run(["--literal-pathspecs", "ls-files", "--error-unmatch", "--", location.path],
                                            timeout: 15, outputLimit: 4_096)
            try Task.checkCancellation()
            if tracked.succeeded { return .unchanged }
            guard tracked.status == 1 else { try Git.check(tracked); return .unchanged }
        }
        // check-ignore accepts filenames rather than literal pathspec magic.
        // Prefix ./ to protect a leading :( and use NUL input for all names.
        let ignored = try await git.run(["check-ignore", "--quiet", "--stdin", "-z"],
                                        input: Data(("./" + location.path + "\0").utf8), timeout: 15, outputLimit: 4_096)
        try Task.checkCancellation()
        if ignored.succeeded { return .ignored }
        guard ignored.status == 1 else { try Git.check(ignored); return .unchanged }
        let patch = try await patch(git, ["--no-index", "--", "/dev/null", location.root.appendingPathComponent(location.path).path],
                                    allowsDifferences: true)
        var file = try await parse(patch, path: location.path)
        file.change = .added
        return .changed(file)
    }

    /// HEAD itself, its symbolic branch, the index and packed refs can change
    /// without a file write. Observe only these few files while Diff is visible.
    static func metadataWatches(_ location: PreviewFileDiffLocation) async throws -> [PreviewFileDiffWatch] {
        let git = Git(location.root.path)
        func watch(_ path: String) async throws -> PreviewFileDiffWatch {
            let result = try await git.run(["rev-parse", "--path-format=absolute", "--git-path", path],
                                           timeout: 15, outputLimit: 16_384)
            try Git.check(result)
            let url = URL(fileURLWithPath: withoutTerminator(result.output))
            return PreviewFileDiffWatch(url: url, revision: PreviewFileMetadata.read(url)?.revision)
        }
        // Take HEAD's stamp before resolving its symbolic branch. If checkout
        // changes that branch during discovery, installing the watch refreshes
        // again even when the new HEAD predates the watch's initial baseline.
        var watches = [try await watch("HEAD")]
        let symbolic = try await git.run(["symbolic-ref", "--quiet", "HEAD"], timeout: 15, outputLimit: 4_096)
        var paths = ["index", "packed-refs"]
        if symbolic.succeeded { paths.append(withoutTerminator(symbolic.output)) }
        for path in paths {
            try Task.checkCancellation()
            watches.append(try await watch(path))
        }
        return watches
    }

    private static func withoutTerminator(_ output: String) -> String {
        output.hasSuffix("\n") ? String(output.dropLast()) : output
    }

    private static func patch(_ git: Git, _ arguments: [String], allowsDifferences: Bool = false) async throws -> String {
        let result = try await git.run(["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                                        "--no-renames", "--src-prefix=a/", "--dst-prefix=b/"] + arguments,
                                       timeout: 15, outputLimit: maximumPatchBytes + 1)
        try Task.checkCancellation()
        if !allowsDifferences || result.status != 1 { try Git.check(result) }
        // Shell retains a bounded tail. Never parse it as a complete patch.
        guard result.stdout.count <= maximumPatchBytes else { throw PreviewFileDiffError.tooLarge }
        return result.output
    }

    private static func parse(_ patch: String, path: String) async throws -> DiffFile {
        let task = Task.detached(priority: .userInitiated) { DiffParser.parseHunks(patch, path: path) }
        return try await withTaskCancellationHandler {
            let file = await task.value
            try Task.checkCancellation()
            return file
        } onCancel: { task.cancel() }
    }
}
