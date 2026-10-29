import AppKit
import SwiftUI
@testable import OMPGUI

private actor BrowserReadGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor BrowserPageRetry {
    private var calls = 0
    let first = GitBrowseCommit(id: String(repeating: "a", count: 40), parents: [String(repeating: "b", count: 40)],
                               author: "Fixture", date: .distantPast, subject: "First page")
    let second = GitBrowseCommit(id: String(repeating: "b", count: 40), parents: [],
                                author: "Fixture", date: .distantPast, subject: "Second page")
    func read(offset: Int) throws -> GitHistoryPage {
        calls += 1
        if calls == 1 { precondition(offset == 0); return .init(commits: [first], hasMore: true) }
        precondition(offset == 1, "Retry must retain the accepted page instead of restarting or skipping it")
        if calls == 2 { throw GitBrowseError.changedDuringRead }
        return .init(commits: [second], hasMore: false)
    }
}

private actor BrowserStatisticsScenario {
    private var additions = 1
    private var gate: BrowserReadGate?
    private(set) var revision = 0

    func pause(_ next: Int) -> BrowserReadGate {
        additions = next; revision += 1
        let gate = BrowserReadGate(); self.gate = gate; return gate
    }
    func replace(_ next: Int) { additions = next; revision += 1 }
    func read(_ status: GitWorkspaceStatus) async throws -> GitWorkspaceStatistics {
        let value = additions
        let gate = gate; self.gate = nil
        if let gate { await gate.hold() }
        return .init(files: Dictionary(uniqueKeysWithValues: status.files.map { ($0.id, .init(additions: value)) }),
                     total: .init(additions: value * status.files.count))
    }
}

private actor BrowserStatisticsCounter {
    private(set) var rows = 0
    private(set) var totals = 0
    func read(_ total: GitStatisticsTotal) { rows += 1; if case .read = total { totals += 1 } }
}

private actor BrowserRefreshScenario {
    private var statusGate: BrowserReadGate?
    private var diffGate: BrowserReadGate?
    private var detailsGate: BrowserReadGate?
    private var historyGate: BrowserReadGate?
    private var sourceOverride: GitHistorySource?
    private var nextDiff: DiffFile
    private var commitIsMissing = false
    private let files: [GitBrowseFile]

    init(diff: DiffFile, files: [GitBrowseFile] = []) { nextDiff = diff; self.files = files }
    func pauseStatus() -> BrowserReadGate {
        let gate = BrowserReadGate(); statusGate = gate; return gate
    }
    func pauseDiff() -> BrowserReadGate {
        let gate = BrowserReadGate(); diffGate = gate; return gate
    }
    func pauseDetails() -> BrowserReadGate {
        let gate = BrowserReadGate(); detailsGate = gate; return gate
    }
    func pauseHistory() -> BrowserReadGate {
        let gate = BrowserReadGate(); historyGate = gate; return gate
    }
    func waitForHistory() async {
        let gate = historyGate; historyGate = nil
        if let gate { await gate.hold() }
    }
    func source(_ fallback: GitHistorySource) -> GitHistorySource { sourceOverride ?? fallback }
    func replaceSource(_ next: GitHistorySource) { sourceOverride = next }
    func replaceDiff(_ diff: DiffFile) { nextDiff = diff }
    func setCommitMissing(_ missing: Bool) { commitIsMissing = missing }
    func details(_ commit: GitBrowseCommit, parent: String? = nil) async throws -> GitCommitDetails {
        let gate = detailsGate; detailsGate = nil
        if let gate { await gate.hold() }
        if commitIsMissing { throw GitBrowseError.missingRepository }
        return .init(commit: commit, message: commit.subject, parent: parent ?? commit.parents.first, files: files)
    }
    func status(_ value: GitWorkspaceStatus) async -> GitWorkspaceStatus {
        let gate = statusGate; statusGate = nil
        if let gate { await gate.hold() }
        return value
    }
    func diff() async -> DiffFile {
        let gate = diffGate; diffGate = nil
        let value = nextDiff
        if let gate { await gate.hold() }
        return value
    }
}

