import Foundation
@testable import OMPGUI

private actor ReadGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@main
private enum FileDiffChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    private static func run(_ git: Git, _ arguments: [String]) async throws {
        let result = try await git.run(arguments)
        precondition(result.succeeded, "Git fixture failed: \(arguments): \(result.failureMessage)")
    }

    private static func write(_ text: String, _ url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func changed(_ location: PreviewFileDiffLocation) async throws -> DiffFile {
        guard case .changed(let file) = try await PreviewFileDiff.load(location) else {
            fatalError("Expected changes for \(location.path)")
        }
        return file
    }

    @MainActor private static func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline, "Preview diff did not settle")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func main() async throws {
        guard let output = CaptureRun.outputDirectory else { fatalError("Require isolated capture output") }
        // Capture reports live beneath the task repository. Put Git fixtures
        // outside it so the non-Git case cannot discover that parent checkout.
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("omp-preview-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let root = fixtures.appendingPathComponent("repo", isDirectory: true)
        let plain = fixtures.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let git = Git(root.path)
        try await run(git, ["init", "--quiet", "--initial-branch=main"])
        try await run(git, ["config", "user.name", "Preview fixture"])
        try await run(git, ["config", "user.email", "preview@localhost"])
        let source = root.appendingPathComponent("source.swift")
        let markdown = root.appendingPathComponent(":(glob)* [文档]\nnotes.md")
        let sibling = root.appendingPathComponent("other.md")
        let large = root.appendingPathComponent("large.txt")
        let baseline = "before\nunchanged\n"
        try write(baseline, source)
        try write("# Before\n", markdown)
        try write("other file\n", sibling)
        try write("ignored.txt\n", root.appendingPathComponent(".gitignore"))
        try write(String(repeating: "a", count: PreviewFileDiff.maximumPatchBytes / 2 - 1) + "\n", large)
        try await run(git, ["add", "--all"])
        try await run(git, ["commit", "--quiet", "-m", "Baseline"])

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        guard let location = try await PreviewFileDiff.locate(source, workingDirectory: nested.path),
              let mdLocation = try await PreviewFileDiff.locate(markdown, workingDirectory: root.path) else {
            fatalError("Git source and Markdown previews were not recognized")
        }
        expect(location.root == root.resolvingSymlinksInPath() && location.path == "source.swift", "Nested execution directory lost the root-relative path")
        expect(try await PreviewFileDiff.locate(source, workingDirectory: plain.path) == nil, "A non-Git project offered Diff")
        let outside = plain.appendingPathComponent("outside.md")
        try write("outside\n", outside)
        expect(try await PreviewFileDiff.locate(outside, workingDirectory: root.path) == nil, "An outside file used the project's HEAD")
        if case .unchanged = try await PreviewFileDiff.load(location) {} else { fatalError("Clean file has a diff") }

        try write("staged\nunchanged\n", source)
        try await run(git, ["add", "source.swift"])
        try write("staged\nworking\nunchanged\n", source)
        try write("# After\n", markdown)
        try write("unrelated changes\n", sibling)
        // These fail immediately if the preview accidentally invokes a driver.
        try write("*.swift diff=preview\n", root.appendingPathComponent(".gitattributes"))
        try await run(git, ["config", "diff.external", "/usr/bin/false"])
        try await run(git, ["config", "diff.preview.textconv", "/usr/bin/false"])
        let index = root.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: index)
        let file = try await changed(location)
        let rows = file.hunks.flatMap(\.lines)
        expect(file.path == "source.swift" && file.additions == 2 && file.deletions == 1, "Diff did not combine staged and working changes against HEAD")
        expect(rows.contains { $0.kind == .deletion && $0.text == "before" } && !rows.contains { $0.text == "unrelated changes" }, "Single-file comparison leaked another file or used the index as its base")
        let md = try await changed(mdLocation)
        expect(md.path == markdown.lastPathComponent && md.additions == 1 && md.deletions == 1, "Literal Markdown path expanded a pathspec or lost Unicode/newlines")
        expect(try Data(contentsOf: index) == indexBefore, "Diff preview modified the real index")

        let newPath = ":(glob)* [new]\nfile.md"
        let newURL = root.appendingPathComponent(newPath)
        try write("# New\n\n正文\n", newURL)
        let newLocation = PreviewFileDiffLocation(root: root, path: newPath)
        let newFile = try await changed(newLocation)
        expect(newFile.change == .added && newFile.additions == 3 && newFile.deletions == 0, "Untracked Markdown was not shown as an addition")
        try write("private\n", root.appendingPathComponent("ignored.txt"))
        if case .ignored = try await PreviewFileDiff.load(.init(root: root, path: "ignored.txt")) {} else { fatalError("Ignored source was presented as a new file") }

        try FileManager.default.removeItem(at: sibling)
        let deleted = try await changed(.init(root: root, path: "other.md"))
        expect(deleted.change == .deleted && deleted.deletions == 1, "Single-file deletion was lost")
        try write("\u{0}binary\n", source)
        let binary = try await changed(location)
        expect(binary.isBinary, "A binary working copy was parsed as text")
        try write("staged\nworking\nunchanged\n", source)

        let unborn = fixtures.appendingPathComponent("unborn", isDirectory: true)
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        let unbornGit = Git(unborn.path)
        try await run(unbornGit, ["init", "--quiet"])
        try write("first\n", unborn.appendingPathComponent("first.md"))
        try await run(unbornGit, ["add", "first.md"])
        let first = try await changed(.init(root: unborn, path: "first.md"))
        expect(first.change == .added && first.additions == 1, "A repository without HEAD could not preview a staged first file")

        let worktree = fixtures.appendingPathComponent("linked", isDirectory: true)
        try await run(git, ["worktree", "add", "--quiet", "-b", "linked", worktree.path])
        let linkedSource = worktree.appendingPathComponent("source.swift")
        try write("worktree only\n", linkedSource)
        guard let linkedLocation = try await PreviewFileDiff.locate(linkedSource, workingDirectory: worktree.path) else { fatalError("Linked worktree not found") }
        let linked = try await changed(linkedLocation)
        expect(linked.hunks.flatMap(\.lines).contains { $0.text == "worktree only" } && linked.additions == 1, "Linked worktree diff used another checkout's working contents")
        expect(try await PreviewFileDiff.locate(linkedSource, workingDirectory: root.path) == nil, "A file from another checkout borrowed this project's root")

        try write(String(repeating: "b", count: PreviewFileDiff.maximumPatchBytes / 2 - 1) + "\n", large)
        do {
            _ = try await PreviewFileDiff.load(.init(root: root, path: "large.txt"))
            fatalError("A truncated patch was shown as complete")
        } catch PreviewFileDiffError.tooLarge { checks += 1 }

        let context = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        let request = FilePreviewDiffRequest(url: source, context: context, revision: "first", showsDiff: true)
        let state = FilePreviewDiffState()
        await state.update(request)
        expect(state.location == location && state.result != nil && state.error == nil && !state.isLoading, "Visible Diff did not publish its result")
        let beforeCommit = state.refreshRevision
        try await run(git, ["add", "source.swift"])
        try await run(git, ["commit", "--quiet", "-m", "Source change"])
        try await eventually { state.refreshRevision > beforeCommit }
        await state.update(.init(url: source, context: context, revision: "after-commit", showsDiff: true))
        if case .unchanged? = state.result {} else { fatalError("Commit without a file write left a stale diff") }
        state.suspend()
        expect(state.request == nil && state.location == nil && state.result == nil && !state.isLoading, "Hidden preview retained a reader result")
        let hiddenRevision = state.refreshRevision
        try await run(git, ["update-ref", "refs/heads/main", "HEAD^"])
        try await Task.sleep(for: .milliseconds(250))
        expect(state.refreshRevision == hiddenRevision, "Hidden preview kept observing Git metadata")

        let gate = ReadGate()
        let racing = FilePreviewDiffState(loader: { location in
            if location.path == "source.swift" { await gate.hold(); return .ignored }
            return .unchanged
        })
        let old = Task { await racing.update(request) }
        try await eventually { await gate.entered }
        let newer = FilePreviewDiffRequest(url: newURL, context: context, revision: "newer", showsDiff: true)
        await racing.update(newer)
        await gate.release()
        await old.value
        expect(racing.request == newer && racing.location?.path == newPath && racing.result != nil, "A late file read replaced the newer tab")
        if case .unchanged? = racing.result {} else { fatalError("A late result replaced the newer diff") }
        racing.suspend()

        let reader = PreviewReaderState()
        reader.showsSource = true
        reader.source = .init(x: 11, y: 240, selectionLocation: 3, selectionLength: 5)
        reader.document = .init(x: 0, y: 120)
        let sourcePosition = reader.source
        let documentPosition = reader.document
        reader.showsDiff = true
        let saved = try JSONEncoder().encode(reader.snapshot)
        let restored = PreviewReaderState(snapshot: try JSONDecoder().decode(PreviewReaderState.Snapshot.self, from: saved))
        expect(restored.showsDiff && restored.source == sourcePosition && restored.document == documentPosition, "Diff mode overwrote source/Markdown reading positions")
        var oldJournal = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        oldJournal.removeValue(forKey: "showsDiff")
        let migrated = try JSONDecoder().decode(PreviewReaderState.Snapshot.self, from: JSONSerialization.data(withJSONObject: oldJournal))
        expect(!PreviewReaderState(snapshot: migrated).showsDiff, "Pre-Diff journals no longer decode")
        try JSONSerialization.data(withJSONObject: ["checks": checks, "passed": true], options: [.prettyPrinted])
            .write(to: output.appendingPathComponent("file-diff.json"))
        print("File diff checks passed: \(checks)")
    }
}