@main
private enum GitBrowserChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func snapshot(_ host: NSView, to output: URL) throws {
        host.layoutSubtreeIfNeeded()
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            view.layer?.setNeedsDisplay()
            view.subviews.forEach(invalidate)
        }
        invalidate(host)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No offscreen bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let pixels = bitmap.bitmapData else { fatalError("No bitmap pixels") }
        precondition(UnsafeBufferPointer(start: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh).contains { $0 != 0 },
                     "An offscreen snapshot must paint content rather than an empty bitmap")
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: output)
    }

    private static func command(_ git: Git, _ arguments: [String], input: String? = nil,
                                environment: [String: String] = [:]) async throws -> String {
        let result = try await git.run(arguments, environment: environment, input: input.map { Data($0.utf8) }, timeout: 15)
        try Git.check(result)
        return result.trimmedOutput
    }

    private static func write(_ text: String, _ root: URL, _ path: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private static func repository(_ root: URL) async throws -> Git {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = Git(root.path)
        _ = try await command(git, ["init", "--quiet", "--initial-branch=main"])
        for (key, value) in [("user.name", "Git browser fixture"), ("user.email", "browser@localhost"),
                             ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
                             ("core.autocrlf", "false"), ("core.attributesfile", "/dev/null")] {
            _ = try await command(git, ["config", key, value])
        }
        return git
    }

    @MainActor private static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private static func graphChecks() throws {
        func commit(_ id: Int, _ parents: [Int]) -> GitBrowseCommit {
            .init(id: String(format: "%040x", id + 1), parents: parents.map { String(format: "%040x", $0 + 1) },
                  author: "Fixture", date: .distantPast, subject: "Commit \(id)")
        }
        // Check the drawn topology independently: follow every outgoing stem
        // through pass-through rows until it ends at a node or a pending parent.
        func verify(_ commits: [GitBrowseCommit]) throws -> GitCommitGraph {
            let graph = try GitCommitGraph.build(commits)
            expect(graph.rows.count == commits.count, "Every commit needs one graph row")
            for (index, commit) in commits.enumerated() {
                let row = graph.rows[index]
                expect(row.isMerge == (commit.parents.count > 1), "Merge rings must describe actual parent counts")
                var actual: [String] = []
                for outgoing in row.segments where outgoing.fromY == 0.5 && outgoing.toY == 1 {
                    var lane = outgoing.toLane
                    var reached: String?
                    if index + 1 < graph.rows.count {
                        for next in graph.rows[(index + 1)...] {
                            guard let segment = next.segments.first(where: { $0.fromY == 0 && $0.fromLane == lane }) else {
                                fatalError("A graph edge silently disappeared between rows")
                            }
                            if segment.toY == 0.5 { reached = next.commitID; break }
                            lane = segment.toLane
                        }
                    }
                    if reached == nil, graph.pendingParents.indices.contains(lane) { reached = graph.pendingParents[lane] }
                    guard let reached else { fatalError("A graph edge lost its off-page parent") }
                    actual.append(reached)
                }
                expect(actual == commit.parents, "Drawn edges must reach exactly the declared parents, in parent order")
            }
            return graph
        }
        let merge = [commit(0, [1, 2]), commit(1, [3]), commit(2, [4]), commit(3, [5]), commit(4, [5]), commit(5, [])]
        let whole = try verify(merge)
        let prefix = try verify(Array(merge.prefix(3)))
        expect(Array(whole.rows.prefix(3)) == prefix.rows, "Pagination must not move existing lanes or curves")
        expect(prefix.pendingParents.compactMap { $0 }.count == 2, "Both unfinished branches need continuation stems")
        let octopus = [commit(0, Array(1...12))] + (1...12).map { commit($0, [13]) } + [commit(13, [])]
        expect(try verify(octopus).laneCount >= 12, "Complex topology must retain distinct lanes")
        do { _ = try GitCommitGraph.build([commit(0, Array(1...513))]); fatalError("Unbounded topology was accepted") }
        catch GitBrowseError.tooLarge { checks += 1 }
        var random: UInt64 = 79
        var generated: [GitBrowseCommit] = []
        for id in 0..<96 {
            var parents = Set<Int>()
            if id < 95 {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                for _ in 0..<Int(random % 4) {
                    random = random &* 6_364_136_223_846_793_005 &+ 1
                    parents.insert(id + 1 + Int(random % UInt64(95 - id)))
                }
            }
            generated.append(commit(id, parents.sorted()))
        }
        let generatedGraph = try verify(generated)
        expect(Array(generatedGraph.rows.prefix(31)) == (try verify(Array(generated.prefix(31)))).rows,
               "Appending disconnected and multi-parent history must preserve the rendered prefix")
        do { _ = try GitCommitGraph.build([commit(1, []), commit(0, [1])]); fatalError("Parent-before-child ordering was accepted") }
        catch GitBrowseError.malformed { checks += 1 }
        do { _ = try GitWorkspaceParser.history(Data("broken\0".utf8)); fatalError("Truncated history was accepted") }
        catch GitBrowseError.malformed { checks += 1 }
        do { _ = try GitWorkspaceParser.text(Data([0xff])); fatalError("Lossy filenames were accepted") }
        catch GitBrowseError.malformed { checks += 1 }
    }

    @MainActor private static func statisticsParserChecks() throws {
        let path = "literal\t路径\nname.txt"
        let entries = try GitWorkspaceParser.numstat(Data("2\t3\t\(path)\0-\t-\tbinary\01\t0\t\0old\npath\0new\tpath\0".utf8))
        expect(entries.count == 3 && entries[0].path == path && entries[0].statistics == .init(additions: 2, deletions: 3),
               "Numstat must preserve tabs, newlines and Unicode after its two numeric fields")
        expect(entries[1].statistics.isBinary && entries[2].oldPath == "old\npath" && entries[2].path == "new\tpath",
               "Binary sentinels and NUL-separated rename paths must stay distinct")
        expect(try GitWorkspaceParser.numstat(Data()).isEmpty, "An empty comparison has known zero text changes")
        for invalid in ["1\t2\tunterminated", "1\t2\t\0old\0", "-\t1\tfile\0", "-1\t0\tfile\0",
                        "+1\t0\tfile\0", "1\t\tfile\0", "1\t2\t\0\0new\0", "99999999999999999999\t0\tfile\0"] {
            do { _ = try GitWorkspaceParser.numstat(Data(invalid.utf8)); fatalError("Malformed numstat accepted: \(invalid)") }
            catch GitBrowseError.malformed { checks += 1 }
        }
        do { _ = try GitLineStatistics(additions: .max).adding(.init(additions: 1)); fatalError("Line total overflow accepted") }
        catch GitBrowseError.tooLarge { checks += 1 }
        let object = String(repeating: "a", count: 40)
        expect(try GitWorkspaceParser.treeEntries(Data("100644 blob \(object)\t\(path)\0".utf8)).first?.path == path,
               "Private comparison indexes must preserve literal HEAD paths")
        for invalid in ["100644 blob \(object)\tfile", "100644 tree \(object)\tfile\0", "100644 blob bad\tfile\0"] {
            do { _ = try GitWorkspaceParser.treeEntries(Data(invalid.utf8)); fatalError("Malformed tree entry accepted") }
            catch GitBrowseError.malformed { checks += 1 }
        }
    }

    @MainActor private static func historyTimeChecks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seconds in [0.0, 59.999] {
            expect(RelativeTime.short(now.addingTimeInterval(-seconds), now: now) == Chrome.localized("now"),
                   "History entries under one minute must say just now")
        }
        for (seconds, minutes) in [(60.0, 1), (119.999, 1), (120.0, 2), (3_599.999, 59)] {
            expect(RelativeTime.short(now.addingTimeInterval(-seconds), now: now)
                   == String(format: Chrome.localized("%lldm"), minutes),
                   "History minutes must discard seconds without rounding into the next minute")
        }
        expect(RelativeTime.short(now.addingTimeInterval(-3_600), now: now)
               == String(format: Chrome.localized("%lldh"), 1), "Older history must retain the shared hour format")
    }

    @MainActor static func main() async throws {
        guard let output = CaptureRun.outputDirectory else { fatalError("Require isolated capture storage") }
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("omp-git-browser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtures) }
        try graphChecks()
        try statisticsParserChecks()
        historyTimeChecks()
        let root = fixtures.appendingPathComponent("repo 中文\nsource", isDirectory: true)
        let git = try await repository(root)
        let literal = ":(glob)* [原始]\nname.txt"
        let renamed = ":(literal) [更名]\nname.txt"
        try write("base\nstable\n", root, "source.txt")
        try write((0..<12).map { "unchanged \($0)" }.joined(separator: "\n") + "\n", root, literal)
        try write("will be removed\n", root, "removed.txt")
        try write((1...160).map { "Inline diff line \($0)" }.joined(separator: "\n") + "\n", root, "inline-long.txt")
        _ = try await command(git, ["add", "--all"])
        _ = try await command(git, ["commit", "--quiet", "-m", "Initial fixture"])
        let initial = try await command(git, ["rev-parse", "HEAD"])
        _ = try await command(git, ["switch", "--quiet", "-c", "feature/graph"])
        try write("feature branch\n", root, "feature.txt")
        _ = try await command(git, ["add", "--all"])
        _ = try await command(git, ["commit", "--quiet", "-m", "Feature graph"])
        let feature = try await command(git, ["rev-parse", "HEAD"])
        _ = try await command(git, ["switch", "--quiet", "main"])
        try write("main branch\n", root, "main.txt")
        _ = try await command(git, ["add", "--all"])
        _ = try await command(git, ["commit", "--quiet", "-m", "Main branch"])
        let firstParent = try await command(git, ["rev-parse", "HEAD"])
        _ = try await command(git, ["merge", "--quiet", "--no-ff", "feature/graph", "-m", "Merge graph"])
        let merge = try await command(git, ["rev-parse", "HEAD"])
        _ = try await command(git, ["commit", "--allow-empty", "--quiet", "-m", "Clock skew child"], environment: [
            "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z"])
        let head = try await command(git, ["rev-parse", "HEAD"])
        _ = try await command(git, ["tag", "-a", "annotated", "-m", "Tag", merge])
        _ = try await command(git, ["tag", "-a", "nested", "-m", "Nested tag", "annotated"])
        let blob = try await command(git, ["hash-object", "-w", "--stdin"], input: "blob tag\n")
        _ = try await command(git, ["update-ref", "refs/tags/blob", blob])
        let tree = try await command(git, ["rev-parse", "HEAD^{tree}"])
        let checkpoint = try await command(git, ["commit-tree", tree, "-p", head], input: "Internal checkpoint\n")
        _ = try await command(git, ["update-ref", "refs/tivano/checkpoints/fixture", checkpoint])
        _ = try await command(git, ["update-ref", "refs/remotes/origin/main", merge])
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        guard let location = try await GitWorkspaceReader.locate(nested.path) else { fatalError("Repository not found") }
        expect(location.root == root.resolvingSymlinksInPath(), "Execution subfolders must resolve to the exact Unicode/newline repository root")
        let clean = try await GitWorkspaceReader.status(location)
        let source = try await GitWorkspaceReader.source(location, clean.head)
        let page = try await GitWorkspaceReader.history(location, source.tips, 0, 2)
        expect(page.commits.count == 2 && page.hasMore, "History needs bounded pages with an explicit continuation")
        let full = try await GitWorkspaceReader.history(location, source.tips, 0, 100)
        expect(full.commits.first?.id == head && full.commits.contains { $0.id == initial }, "Clock-skewed tips and root commits must be present")
        expect(!full.commits.contains { $0.id == checkpoint }, "Internal checkpoint references must never enter user history")
        expect(source.references.contains { $0.name == "refs/tags/nested" && $0.commit == merge }
               && !source.references.contains { $0.name == "refs/tags/blob" }, "Commit tags must peel recursively, while non-commit tags stay outside the revision walk")
        let graph = try GitCommitGraph.build(full.commits)
        expect(graph.rows.first { $0.commitID == merge }?.isMerge == true, "Real merge topology lost its ring")
        _ = try await command(git, ["commit", "--allow-empty", "--quiet", "-m", "New external head"])
        let later = try await GitWorkspaceReader.history(location, source.tips, 2, 100)
        expect(page.commits.map(\.id) + later.commits.map(\.id) == full.commits.map(\.id), "A moving branch must not duplicate or skip commits in pinned pagination")

        let firstDetails = try await GitWorkspaceReader.details(location, merge, nil)
        let otherDetails = try await GitWorkspaceReader.details(location, merge, feature)
        expect(firstDetails.parent == firstParent && firstDetails.files.map(\.path) == ["feature.txt"], "Merge defaults must compare the first parent explicitly")
        expect(otherDetails.parent == feature && otherDetails.files.map(\.path) == ["main.txt"], "Selecting another merge parent must change the file set")
        let initialDetails = try await GitWorkspaceReader.details(location, initial, nil)
        expect(initialDetails.parent == nil && initialDetails.files.contains { $0.path == literal }, "Initial commits need an empty-tree comparison with literal paths")
        let initialFile = initialDetails.files.first { $0.path == literal }!
        let initialDiff = try await GitWorkspaceReader.diff(location, .init(file: initialFile, commit: initial, parent: nil))
        expect(initialDiff.additions == 12 && initialDiff.path == literal, "Initial file diffs lost literal paths or content")
        expect(try await GitWorkspaceReader.statistics(location, .init(file: initialFile, commit: initial)) == .init(additions: 12),
               "Initial history statistics must use the empty tree and preserve literal paths")
        expect(try await GitWorkspaceReader.statistics(location, .init(file: otherDetails.files[0], commit: merge, parent: feature)) == .init(additions: 1),
               "History statistics must use the explicitly selected merge parent")

        try write("staged\nstable\n", root, "source.txt")
        _ = try await command(git, ["add", "source.txt"])
        try write("staged\nworking\nstable\n", root, "source.txt")
        _ = try await command(git, ["--literal-pathspecs", "mv", "--", literal, renamed])
        try write((0..<12).map { "unchanged \($0)" }.joined(separator: "\n") + "\nworking rename\n", root, renamed)
        let newName = ":(glob)* [新增]\n\tnote.txt"
        try write("new text\n", root, newName)
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.bin"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        _ = try await command(git, ["config", "diff.external", "/usr/bin/false"])
        _ = try await command(git, ["config", "diff.fixture.textconv", "/usr/bin/false"])
        try write("*.txt diff=fixture\n", root, ".gitattributes")
        let index = location.gitDirectory.appendingPathComponent("index")
        let indexBefore = try Data(contentsOf: index)
        let status = try await GitWorkspaceReader.status(location)
        let partial = status.files.filter { $0.path == "source.txt" }
        expect(partial.count == 2 && Set(partial.map(\.side)) == [.index, .working], "A partially staged file needs two independent comparisons")
        expect(status.files.first { $0.path == renamed && $0.side == .index }?.oldPath == literal, "Rename source paths must survive NUL records")
        for file in partial {
            let diff = try await GitWorkspaceReader.diff(location, .init(file: file))
            let texts = diff.hunks.flatMap(\.lines).map(\.text)
            if file.side == .index { expect(diff.additions == 1 && diff.deletions == 1 && !texts.contains("working"), "Staged diffs must use HEAD → index") }
            else { expect(diff.additions == 1 && diff.deletions == 0 && texts.contains("working"), "Working diffs must use index → working tree") }
        }
        let stagedRename = status.files.first { $0.path == renamed && $0.side == .index }!
        let renameDiff = try await GitWorkspaceReader.diff(location, .init(file: stagedRename))
        expect(renameDiff.change == .renamed && renameDiff.oldPath == literal && renameDiff.additions == 0, "Rename comparisons must preserve their original source blob")
        let newFile = status.files.first { $0.path == newName }!
        expect(try await GitWorkspaceReader.diff(location, .init(file: newFile)).additions == 1, "Untracked literal paths must not expand pathspecs")
        let binary = status.files.first { $0.path == "binary.bin" }!
        expect(try await GitWorkspaceReader.diff(location, .init(file: binary)).isBinary, "Binary differences must never be displayed as empty text")
        let deleted = status.files.first { $0.path == "removed.txt" }!
        expect(try await GitWorkspaceReader.diff(location, .init(file: deleted)).deletions == 1, "Deleted files still need a read-only diff")
        let statistics = try await GitWorkspaceReader.workspaceStatistics(location, status)
        expect(statistics.files[partial.first { $0.side == .index }!.id] == .init(additions: 1, deletions: 1)
               && statistics.files[partial.first { $0.side == .working }!.id] == .init(additions: 1),
               "Partially staged paths need separate native counts for HEAD → index and index → worktree")
        expect(statistics.files[stagedRename.id] == .init()
               && statistics.files["working:" + renamed] == .init(additions: 1), "Rename-only staging must not count the whole file as new text")
        expect(statistics.files[newFile.id] == .init(additions: 1) && statistics.files[binary.id]?.isBinary == true,
               "Untracked literal and binary paths must retain native numstat semantics")
        expect(statistics.total == .init(additions: 5, deletions: 2, isBinary: true)
               && statistics.files.count == status.files.count, "Totals must include every comparison, including offscreen untracked files")
        expect(try Data(contentsOf: index) == indexBefore, "Browsing must not modify the real Git index")
        try write("new status invalidates old totals\n", root, "transient.txt")
        do { _ = try await GitWorkspaceReader.workspaceStatistics(location, status); fatalError("Stale status totals were accepted") }
        catch GitBrowseError.changedDuringRead { checks += 1 }
        try FileManager.default.removeItem(at: root.appendingPathComponent("transient.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("main.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("main.txt").path, withDestinationPath: "source.txt")
        let typeStatus = try await GitWorkspaceReader.status(location)
        let typeFile = typeStatus.files.first { $0.path == "main.txt" }!
        expect(try await GitWorkspaceReader.statistics(location, .init(file: typeFile)) == .init(additions: 1, deletions: 1),
               "A regular-file to symlink change must count both native type-change records")
        expect(try await GitWorkspaceReader.workspaceStatistics(location, typeStatus).total == .init(additions: 6, deletions: 3, isBinary: true),
               "Batch totals must agree with individual type-change counts")
        try FileManager.default.removeItem(at: root.appendingPathComponent("main.txt"))
        try write("main branch\n", root, "main.txt")
        let huge = "large.txt"
        try write(String(repeating: "x", count: GitWorkspaceReader.maximumPatchBytes + 100), root, huge)
        do {
            _ = try await GitWorkspaceReader.diff(location, .init(file: .init(path: huge, status: "?", side: .untracked)))
            fatalError("A truncated bounded patch was accepted as complete")
        } catch GitBrowseError.tooLarge { checks += 1 }
        expect(try await GitWorkspaceReader.statistics(location, .init(file: .init(path: huge, status: "?", side: .untracked))) == .init(additions: 1),
               "Line counts must not load or truncate a multi-megabyte patch")
        try FileManager.default.removeItem(at: root.appendingPathComponent(huge))

        let unbornRoot = fixtures.appendingPathComponent("unborn", isDirectory: true)
        let unbornGit = try await repository(unbornRoot)
        try write("first\n", unbornRoot, "first.txt")
        _ = try await command(unbornGit, ["add", "first.txt"])
        let unborn = try await GitWorkspaceReader.locate(unbornRoot.path)!
        let unbornStatus = try await GitWorkspaceReader.status(unborn)
        expect(unbornStatus.head == nil && unbornStatus.branch == "main", "An unborn branch must not be confused with detached HEAD")
        expect(try await GitWorkspaceReader.diff(unborn, .init(file: unbornStatus.files[0])).additions == 1, "The first staged file must compare with an empty tree")
        expect(try await GitWorkspaceReader.workspaceStatistics(unborn, unbornStatus).total == .init(additions: 1),
               "An unborn branch still needs staged totals against the empty tree")

        let conflictRoot = fixtures.appendingPathComponent("conflict", isDirectory: true)
        let conflictGit = try await repository(conflictRoot)
        try write("base\n", conflictRoot, "conflict.txt")
        _ = try await command(conflictGit, ["add", "--all"])
        _ = try await command(conflictGit, ["commit", "--quiet", "-m", "Base"])
        _ = try await command(conflictGit, ["switch", "--quiet", "-c", "other"])
        try write("theirs\n", conflictRoot, "conflict.txt")
        _ = try await command(conflictGit, ["commit", "--quiet", "-am", "Other"])
        _ = try await command(conflictGit, ["switch", "--quiet", "main"])
        try write("ours\n", conflictRoot, "conflict.txt")
        _ = try await command(conflictGit, ["commit", "--quiet", "-am", "Main"])
        let conflictResult = try await conflictGit.run(["merge", "other", "--no-edit"])
        expect(!conflictResult.succeeded, "Conflict fixture must actually conflict")
        let conflictLocation = try await GitWorkspaceReader.locate(conflictRoot.path)!
        let conflictStatus = try await GitWorkspaceReader.status(conflictLocation)
        expect(conflictStatus.operations == ["Merge in progress"] && conflictStatus.files.first?.side == .conflict,
               "Conflict records and per-checkout operation markers must remain visible")
        let conflictDiff = try await GitWorkspaceReader.diff(conflictLocation, .init(file: conflictStatus.files[0]))
        expect(conflictDiff.hunks.flatMap(\.lines).contains { $0.text.hasPrefix("<<<<<<<") }, "Conflict diff must show the actual working conflict markers")
        expect(try await GitWorkspaceReader.workspaceStatistics(conflictLocation, conflictStatus).total
               == GitLineStatistics(additions: conflictDiff.additions, deletions: conflictDiff.deletions),
               "Conflict totals must use ours and consume Git's extra zero-count unmerged record")
        let linked = fixtures.appendingPathComponent("linked", isDirectory: true)
        _ = try await command(conflictGit, ["worktree", "add", "--quiet", "-b", "linked", linked.path])
        let linkedLocation = try await GitWorkspaceReader.locate(linked.path)!
        try FileManager.default.createDirectory(at: linkedLocation.gitDirectory.appendingPathComponent("rebase-merge"), withIntermediateDirectories: true)
        try write("linked only\n", linked, "conflict.txt")
        let linkedStatus = try await GitWorkspaceReader.status(linkedLocation)
        expect(linkedLocation.commonDirectory == conflictLocation.commonDirectory && linkedLocation.gitDirectory != conflictLocation.gitDirectory,
               "Linked worktrees must share refs while retaining their own index and HEAD")
        expect(linkedStatus.operations == ["Rebase in progress"], "A worktree must not borrow the main checkout's merge marker")
        let linkedDiff = try await GitWorkspaceReader.diff(linkedLocation, .init(file: linkedStatus.files[0]))
        expect(linkedDiff.hunks.flatMap(\.lines).contains { $0.text == "linked only" }, "Worktree diff read another checkout")
        expect(try await GitWorkspaceReader.workspaceStatistics(linkedLocation, linkedStatus).total == .init(additions: 1, deletions: 1),
               "Line totals must use a linked worktree's own index and working files")
        let baseBlob = try await command(conflictGit, ["rev-parse", "HEAD^:conflict.txt"])
        let theirBlob = try await command(conflictGit, ["rev-parse", "MERGE_HEAD:conflict.txt"])
        _ = try await command(conflictGit, ["update-index", "--index-info"], input:
            "0 \(String(repeating: "0", count: 40))\tconflict.txt\n100644 \(baseBlob) 1\tconflict.txt\n100644 \(theirBlob) 3\tconflict.txt\n")
        let noOurs = try await GitWorkspaceReader.status(conflictLocation)
        let unavailable = try await GitWorkspaceReader.workspaceStatistics(conflictLocation, noOurs)
        expect(noOurs.files.first?.side == .conflict && unavailable.files.isEmpty
               && unavailable.total == .init(additions: conflictDiff.additions, deletions: conflictDiff.deletions),
               "A missing conflict stage must withhold its row count while net totals still compare actual files with HEAD")

        try await stateChecks(location: location, status: status, source: source, files: partial, contextRoot: root)
        try await refreshChecks(location: location, status: status, source: source, file: partial.first { $0.side == .working }!)
        try await statisticsStateChecks(location: location, source: source, root: root)
        try await statisticsStabilityChecks(fixtures.appendingPathComponent("statistics-stability"))
        try await netRenameChecks(fixtures.appendingPathComponent("net-rename 中文\nsource"))
        try await watchChecks(location: location, root: root)
        try await layoutChecks(location: location, root: root, output: output)
        try await navigationChecks(location: location, status: status, source: source)
        try await tabPresentationChecks(location: location, output: output)
        try await referenceMenuChecks(output: output)
        let nestedRepo = root.appendingPathComponent("nested-repository", isDirectory: true)
        _ = try await repository(nestedRepo)
        let nestedLocation = try await GitWorkspaceReader.locate(nestedRepo.path)!
        try FileManager.default.removeItem(at: nestedRepo.appendingPathComponent(".git"))
        do { _ = try await GitWorkspaceReader.status(nestedLocation); fatalError("A removed nested repository fell back to its parent") }
        catch GitBrowseError.missingRepository { checks += 1 }
        try JSONSerialization.data(withJSONObject: ["checks": checks, "passed": true,
            "scope": "isolated Git fixtures, deterministic graph traversal, asynchronous ownership, visible-only FSEvents and unshown layout"], options: [.prettyPrinted])
            .write(to: output.appendingPathComponent("git-browser.json"))
        print("Git browser checks passed: \(checks)")
    }

    @MainActor private static func refreshChecks(location: GitRepositoryLocation, status: GitWorkspaceStatus,
                                                source: GitHistorySource, file: GitBrowseFile) async throws {
        let patch = "diff --git a/source.txt b/source.txt\n--- a/source.txt\n+++ b/source.txt\n@@ -1 +1 @@\n-old\n+new\n"
        let deferred = DiffFile(path: file.path, change: .modified, isBinary: false, hunks: [],
                                reportedAdditions: 1, reportedDeletions: 1, deferredPatch: patch, deferredLineCount: 2)
        let scenario = BrowserRefreshScenario(diff: deferred)
        let commit = GitBrowseCommit(id: source.head!, parents: [], author: "Fixture", date: .distantPast, subject: "Immutable commit")
        var reader = GitWorkspaceReading.live
        reader.locate = { _ in location }
        reader.status = { _ in await scenario.status(status) }
        reader.source = { _, _ in source }
        reader.diff = { _, _ in await scenario.diff() }
        reader.details = { _, _, _ in try await scenario.details(commit) }
        let state = GitWorkspaceStore(reader: reader, watchFactory: { _, _ in nil })
        state.present(.init(threadID: UUID(), workingDirectory: location.root.path))
        defer { state.suspend() }
        try await eventually("Refresh fixture must load") { state.status != nil && !state.isLoading }
        state.openFile(file)
        try await eventually("Deferred file must load") { state.diff != nil && !state.isSelectionLoading }
        state.expandDiff()
        try await eventually("Explicit expansion must finish") { state.diff?.isDeferred == false && !state.isSelectionLoading }
        let expanded = state.diff!
        expect(!expanded.hunks.isEmpty, "Expansion must expose the actual patch before testing refresh")

        let statusGate = await scenario.pauseStatus()
        let diffGate = await scenario.pauseDiff()
        state.refresh()
        expect(state.diff == expanded && state.selectionError == nil, "Starting a refresh must retain the visible diff")
        try await eventually("Background status read must reach its gate") { await statusGate.entered }
        expect(state.diff == expanded && state.status == status, "Repository revalidation must retain accepted visible content")
        state.refresh() // An activation notification may join an in-flight filesystem refresh.
        await statusGate.release()
        try await eventually("Coalesced refresh must revalidate the mutable comparison") { await diffGate.entered }
        expect(state.diff == expanded, "A slow comparison must never replace the diff with a loading placeholder")
        await diffGate.release()
        try await eventually("Unchanged refresh must settle") { !state.isLoading && !state.isSelectionLoading }
        expect(state.diff == expanded, "An unchanged read must preserve explicit expansion and the mounted diff")

        var changed = deferred
        changed.deferredPatch = patch.replacingOccurrences(of: "+new", with: "+external update")
        await scenario.replaceDiff(changed)
        state.refresh()
        try await eventually("External file changes must still replace old content") { state.diff == changed && !state.isSelectionLoading }
        expect(state.diff?.isDeferred == true, "A changed large patch must require its own explicit expansion")

        let lateDiff = await scenario.pauseDiff()
        state.refresh()
        try await eventually("Late refresh comparison must start") { await lateDiff.entered }
        state.openCommit(commit)
        try await eventually("New commit selection must load") { state.details?.commit == commit && !state.isSelectionLoading }
        await lateDiff.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(state.diff == nil && state.details?.commit == commit, "A preserved refresh must still reject completions after navigation")
        let commitGate = await scenario.pauseStatus()
        state.refresh()
        expect(state.details?.commit == commit, "Commit metadata must stay visible during revalidation")
        try await eventually("Commit refresh must reach its repository check") { await commitGate.entered }
        expect(state.details?.message == commit.subject, "Slow repository checks must retain immutable commit details")
        await commitGate.release()
        try await eventually("Commit refresh must settle") { !state.isLoading && !state.isSelectionLoading }
        expect(state.details?.commit == commit, "Unchanged commit refresh must keep its accepted detail snapshot")
        await scenario.setCommitMissing(true)
        state.refresh()
        try await eventually("Unavailable commits must surface their new read error") { state.selectionError != nil && !state.isSelectionLoading }
        expect(state.details == nil && state.diff == nil, "A failed refresh must not present its old snapshot as current")
        await scenario.setCommitMissing(false)
        state.refresh()
        try await eventually("A successful retry must restore commit details") { state.details?.commit == commit && !state.isSelectionLoading }
        expect(state.selectionError == nil, "A successful read must clear the previous selection error")
    }

    @MainActor private static func navigationChecks(location: GitRepositoryLocation, status: GitWorkspaceStatus,
                                                   source: GitHistorySource) async throws {
        let file = GitBrowseFile(path: "source.txt", status: "M", side: .commit)
        let patch = "diff --git a/source.txt b/source.txt\n--- a/source.txt\n+++ b/source.txt\n@@ -1 +1 @@\n-old\n+new\n"
        let deferred = DiffFile(path: file.path, change: .modified, isBinary: false, hunks: [],
                                reportedAdditions: 1, reportedDeletions: 1, deferredPatch: patch, deferredLineCount: 2)
        let scenario = BrowserRefreshScenario(diff: deferred, files: [file])
        let commit = GitBrowseCommit(id: source.head!, parents: [String(repeating: "a", count: 40), String(repeating: "b", count: 40)],
                                     author: "Fixture", date: .distantPast, subject: "Retained parent")
        var reader = GitWorkspaceReading.live
        reader.locate = { _ in location }
        reader.status = { _ in await scenario.status(status) }
        reader.source = { _, _ in await scenario.source(source) }
        reader.history = { location, tips, offset, count in
            await scenario.waitForHistory()
            return try await GitWorkspaceReading.live.history(location, tips, offset, count)
        }
        reader.details = { _, _, parent in try await scenario.details(commit, parent: parent) }
        reader.diff = { _, _ in await scenario.diff() }
        let state = GitWorkspaceStore(reader: reader, watchFactory: { _, _ in nil })
        let context = FilePreviewContext(threadID: UUID(), workingDirectory: location.root.path)
        state.present(context)
        defer { state.suspend() }
        try await eventually("Navigation fixture must validate its repository") { state.status != nil && !state.isLoading }

        let firstCommit = await scenario.pauseDetails()
        state.openCommit(commit)
        try await eventually("A first commit must prepare before presentation") { await firstCommit.entered }
        expect(state.route == .commit(commit.id) && state.displayedRoute == nil && state.details == nil,
               "The root must remain presented while the first commit detail is preparing")
        await firstCommit.release()
        try await eventually("Prepared commit must publish with its route") { state.displayedRoute == .commit(commit.id) && !state.isSelectionLoading }
        let parent = state.details!
        let firstFile = await scenario.pauseDiff()
        state.openFile(file)
        try await eventually("A first file must prepare before presentation") { await firstFile.entered }
        expect(state.displayedRoute == .commit(commit.id) && state.details == parent && state.diff == nil,
               "The accepted commit must stay visible while its first file is preparing")
        state.back()
        expect(state.displayedRoute == .commit(commit.id) && state.details == parent,
               "Back from a pending child must restore its accepted parent synchronously")
        await firstFile.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(state.route == .commit(commit.id) && state.diff == nil, "A cancelled child must not flash open after Back")

        let repeatedFile = await scenario.pauseDiff()
        state.openFile(file)
        try await eventually("A repeated click must begin from the accepted parent") { await repeatedFile.entered }
        state.openFile(file)
        try await eventually("Prepared child must keep its parent snapshot") { state.diff != nil && !state.isSelectionLoading }
        expect(state.details == parent && state.routes.count == 2,
               "Repeated clicks during preparation must retain the parent without adding phantom navigation levels")
        await repeatedFile.release()
        state.expandDiff()
        try await eventually("An expanded child must finish parsing") { state.diff?.isDeferred == false && !state.isSelectionLoading }
        let expanded = state.diff!
        let childRoute = state.displayedRoute
        state.suspend(keepingContent: true)
        expect(!state.isPresented && state.diff == expanded && state.details == parent && state.displayedRoute == childRoute
               && state.writeBlocker != nil, "An inactive tab must keep its bounded presentation while refusing writes")
        let resume = await scenario.pauseStatus()
        state.present(context)
        try await eventually("A resumed tab must revalidate its repository") { await resume.entered }
        expect(state.diff == expanded && state.displayedRoute == childRoute && state.writeBlocker != nil,
               "Resume must show the accepted page without authorizing writes from a cached repository check")
        await resume.release()
        try await eventually("An unchanged resume must keep explicit expansion") { !state.isLoading && !state.isSelectionLoading }
        expect(state.diff == expanded && state.details == parent, "An unchanged tab visit must preserve the complete accepted child and parent")

        var changed = deferred
        changed.deferredPatch = patch.replacingOccurrences(of: "+new", with: "+changed while away")
        state.suspend(keepingContent: true)
        await scenario.replaceDiff(changed)
        state.present(context)
        try await eventually("Resume must still read changed contents") { state.diff == changed && !state.isSelectionLoading }
        expect(state.displayedRoute == childRoute, "Changed contents must replace the retained comparison without losing its route")

        state.back()
        expect(state.displayedRoute == .commit(commit.id) && state.details == parent && state.diff == nil,
               "Back from a loaded child must present its cached parent without an empty intermediate state")
        try await eventually("Parent revalidation must finish before the next explicit comparison") { !state.isSelectionLoading }
        let otherParent = await scenario.pauseDetails()
        state.chooseParent(commit.parents[1])
        try await eventually("A different merge parent must still prepare its own comparison") { await otherParent.entered }
        expect(state.details == parent, "Changing merge parents must retain the accepted comparison until its replacement is ready")
        await otherParent.release()
        try await eventually("The selected parent must replace the cached comparison") { state.details?.parent == commit.parents[1] && !state.isSelectionLoading }
        state.openFile(file)
        try await eventually("The selected-parent child must load") { state.diff != nil && !state.isSelectionLoading }
        if case .file(let comparison) = state.route {
            expect(comparison.parent == commit.parents[1], "Prepared navigation must pin the file's actual selected parent")
        } else { fatalError("Expected selected-parent file") }
        let cancelledParent = await scenario.pauseDetails()
        state.chooseParent(commit.parents[0])
        try await eventually("A new parent comparison must leave the accepted inline file visible while preparing") { await cancelledParent.entered }
        state.toggleInlineFile(file)
        expect(state.route == .commit(commit.id) && state.displayedRoute == state.route && state.diff == nil
               && state.details?.parent == commit.parents[1],
               "Clicking an expanded inline diff collapses synchronously without losing its selected comparison parent")
        try await eventually("Collapsed parent revalidation must finish") { !state.isSelectionLoading }
        await cancelledParent.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(state.details?.parent == commit.parents[1], "Collapsing the accepted diff cancels a pending parent change as well")
        let cancelledInline = await scenario.pauseDiff()
        state.toggleInlineFile(file)
        try await eventually("A collapsed inline diff must be reopenable") { await cancelledInline.entered }
        state.toggleInlineFile(file)
        expect(state.route == .commit(commit.id) && state.diff == nil, "A second click also collapses a still-pending inline read")
        await cancelledInline.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(state.displayedRoute == .commit(commit.id) && state.diff == nil,
               "A late cancelled read must not reopen a collapsed inline diff")
        state.openCommitComposer()
        state.commitMessage = "Keep this draft when folding"
        let staged = state.commitReview!.files.first!
        state.toggleInlineFile(staged, inComposer: true)
        try await eventually("A composer file must expand inline") { state.diff != nil && !state.isSelectionLoading }
        state.toggleInlineFile(staged, inComposer: true)
        expect(state.route == .compose && state.displayedRoute == .compose && state.diff == nil
               && state.commitMessage == "Keep this draft when folding",
               "Collapsing a staged-file comparison retains the composer and its draft")
        state.suspend()
        expect(state.diff == nil && state.details == nil && state.displayedRoute == nil,
               "Full hiding must still release the retained child and parent snapshots")

        state.present(context)
        state.show(.history)
        try await eventually("History must load before testing reference refresh") { !state.commits.isEmpty && !state.isHistoryLoading && !state.isLoading }
        let acceptedHistory = state.commits
        let historyRead = await scenario.pauseHistory()
        let changedSource = GitHistorySource(head: source.head, references: source.references + [
            .init(name: "refs/heads/retained-history-fixture", commit: source.head!),
        ])
        await scenario.replaceSource(changedSource)
        state.refresh()
        try await eventually("Changed references must prepare a replacement graph") { await historyRead.entered }
        expect(state.commits == acceptedHistory && state.graph.rows.count == acceptedHistory.count,
               "Background reference changes must not clear accepted history before its replacement graph is ready")
        await historyRead.release()
        try await eventually("The replacement graph must finish publishing") { !state.isHistoryLoading && !state.isLoading }
        expect(state.graph.rows.count == state.commits.count && !state.commits.isEmpty,
               "A refreshed graph must publish complete matching commit and topology snapshots")
    }

    @MainActor private static func tabPresentationChecks(location: GitRepositoryLocation, output: URL) async throws {
        let previews = FilePreviewStore(persistenceURL: output.appendingPathComponent("git-tab-previews.json"))
        previews.setContext(.init(threadID: UUID(), workingDirectory: location.root.path))
        previews.openPanel(.git)
        let navigation = previews.session!.gitNavigation
        navigation.routes = [.compose]
        navigation.commitMessage = (0..<30).map { "Retained draft \($0) 中文 🧭" }.joined(separator: "\n")
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 650),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let resize = WindowLiveResize(window: window)
        let host = FrameHostingView(rootView: AnyView(WorkspaceSidebarPane(store: previews)
            .modifier(HostedEnvironment(model: model, liveResize: resize, previews: previews))))
        window.contentView = host
        defer { previews.suspend(); window.contentView = nil; window.close() }
        var native: NSTextView?
        try await eventually("The production sidebar must create its Git draft editor") {
            host.layoutSubtreeIfNeeded()
            native = descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == navigation.commitMessage }
            return native != nil
        }
        let editor = native!
        let scroll = editor.enclosingScrollView!
        editor.setSelectedRange(NSRange(location: 20, length: 4))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        let offset = scroll.contentView.bounds.origin.y
        expect(offset > 80, "The retained tab fixture must begin with a scrolled native editor")
        previews.openPanel(.files)
        try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        expect(descendants(host).contains { $0 === editor } && editor.enclosingScrollView === scroll,
               "Visiting Files must keep the Git page's actual native editor and scroll viewport mounted")
        expect(!editor.isEditable, "An inactive retained Git page must not accept native editing or shortcuts")
        previews.openPanel(.git)
        try await eventually("Returning to Git must re-enable the retained editor") { host.layoutSubtreeIfNeeded(); return editor.isEditable }
        expect(descendants(host).contains { $0 === editor } && editor.string == navigation.commitMessage
               && editor.selectedRange() == NSRange(location: 20, length: 4),
               "Tab return must retain the native draft, selection and editor identity")
        expect(abs(scroll.contentView.bounds.origin.y - offset) < 1, "Tab return must keep the exact native reading offset")
        previews.setFullscreen(true)
        window.setContentSize(NSSize(width: 1000, height: 650))
        func divider() -> DragHandleView? {
            descendants(host).compactMap { $0 as? DragHandleView }.first { $0.bounds.height > 200 && $0.bounds.width == 9 }
        }
        try await eventually("Fullscreen composer must open beside the changes list") { host.layoutSubtreeIfNeeded(); return divider() != nil }
        let handle = divider()!
        let before = handle.convert(handle.bounds, to: host).midX
        handle.onBegin?(); handle.onChange?(CGSize(width: 130, height: 0)); handle.onEnd?()
        try await eventually("Dragging the native divider must redistribute both columns") {
            host.layoutSubtreeIfNeeded()
            return abs(handle.convert(handle.bounds, to: host).midX - before - 130) < 1
        }
        let dividedAt = handle.convert(handle.bounds, to: host).midX
        let fraction = previews.session!.gitDetailFraction
        previews.openPanel(.files)
        try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        previews.openPanel(.git)
        try await eventually("Returning to fullscreen Git must restore the divider and editable draft") {
            host.layoutSubtreeIfNeeded()
            return editor.isEditable && divider().map { abs($0.convert($0.bounds, to: host).midX - dividedAt) < 1 } == true
        }
        expect(previews.session!.gitDetailFraction == fraction && descendants(host).contains { $0 === editor },
               "Tab switching must preserve both the column allocation and the actual composer")
        try snapshot(host, to: output.appendingPathComponent("git-fullscreen-composer.png"))
        previews.closeSidebarTab(.panel(.git))
        try await eventually("Closing Git must release its retained native page") {
            host.layoutSubtreeIfNeeded()
            return !descendants(host).contains { $0 === editor }
        }
        expect(!window.isVisible, "Tab presentation checks must never show or launch the GUI")
    }

    @MainActor private static func stateChecks(location: GitRepositoryLocation, status: GitWorkspaceStatus,
                                              source: GitHistorySource, files: [GitBrowseFile], contextRoot: URL) async throws {
        let context = FilePreviewContext(threadID: UUID(), workingDirectory: contextRoot.path)
        let gate = BrowserReadGate()
        var reader = GitWorkspaceReading.live
        reader.diff = { _, comparison in
            if comparison.file.side == .index { await gate.hold() }
            return DiffFile(path: comparison.file.side.rawValue, change: .modified, isBinary: false, hunks: [])
        }
        let state = GitWorkspaceStore(reader: reader, watchFactory: { _, _ in nil })
        state.present(context)
        try await eventually("Initial state must settle") { !state.isLoading && state.status != nil }
        state.openFile(files.first { $0.side == .index }!)
        try await eventually("The first diff must enter the slow reader") { await gate.entered }
        state.back(); state.openFile(files.first { $0.side == .working }!)
        try await eventually("The newer diff must publish") { state.diff?.path == "working" }
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(state.diff?.path == "working", "A cancelled late diff replaced the newer selection")
        state.beginSearch()
        expect(state.route == nil && state.showsSearch && state.diff == nil, "Search from a detail page must enter its searchable root")
        state.openFile(files.first { $0.side == .working }!)
        state.suspend()
        expect(state.diff == nil && state.details == nil && !state.isPresented, "Hidden pages must release diff bodies and reads")
        let navigation = state.navigation
        expect(navigation.routes.count == 1, "Hiding should retain lightweight file navigation")

        let refreshGate = BrowserReadGate()
        var racingReader = GitWorkspaceReading.live
        racingReader.locate = { _ in location }
        racingReader.status = { _ in await refreshGate.hold(); return status }
        racingReader.source = { _, _ in source }
        let racing = GitWorkspaceStore(reader: racingReader, watchFactory: { _, _ in nil })
        racing.present(context)
        try await eventually("The old workspace status must enter its reader") { await refreshGate.entered }
        racing.suspend()
        await refreshGate.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(racing.status == nil && !racing.isLoading, "An unmounted page published an old status read")

        let scenario = BrowserPageRetry()
        var retryReader = GitWorkspaceReading.live
        retryReader.history = { _, _, offset, _ in try await scenario.read(offset: offset) }
        let retryNavigation = GitBrowseNavigation()
        retryNavigation.mode = .history
        let retry = GitWorkspaceStore(navigation: retryNavigation, reader: retryReader, watchFactory: { _, _ in nil })
        retry.present(context)
        try await eventually("The first page must load") { retry.commits.count == 1 && !retry.isHistoryLoading }
        retry.loadMoreHistory()
        try await eventually("The failed next page must retain its accepted prefix") { retry.historyError != nil && !retry.isHistoryLoading }
        expect(retry.commits.count == 1, "A failed page must not discard accepted history")
        retry.refresh()
        try await eventually("Retry must actually re-read the failed history page") { retry.commits.count == 2 && !retry.isHistoryLoading }
        expect(retry.historyError == nil && !retry.hasMoreHistory, "Successful retry must clear the old page error")
        retry.suspend()
    }

    @MainActor private static func statisticsStateChecks(location: GitRepositoryLocation,
                                                        source: GitHistorySource, root: URL) async throws {
        // Earlier fixtures may refresh Git's index metadata. The mock must pin
        // the current revision, just as the production refresh does.
        let status = try await GitWorkspaceReader.status(location)
        let scenario = BrowserStatisticsScenario()
        var reader = GitWorkspaceReading.live
        reader.locate = { _ in location }; reader.status = { _ in status }; reader.source = { _, _ in source }
        reader.workspaceStatistics = { _, status, _ in try await scenario.read(status) }
        reader.statisticsInputs = { location, status, paths in
            var inputs = try await GitWorkspaceReader.statisticsInputs(location, status, paths)
            inputs.configuration += "-\(await scenario.revision)"
            return inputs
        }
        let state = GitWorkspaceStore(reader: reader, watchFactory: { _, _ in nil })
        defer { state.suspend() }
        let context = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        state.present(context)
        try await eventually("Initial complete line totals must publish") { state.workspaceStatistics?.total?.additions == status.files.count }
        state.query = "no file matches this search"
        state.chooseGroup(.untracked)
        expect(state.filteredFiles.isEmpty && state.workspaceStatistics?.total?.additions == status.files.count,
               "Filtering and grouping must not turn the top total into a partial visible-row sum")

        let late = await scenario.pause(2)
        state.refresh()
        try await eventually("The superseded statistics read must start") { await late.entered }
        expect(state.workspaceStatistics?.total?.additions == status.files.count,
               "An in-progress refresh must keep its accepted numbers rather than flash a placeholder")
        state.show(.history)
        await scenario.replace(3)
        state.show(.changes)
        try await eventually("Returning to Changes must publish a fresh total") { state.workspaceStatistics?.total?.additions == status.files.count * 3 }
        await late.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(state.workspaceStatistics?.total?.additions == status.files.count * 3,
               "A cancelled reader must not overwrite the newer Changes total")

        let hidden = await scenario.pause(4)
        state.refresh()
        try await eventually("The hidden statistics read must start") { await hidden.entered }
        state.suspend()
        await hidden.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(state.workspaceStatistics == nil && !state.isStatisticsLoading && state.statisticsError == nil,
               "Hiding must release counts and reject late results without publishing a spurious error")
        state.present(context)
        try await eventually("Reopening Changes must read complete current totals") { state.workspaceStatistics?.total?.additions == status.files.count * 4 }
    }

    @MainActor private static func statisticsStabilityChecks(_ root: URL) async throws {
        let git = try await repository(root)
        let base = "one\ntwo\nthree\n"
        try write(base, root, "root.txt")
        _ = try await command(git, ["add", "--all"])
        _ = try await command(git, ["commit", "--quiet", "-m", "Statistics base"])
        try write("one\nstage\nthree\n", root, "root.txt")
        _ = try await command(git, ["add", "root.txt"])
        try write("one\nother\nthree\n", root, "root.txt")
        let counter = BrowserStatisticsCounter()
        let scenario = BrowserRefreshScenario(diff: .init(path: "root.txt", change: .modified, isBinary: false, hunks: []))
        var reader = GitWorkspaceReading.live
        reader.status = { location in await scenario.status(try await GitWorkspaceReader.status(location)) }
        reader.workspaceStatistics = { location, status, total in
            await counter.read(total)
            return try await GitWorkspaceReader.workspaceStatistics(location, status, total: total)
        }
        let state = GitWorkspaceStore(reader: reader, watchFactory: { _, _ in nil })
        defer { state.suspend() }
        func ready() async throws {
            try await eventually("Statistics must settle") {
                !state.isLoading && !state.isStatisticsLoading && !state.isWriting && state.workspaceStatistics?.total != nil
            }
        }
        state.present(.init(threadID: UUID(), workingDirectory: root.path))
        try await ready()
        expect(state.workspaceStatistics?.total == .init(additions: 1, deletions: 1),
               "Overlapping staged/unstaged edits must count the actual net change once")
        expect(await counter.rows == 1, "The first complete comparison should read rows once")
        expect(await counter.totals == 1, "The first complete comparison should read the total once")
        state.refresh() // Same path as application activation.
        expect(state.workspaceStatistics?.total == .init(additions: 1, deletions: 1), "Activation must retain accepted numbers during validation")
        try await ready()
        expect(await counter.rows == 1, "Unchanged activation must not recalculate row counts")
        expect(await counter.totals == 1, "Unchanged activation must not recalculate the total")

        let lateRefresh = await scenario.pauseStatus()
        state.refresh()
        try await eventually("The old activation refresh must start before staging") { await lateRefresh.entered }
        state.stage(state.status!.files.first { $0.side == .working }!)
        expect(state.workspaceStatistics?.total == .init(additions: 1, deletions: 1), "Staging must not clear the displayed total")
        try await ready()
        await lateRefresh.release()
        try await Task.sleep(for: .milliseconds(50))
        expect(state.error == nil && state.status?.files.allSatisfy { $0.side == .index } == true,
               "A superseded activation refresh must not clear or overwrite the state produced by staging")
        expect(await counter.rows == 2, "Staging must refresh the row's changed comparison side")
        expect(await counter.totals == 1, "Staging must reuse the total because working contents did not change")
        state.stage(state.status!.files.first { $0.side == .index }!, unstaging: true)
        try await ready()
        expect(state.workspaceStatistics?.total == .init(additions: 1, deletions: 1), "Unstaging must retain the same net total")
        expect(await counter.totals == 1, "Unstaging must not reread the net diff")
        let rows = await counter.rows
        state.refresh(); try await ready()
        expect(await counter.rows == rows, "Activation after unstaging must also reuse accepted comparisons")

        // Same byte length and the same porcelain M status, different content.
        try write("one\nlater\nthird\n", root, "root.txt")
        state.refresh()
        try await ready()
        expect(state.workspaceStatistics?.total == .init(additions: 2, deletions: 2), "Same-size edits must invalidate cached content inputs")
        expect(await counter.totals == 2, "Actual content changes must trigger a fresh total")
        try write("new\n", root, "new.txt")
        state.refresh(); try await ready()
        expect(state.workspaceStatistics?.total == .init(additions: 3, deletions: 2), "New untracked files must enter the net total")
        let totalsWithNewFile = await counter.totals
        state.stage(state.status!.files.first { $0.path == "new.txt" }!)
        try await ready()
        expect(await counter.totals == totalsWithNewFile, "Tracking a previously untracked file must not recalculate its total")
        expect(state.workspaceStatistics?.files["index:new.txt"] == .init(additions: 1), "The newly staged row must still get its own index count")

        state.stage(state.status!.files.first { $0.path == "root.txt" }!)
        try await ready()
        try write(base, root, "root.txt")
        state.refresh(); try await ready()
        expect(state.workspaceStatistics?.total == .init(additions: 1), "Working edits that reverse staged edits must cancel in the total")
        let totalsBeforeCancellation = await counter.totals
        state.stage(state.status!.files.first { $0.path == "root.txt" && $0.side == .working }!)
        try await ready()
        expect(!state.status!.files.contains { $0.path == "root.txt" }, "Staging the reversal must remove the clean path from status")
        expect(await counter.totals == totalsBeforeCancellation, "A path disappearing after staging must not invalidate unchanged working contents")
        expect(state.workspaceStatistics?.total == .init(additions: 1), "Removing a clean comparison must retain the correct total")
        _ = try await command(git, ["commit", "--quiet", "-m", "New baseline"])
        state.refresh(); try await ready()
        expect(state.workspaceStatistics?.total == .init(), "A changed HEAD must invalidate the old net baseline")
        expect(await counter.totals == totalsBeforeCancellation + 1, "A changed HEAD requires a new total even with unchanged working files")
        let attributes = root.deletingLastPathComponent().appendingPathComponent("statistics-global-attributes")
        try Data("*.txt diff\n".utf8).write(to: attributes)
        _ = try await command(git, ["config", "core.attributesFile", attributes.path])
        try write("changed\n", root, "root.txt")
        state.refresh(); try await ready()
        expect(state.workspaceStatistics?.total == .init(additions: 1, deletions: 3), "Explicit global text attributes must retain text counts")
        let totalsBeforeAttributes = await counter.totals
        try Data("*.txt -diff\n".utf8).write(to: attributes)
        state.refresh(); try await ready()
        expect(state.workspaceStatistics?.total == .init(isBinary: true), "Changed global attribute contents must invalidate cached counts")
        expect(await counter.totals == totalsBeforeAttributes + 1, "Attribute-only changes must be read even when HEAD, index and working bytes are unchanged")
    }

    @MainActor private static func netRenameChecks(_ root: URL) async throws {
        let git = try await repository(root)
        let old = ":(glob)* [原始]\nfile.txt", new = ":(literal)更名\tfile.txt"
        let original = (0..<12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try write(original, root, old); try write("kept\n", root, "keep.txt")
        _ = try await command(git, ["add", "--all"])
        _ = try await command(git, ["commit", "--quiet", "-m", "Rename baseline"])
        try FileManager.default.moveItem(at: root.appendingPathComponent(old), to: root.appendingPathComponent(new))
        try write(original.replacingOccurrences(of: "line 5\n", with: "changed line 5\n"), root, new)
        let location = try await GitWorkspaceReader.locate(root.path)!
        let hooks = location.gitDirectory.appendingPathComponent("read-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appendingPathComponent("post-index-change")
        try Data("#!/bin/sh\ntouch should-not-run\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await command(git, ["config", "core.hooksPath", hooks.path])
        let marker = root.appendingPathComponent("should-not-run")
        let index = try Data(contentsOf: location.indexFile)
        let objects = try FileManager.default.subpathsOfDirectory(atPath: location.commonDirectory.appendingPathComponent("objects").path).sorted()
        let unstaged = try await GitWorkspaceReader.status(location)
        expect(try await GitWorkspaceReader.workspaceStatistics(location, unstaged).total == .init(additions: 1, deletions: 1),
               "An unstaged rename must use native rename detection rather than whole-file addition/deletion counts")
        expect(try Data(contentsOf: location.indexFile) == index && !FileManager.default.fileExists(atPath: marker.path),
               "Net counts must neither write the real index nor invoke its post-index-change hook")
        expect(try FileManager.default.subpathsOfDirectory(atPath: location.commonDirectory.appendingPathComponent("objects").path).sorted() == objects,
               "Intent-to-add objects must stay in the disposable object directory")
        _ = try await command(git, ["--literal-pathspecs", "add", "--all"])
        expect(FileManager.default.fileExists(atPath: marker.path), "The hook fixture must actually run for a real index mutation")
        try FileManager.default.removeItem(at: marker)
        let staged = try await GitWorkspaceReader.status(location)
        expect(try await GitWorkspaceReader.workspaceStatistics(location, staged).total == .init(additions: 1, deletions: 1),
               "Fresh net counts must remain identical after staging a literal rename")
        expect(!FileManager.default.fileExists(atPath: marker.path), "Reading the staged rename must still bypass private-index hooks")
        _ = try await command(git, ["rm", "--cached", "--", "keep.txt"])
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        let untrackedHeadPath = try await GitWorkspaceReader.status(location)
        expect(try await GitWorkspaceReader.workspaceStatistics(location, untrackedHeadPath).total == .init(additions: 1, deletions: 1),
               "Removing a path from the index while keeping its HEAD contents on disk must not manufacture net changes")
    }

    @MainActor private static func watchChecks(location: GitRepositoryLocation, root: URL) async throws {
        var notifications = 0
        let state = GitWorkspaceStore(watchFactory: { location, notify in
            GitRepositoryWatch(location: location) { notifications += 1; notify() }
        })
        state.present(.init(threadID: UUID(), workingDirectory: root.path))
        try await eventually("Watch-backed state must settle") { !state.isLoading && state.status != nil }
        expect(state.automaticRefreshAvailable, "Local repository must support automatic refresh")
        try write("external change without a Git command\n", root, "watch-visible.txt")
        try await eventually("Ordinary working-file writes must refresh status") { state.status?.files.contains { $0.path == "watch-visible.txt" } == true }
        state.suspend()
        let before = notifications
        try write("hidden write\n", root, "watch-hidden.txt")
        try await Task.sleep(for: .milliseconds(900))
        expect(notifications == before, "Hidden Git pages retained filesystem observations")
    }

    @MainActor private static func layoutChecks(location: GitRepositoryLocation, root: URL, output: URL) async throws {
        _ = NSApplication.shared // Never order this window front or run OMP.
        let longReference = "refs/heads/feature/sidebar-branch-label"
        _ = try await command(Git(location.root.path), ["update-ref", longReference, "HEAD"])
        let previews = FilePreviewStore(persistenceURL: output.appendingPathComponent("git-layout-previews.json"))
        let context = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        previews.setContext(context); previews.openPanel(.git)
        let session = previews.session!
        let layoutStatistics = BrowserStatisticsScenario()
        var reader = GitWorkspaceReading.live
        reader.workspaceStatistics = { _, status, _ in try await layoutStatistics.read(status) }
        reader.statisticsInputs = { location, status, paths in
            var inputs = try await GitWorkspaceReader.statisticsInputs(location, status, paths)
            inputs.configuration += "-\(await layoutStatistics.revision)"
            return inputs
        }
        let state = GitWorkspaceStore(navigation: session.gitNavigation, reader: reader, watchFactory: { _, _ in nil })
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 650), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let resize = WindowLiveResize(window: window)
        let host = FrameHostingView(rootView: AnyView(GitWorkspacePane(previews: previews, session: session, state: state)
            .modifier(HostedEnvironment(model: model, liveResize: resize, previews: previews))
            .background(Color(nsColor: .windowBackgroundColor))))
        window.contentView = host
        defer { state.suspend(); previews.suspend(); window.contentView = nil; window.close() }
        try await eventually("Production Git page must load the fixture") { host.layoutSubtreeIfNeeded(); return state.status != nil && !state.isLoading }
        state.show(.history)
        try await eventually("Production history must render loaded topology") { !state.isHistoryLoading && !state.commits.isEmpty }
        func capture(_ name: String, width: Int) async throws {
            window.setContentSize(NSSize(width: width, height: 650)); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            try snapshot(host, to: output.appendingPathComponent("git-\(name)-\(width).png"))
            expect(host.bounds.width == CGFloat(width) && !window.isVisible, "Layout checks must use the requested width without showing a GUI")
        }
        func toolbarFits() {
            let controls = descendants(host).compactMap { $0 as? NoWindowDragView }.map { view -> NSRect in
                var frame = view.convert(view.bounds, to: host)
                if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
                return frame
            }.filter { $0.height > 1 && $0.minY >= 0 && $0.minY < 40 }
            expect(!controls.isEmpty && controls.allSatisfy { $0.minX >= -0.5 && $0.maxX <= host.bounds.width + 0.5 },
                   "Every actual toolbar control must stay within the viewport, including when totals have many digits")
            expect((controls.map(\.midY).max()! - controls.map(\.midY).min()!) < 1,
                   "All global action hit targets must remain centered on a single toolbar line")
        }
        for width in [260, 360, 480] { try await capture("history", width: width); toolbarFits() }
        state.chooseReference(longReference)
        try await eventually("Named branch history must load") { !state.isHistoryLoading && !state.commits.isEmpty }
        for width in [260, 480] { try await capture("history-long-branch", width: width); toolbarFits() }
        state.chooseReference(nil)
        try await eventually("All-branch history must restore") { !state.isHistoryLoading && !state.commits.isEmpty }
        state.openCommit(state.commits.first { $0.parents.count > 1 }!)
        try await eventually("Commit drill-down must load files") { state.details != nil && !state.isSelectionLoading }
        expect(state.details?.commit.parents.count == 2, "Production details must retain all merge parents")
        try await capture("commit", width: 360)
        state.back()
        expect(state.route == nil && state.historyAnchor != nil, "Returning must restore the graph anchor")
        // Six 54 pt commits must remain scrollable without relying on the
        // repository/scope headers that the production UI no longer shows.
        window.setContentSize(NSSize(width: 360, height: 240))
        var historyScroll: NSScrollView?
        try await eventually("History fixture must expose a scrollable native viewport") {
            host.layoutSubtreeIfNeeded()
            historyScroll = descendants(host).compactMap { $0 as? NSScrollView }.first {
                $0.bounds.height > 100 && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 100
            }
            return historyScroll != nil
        }
        let originalScroll = historyScroll!
        originalScroll.contentView.scroll(to: NSPoint(x: 0, y: 113.5))
        originalScroll.reflectScrolledClipView(originalScroll.contentView)
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let scrollOffset = originalScroll.contentView.bounds.origin.y
        expect(scrollOffset > 80, "The history regression must begin between rows rather than at the top")
        state.openCommit(state.commits.first { $0.parents.count > 1 }!)
        try await eventually("Scrolled history must open commit details") { host.layoutSubtreeIfNeeded(); return state.details != nil && !state.isSelectionLoading }
        expect(descendants(host).contains { $0 === originalScroll }, "Commit details must retain the history's original native scroller")
        let parentScroll = descendants(host).compactMap { $0 as? NSScrollView }.first {
            $0 !== originalScroll && $0.bounds.height > 100
        }!
        state.openFile(state.details!.files.first!)
        try await eventually("Commit file drill-down must load") { host.layoutSubtreeIfNeeded(); return state.diff != nil && !state.isSelectionLoading }
        expect(descendants(host).contains { $0 === parentScroll }, "File drill-down must keep the actual parent commit scroller mounted")
        state.back()
        expect(state.displayedRoute == state.route && state.details != nil,
               "Native Back must expose the accepted parent before another asynchronous read")
        try await eventually("Returning from a commit file must reload its commit") { state.details != nil && !state.isSelectionLoading }
        host.layoutSubtreeIfNeeded()
        expect(descendants(host).contains { $0 === parentScroll }, "Returning must reuse the parent's native viewport")
        state.back()
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        expect(state.route == nil && descendants(host).contains { $0 === originalScroll }, "Returning from nested details must reuse the history viewport")
        expect(abs(originalScroll.contentView.bounds.origin.y - scrollOffset) < 1,
               "Returning from details must preserve the exact scroll offset, not align the clicked commit to the top")
        state.show(.changes)
        try await eventually("Changes totals must settle before measuring controls") { state.workspaceStatistics?.total != nil }
        for width in [260, 360, 400, 480] { try await capture("changes", width: width); toolbarFits() }
        await layoutStatistics.replace(99_999_999_999)
        state.refresh()
        try await eventually("Long totals must publish for layout") { (state.workspaceStatistics?.total?.additions ?? 0) > 99_999_999_999 }
        let originalUI = TypeScale.shared.ui
        for fontSize in [originalUI, TypeScale.uiRange.upperBound] {
            TypeScale.shared.ui = fontSize
            for width in [360, 400, 480] {
                window.setContentSize(NSSize(width: width, height: 650)); host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
                toolbarFits()
            }
        }
        TypeScale.shared.ui = originalUI
        state.openFile(state.status!.files.first { $0.path == "source.txt" && $0.side == .working }!)
        try await eventually("File drill-down must render the live comparison") { state.diff != nil && !state.isSelectionLoading }
        for width in [260, 360] { try await capture("file", width: width) }

        state.back()
        previews.setFullscreen(true)
        try await capture("fullscreen-overview", width: 1000)
        func divider() -> DragHandleView? {
            descendants(host).compactMap { $0 as? DragHandleView }.first { $0.bounds.height > 200 && $0.bounds.width == 9 }
        }
        let list = descendants(host).compactMap { $0 as? NSScrollView }.first { $0.bounds.width > 900 }!
        expect(divider() == nil, "Fullscreen without a selected item must keep one full-width overview")
        let changedFiles = state.status!.files.filter { $0.path == "source.txt" }
        expect(changedFiles.count == 2, "The fullscreen fixture has both staged and working comparisons")
        for file in changedFiles.prefix(2) {
            state.openFile(file, replacingDetail: true)
            try await eventually("Fullscreen file selection must finish") { !state.isSelectionLoading && state.displayedRoute == state.route }
            expect(state.routes.count == 1, "Selecting a different visible file replaces the detail without growing a Back stack")
        }
        try await capture("fullscreen-file", width: 1000)
        expect(divider() != nil && descendants(host).contains { $0 === list } && list.bounds.width > 240 && list.bounds.width < 600,
               "Selecting a file retains and resizes the original list beside its diff")
        let right = descendants(host).compactMap { $0 as? NSScrollView }.first { $0 !== list && $0.bounds.height > 200 }!
        expect(right.convert(right.bounds, to: host).minX > list.convert(list.bounds, to: host).maxX,
               "The detail and list must occupy distinct columns separated by the divider")
        state.show(.history)
        try await eventually("Fullscreen history must load") { !state.isHistoryLoading && !state.commits.isEmpty }
        state.openCommit(state.commits.first { $0.parents.isEmpty }!)
        try await eventually("Fullscreen commit detail must load") { state.details != nil && !state.isSelectionLoading }
        try await capture("fullscreen-commit", width: 1000)
        let commitScroll = descendants(host).compactMap { $0 as? NSScrollView }.first { $0.convert($0.bounds, to: host).minX > 300 }!
        for file in state.details!.files.prefix(2) {
            state.toggleInlineFile(file)
            try await eventually("Fullscreen commit file must load inline") { !state.isSelectionLoading && state.diff != nil }
            expect(state.routes.count == 2, "Commit files replace their sibling detail while retaining one parent commit")
        }
        try await capture("fullscreen-commit-file", width: 1000)
        expect(descendants(host).contains { $0 === commitScroll }
               && descendants(host).compactMap { $0 as? NSScrollView }.count == 3,
               "An inline comparison gets its own scroll viewport while retaining its parent file list")
        func inlineViewport() -> NSScrollView? {
            descendants(commitScroll).compactMap { $0 as? NSScrollView }.first { $0 !== commitScroll }
        }
        let longFile = state.details!.files.first { $0.path == "inline-long.txt" }!
        expect(state.route == .file(state.comparison(for: longFile)), "The long inline fixture must be selected")
        let longViewport = inlineViewport()!
        expect(longViewport.bounds.height <= 360.5 && longViewport.bounds.height >= 350
               && (longViewport.documentView?.bounds.height ?? 0) > 1000,
               "Long inline diffs must cap at 360 pt while retaining all scrollable lines")
        let parentOffset = commitScroll.contentView.bounds.origin.y
        longViewport.contentView.scroll(to: NSPoint(x: 0, y: 500))
        longViewport.reflectScrolledClipView(longViewport.contentView)
        try await capture("inline-diff-scrolled", width: 1000)
        expect(longViewport.contentView.bounds.origin.y > 450 && abs(commitScroll.contentView.bounds.origin.y - parentOffset) < 1,
               "Scrolling the inline diff must not move the surrounding file list")
        window.appearance = NSAppearance(named: .darkAqua)
        try await capture("inline-diff-dark", width: 1000)
        window.appearance = NSAppearance(named: .aqua)
        state.toggleInlineFile(longFile)
        try await capture("inline-diff-collapsed", width: 1000)
        expect(inlineViewport() == nil && descendants(host).contains { $0 === commitScroll },
               "Clicking the expanded row removes its diff viewport and retains the actual parent list")
        let shortFile = state.details!.files.first { $0.path == "removed.txt" }!
        state.toggleInlineFile(shortFile)
        try await eventually("Another inline file must expand after collapsing") { state.diff != nil && !state.isSelectionLoading }
        try await capture("inline-diff-short", width: 1000)
        expect(inlineViewport().map { $0.bounds.height > 0 && $0.bounds.height < 360 } == true,
               "Short inline diffs fit their content instead of reserving the maximum height")
        previews.setFullscreen(false)
        try await capture("fullscreen-exit-file", width: 360)
        expect(divider() == nil, "Leaving fullscreen restores single-column drill-down")
        previews.setWorkspacePresented(false)
        try await eventually("Settings coverage must suspend Git reads") { !state.isPresented }
        expect(state.diff == nil, "Covered Git pane retained a diff buffer")
    }

    @MainActor private static func referenceMenuChecks(output: URL) async throws {
        let names = ["main", "codex/keep-the-entire-branch-name-visible-in-this-wider-popover",
                     "feature/keep-the-entire-long-branch-name-visible/including-the-middle-and-the-final-component-without-an-ellipsis",
                     "origin/功能分支/完整显示分支名称及最后一个路径组件"]
        func references(_ names: [String]) -> [GitHistoryReference] {
            names.map { GitHistoryReference(name: "refs/heads/" + $0, commit: String(repeating: "a", count: 40)) }
        }
        let sizing = GitReferenceMenuSizing()
        let short = references(["main", "feature/ui"])
        let medium = references(["main", "codex/history-scroll-restoration"])
        let refs = references(names)
        let shortWidth = sizing.width(references: short, maximumWidth: 2000)
        let mediumWidth = sizing.width(references: medium, maximumWidth: 2000)
        let longWidth = sizing.width(references: refs, maximumWidth: 2000)
        expect(shortWidth < mediumWidth && mediumWidth < longWidth,
               "Reference popovers must grow with the longest name instead of keeping a fixed width")
        expect(sizing.width(references: short, maximumWidth: 2000) == shortWidth,
               "Returning to short branch names must shrink the popover again")
        let completeRow = PopoverItem(names[2], text: Text(verbatim: names[2]), isChecked: false, wrapsTitle: true) {}
        let completeHost = NSHostingView(rootView: completeRow.frame(width: longWidth - 12))
        expect(completeHost.fittingSize.height <= 26,
               "Natural width must fit the longest branch on one line when screen space permits")
        let limitedWidth = sizing.width(references: refs, maximumWidth: 300)
        expect(limitedWidth <= 300, "A reference popover must respect the available screen width")
        let row = PopoverItem(names[2], text: Text(verbatim: names[2]), isChecked: false, wrapsTitle: true) {}
        let rowHost = NSHostingView(rootView: row.frame(width: limitedWidth - 12))
        expect(rowHost.fittingSize.height > 26, "Long branch names must gain enough height to display their full text")
        for (name, list) in [("short", short), ("medium", medium), ("long", refs)] {
            let width = sizing.width(references: list, maximumWidth: 1000)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = FrameHostingView(rootView: AnyView(PopoverMenu(width: width) {
                GitHistoryReferenceMenu(references: list, selection: list[1].name, onSelect: { _ in })
            }.frame(width: width, height: 300, alignment: .topLeading)))
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            try snapshot(host, to: output.appendingPathComponent("git-reference-menu-\(name).png"))
            expect(!window.isVisible, "Reference-menu layout verification must never show a GUI")
        }
        let originalUI = TypeScale.shared.ui
        defer { TypeScale.shared.ui = originalUI }
        TypeScale.shared.ui = originalUI < TypeScale.uiRange.upperBound
            ? min(originalUI + 2, TypeScale.uiRange.upperBound) : originalUI - 2
        let resizedWidth = sizing.width(references: medium, maximumWidth: 2000)
        expect(TypeScale.shared.ui > originalUI ? resizedWidth > mediumWidth : resizedWidth < mediumWidth,
               "Changing interface font size must also update the reference popover's natural width")
    }
}
