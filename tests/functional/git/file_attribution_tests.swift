import AppKit
import Foundation
@testable import OMPGUI

@main
struct FileAttributionChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }

    @MainActor private static func run(_ git: Git, _ args: [String]) async throws {
        let result = try await git.run(args)
        expect(result.succeeded, "Git fixture failed: \(args): \(result.output)")
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError("Command attribution did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private static func checkMerge(in root: URL, app: AppModel, writes: Bool, foreign: Bool) async throws {
        let name = foreign ? "foreign-merge" : writes ? "merge-with-own-writes" : "merge-only"
        let checkout = root.appendingPathComponent(name)
        let incoming = root.appendingPathComponent(name + "-other-task")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let git = Git(checkout.path)
        try await run(git, ["init", "-q", "--initial-branch=main"])
        for path in ["shared.txt", "renamed.txt", "deleted.txt"] {
            try write("before\n", to: checkout.appendingPathComponent(path))
        }
        try await run(git, ["add", "."])
        try await run(git, ["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "Baseline"])
        try await run(git, ["worktree", "add", "-q", "-b", "other-task", incoming.path])
        let other = Git(incoming.path)
        try write("incoming\n", to: incoming.appendingPathComponent("shared.txt"))
        try write("new from other task\n", to: incoming.appendingPathComponent("新增 [file].txt"))
        try FileManager.default.moveItem(at: incoming.appendingPathComponent("renamed.txt"), to: incoming.appendingPathComponent("renamed-by-other.txt"))
        try FileManager.default.removeItem(at: incoming.appendingPathComponent("deleted.txt"))
        try await run(other, ["add", "-A"])
        try await run(other, ["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "Other task"])

        // A dirty file that predates the command is not its work either.
        try write("preexisting owner change\n", to: checkout.appendingPathComponent("already-dirty.txt"))
        let project = app.addProject(at: checkout)
        var chat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        chat.hasCustomTitle = true
        chat.hydraEnabled = false
        app.insertThread(chat)
        let runtime = app.runtime(for: chat.id)
        await runtime.ensureLoaded()
        let ref = Git.checkpointRef(thread: chat.id, turn: UUID(), phase: "start")
        let before = try await git.captureCheckpoint(ref)
        runtime.rehearseTurn("Generate a preview", baseCheckpoint: ref, baseSnapshot: before)
        let command = foreign ? "cd \(incoming.path) && swift /tmp/render.swift" : "swift /tmp/render.swift"
        runtime.rehearse(.toolStarted(id: name, call: ToolCall(kind: .command, title: command, toolName: "bash")))

        // A separate task fast-forwards this checkout while a preview command runs.
        // The foreign path has the same case in a second repository watched via cd.
        if foreign {
            // Let the foreign lookup take its committed baseline before advancing it.
            let baseline = try await other.headTree()
            try await Task.sleep(for: .milliseconds(100))
            try write("another incoming change\n", to: incoming.appendingPathComponent("shared.txt"))
            try await run(other, ["add", "-A"])
            try await run(other, ["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "Another task"])
            expect(try await other.headTree() != baseline, "Foreign HEAD really advanced")
        }
        try await run(git, ["merge", "--ff-only", "other-task"])
        if writes {
            try write("incoming\nours\n", to: checkout.appendingPathComponent("shared.txt"))
            try write("our new file\n", to: checkout.appendingPathComponent("ours.txt"))
        }
        runtime.rehearse(.toolUpdated(id: name, update: ToolUpdate(status: .completed)))
        runtime.rehearse(.turnCompleted(status: .completed, error: nil))
        try await wait { runtime.phase == .idle && runtime.turns.last?.status == .completed }
        let turn = runtime.turns.last!
        expect(turn.touchedPaths == (writes ? ["ours.txt", "shared.txt"] : []), "Only the current command's writes are persisted")
        let files = await runtime.parsedDiff(selection: turn.id)
        expect(files.map(\.path) == (writes ? ["ours.txt", "shared.txt"] : []), "Diff excludes incoming additions, removals, renames and preexisting dirt")
        let summary = runtime.entries.compactMap { entry -> TurnSummary? in
            if case .turnEnd(let summary) = entry.item.content { return summary }; return nil
        }.last!
        expect(runtime.reviewTurns().map(\.id) == (writes ? [turn.id] : []),
               "Review lists only turns with attributed files, excluding checkpoint-only and incoming-merge turns")
        expect(summary.filesChanged == (writes ? 2 : 0) && summary.additions == (writes ? 2 : 0) && summary.deletions == 0,
               "The turn card's counts exclude incoming lines even when this command edits the same file")
        await runtime.refreshChangeStats()
        expect(runtime.changeStats?.files.count == (writes ? 2 : nil), "The composer agrees with the turn card")

        runtime.saveNow()
        let reopened = ThreadRuntime(threadID: chat.id, app: app)
        await reopened.ensureLoaded()
        let finalHead = try await git.headTree()
        expect(reopened.turns.last?.baseSnapshot == before && reopened.turns.last?.endSnapshot?.head == finalHead,
               "Immutable HEAD boundaries survive persistence")
        let reopenedFiles = await reopened.parsedDiff(selection: turn.id)
        expect(reopenedFiles.map(\.path) == files.map(\.path), "Reopening never revives another task's files")
        if writes {
            let secondRef = Git.checkpointRef(thread: chat.id, turn: UUID(), phase: "start")
            let secondBase = try await git.captureCheckpoint(secondRef)
            runtime.rehearseTurn("Add another file", baseCheckpoint: secondRef, baseSnapshot: secondBase)
            try write("second turn\n", to: checkout.appendingPathComponent("second.txt"))
            runtime.rehearse(.toolStarted(id: "second-edit", call: ToolCall(kind: .edit, title: "edit", toolName: "edit", edits: [
                FileEdit(path: "second.txt", old: "", new: "second turn\n")
            ])))
            runtime.rehearse(.toolUpdated(id: "second-edit", update: ToolUpdate(status: .completed)))
            runtime.rehearse(.turnCompleted(status: .completed, error: nil))
            try await wait { runtime.phase == .idle && runtime.turns.last?.status == .completed }
            let second = runtime.turns.last!
            let allFiles = await runtime.parsedDiff(selection: nil)
            expect(allFiles.map(\.path) == ["ours.txt", "second.txt", "shared.txt"],
                   "All changes includes both turns while excluding incoming commits and preexisting dirt")
            expect(allFiles.allSatisfy { !$0.hunks.isEmpty }, "All changes retains patches from both turns")
            expect(await runtime.parsedDiff(selection: second.id).map(\.path) == ["second.txt"],
                   "Switching from all changes to one turn limits the diff to that turn")
        }
        reopened.cancelPersistence()
        runtime.cancelPersistence()
    }

    @MainActor private static func summary(in runtime: ThreadRuntime) -> TurnSummary {
        runtime.entries.compactMap { entry -> TurnSummary? in
            if case .turnEnd(let summary) = entry.item.content { return summary }
            return nil
        }.last!
    }

    @MainActor private static func checkWorktreeHistory(in root: URL, app: AppModel) async throws {
        let checkout = root.appendingPathComponent("worktree-history")
        let task = root.appendingPathComponent("task worktree 中文\ncopy")
        let sibling = root.appendingPathComponent("sibling-worktree")
        let unrelated = root.appendingPathComponent("unrelated-repository")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let git = Git(checkout.path)
        try await run(git, ["init", "-q", "--initial-branch=main"])
        try await run(Git(unrelated.path), ["init", "-q", "--initial-branch=main"])
        for path in ["main.txt", "worktree.txt", "deleted.txt"] {
            try write("before\n", to: checkout.appendingPathComponent(path))
        }
        try await run(git, ["add", "."])
        try await run(git, ["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "Baseline"])
        try await run(git, ["worktree", "add", "-q", "-b", "task", task.path])
        try await run(git, ["worktree", "add", "-q", "-b", "sibling", sibling.path])
        expect(Set(try await git.worktreeRoots()) == Set([checkout.path, task.path, sibling.path]),
               "Git worktree identity preserves spaces, newlines and Unicode")
        let project = app.addProject(at: checkout)
        var chat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        chat.hasCustomTitle = true
        chat.hydraEnabled = false
        app.insertThread(chat)
        let runtime = app.runtime(for: chat.id)
        await runtime.ensureLoaded()
        let ref = Git.checkpointRef(thread: chat.id, turn: UUID(), phase: "start")
        let before = try await git.captureCheckpoint(ref)
        runtime.rehearseTurn("Edit in a task worktree", baseCheckpoint: ref, baseSnapshot: before)
        try write("before\nours\n", to: checkout.appendingPathComponent("main.txt"))
        try write("before\nours\n", to: task.appendingPathComponent("worktree.txt"))
        try write("new\n", to: task.appendingPathComponent("新增 [file].txt"))
        try FileManager.default.removeItem(at: task.appendingPathComponent("deleted.txt"))
        let edits = [
            FileEdit(path: "main.txt", old: "before\n", new: "before\nours\n"),
            FileEdit(path: task.appendingPathComponent("worktree.txt").path, old: "before\n", new: "before\nours\n"),
            FileEdit(path: task.appendingPathComponent("新增 [file].txt").path,
                     diff: "@@ -0,0 +1 @@\n+new", additions: 1, deletions: 0),
            FileEdit(path: task.appendingPathComponent("deleted.txt").path,
                     diff: "@@ -1 +0,0 @@\n-before", additions: 0, deletions: 1),
            FileEdit(path: unrelated.appendingPathComponent("worktree.txt").path, old: "", new: "unrelated\n"),
            FileEdit(path: root.appendingPathComponent("notes/memory.txt").path, old: "", new: "private note\n"),
        ]
        runtime.rehearse(.toolStarted(id: "native-edits", call: ToolCall(kind: .edit, title: "edit", toolName: "edit", edits: edits)))
        runtime.rehearse(.toolUpdated(id: "native-edits", update: ToolUpdate(status: .completed)))
        let other = Git(task.path)
        try await run(other, ["add", "-A"])
        try await run(other, ["-c", "user.name=Fixture", "-c", "user.email=fixture@localhost", "commit", "-qm", "Task edits"])
        try await run(git, ["merge", "--ff-only", "task"])
        // Other writes in both linked checkouts have no edit record in this chat.
        try write("unreported\n", to: task.appendingPathComponent("unreported.txt"))
        try write("another task\n", to: sibling.appendingPathComponent("another-task.txt"))
        runtime.rehearse(.turnCompleted(status: .completed, error: nil))
        try await wait { runtime.phase == .idle && runtime.turns.last?.status == .completed }
        let turn = runtime.turns.last!
        let expected = Array(edits.prefix(4).map(\.path)).sorted()
        let files = await runtime.parsedDiff(selection: turn.id)
        expect(files.map(\.path) == expected, "Only this chat's explicit edits enter the diff, including its linked worktree")
        expect(files.allSatisfy { !$0.hunks.isEmpty }, "Worktree edits retain their saved patches after commit and fast-forward")
        expect(turn.touchedPaths == ["main.txt"], "External worktree paths never enter checkout restore or merge ownership")
        let current = summary(in: runtime)
        expect(current.filesChanged == 4 && current.additions == 3 && current.deletions == 1,
               "The completed card counts local and worktree edits once")
        expect(current.fileAttributionVersion == TurnSummary.currentFileAttributionVersion, "New summaries carry the corrected attribution version")
        await runtime.refreshChangeStats()
        expect(runtime.changeStats?.files.map(\.path) == expected, "Composer statistics agree with the completed worktree card")

        // Reproduce the persisted zero-file summary from the reported conversation.
        let ending = runtime.entries.last(where: { $0.kind == .turnEnd })!
        var old = current
        old.changes = FileChangeSummary(files: [])
        old.filesChanged = 0
        old.additions = 0
        old.deletions = 0
        old.fileAttributionVersion = nil
        ending.item.content = .turnEnd(old)
        runtime.saveNow()
        let reopened = ThreadRuntime(threadID: chat.id, app: app)
        await reopened.ensureLoaded()
        expect(summary(in: reopened).changes?.files.isEmpty == true, "Fixture reopens the old explicit empty summary")
        let repaired = await reopened.refreshTurnChanges(turnID: turn.id)
        expect(repaired?.files.map(\.path) == expected, "Visible historical cards replace stale empty summaries")
        let migrated = summary(in: reopened)
        expect(migrated == current, "Migration repairs every saved count and version without changing turn metadata")
        await reopened.refreshChangeStats()
        expect(reopened.changeStats == repaired, "An existing conversation's composer agrees with its migrated card")
        reopened.saveNow()
        let reloaded = ThreadRuntime(threadID: chat.id, app: app)
        await reloaded.ensureLoaded()
        expect(summary(in: reloaded) == migrated, "Corrected historical summaries survive another reopen")
        expect(await reloaded.refreshTurnChanges(turnID: turn.id) == repaired, "Reopening reuses a current summary")
        expect(!reloaded.hasCachedDiff(selection: turn.id), "Current summaries require no historical Git or diff replay")

        // A summary-only imported archive must not lose known files during migration.
        let archive = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(archive)
        var archivedTurn = turn
        archivedTurn.touchedPaths = []
        var archivedSummary = current
        archivedSummary.fileAttributionVersion = nil
        var document = ThreadDocument(threadID: archive.id)
        document.turns = [archivedTurn]
        document.items = [TimelineItem(turnID: turn.id, content: .turnEnd(archivedSummary))]
        try JSONEncoder.storage.encode(document).write(to: Storage.threadURL(archive.id), options: .atomic)
        let summaryOnly = ThreadRuntime(threadID: archive.id, app: app)
        await summaryOnly.ensureLoaded()
        expect(await summaryOnly.refreshTurnChanges(turnID: turn.id) == current.changes,
               "An archive without edit records retains its saved files and totals")
        expect(!summaryOnly.hasCachedDiff(selection: turn.id), "Summary-only history never infers edits from the checkout")
        expect(summaryOnly.reviewTurns().map(\.id) == [turn.id], "Review retains a summary-only historical turn")
        let archiveReview = await summaryOnly.reviewFiles(turnID: turn.id)
        expect(FileChangeSummary(files: archiveReview) == current.changes,
               "Review preserves every saved file and count when patches are unavailable")
        expect(archiveReview.allSatisfy { $0.hunks.isEmpty && !$0.isDeferred },
               "Summary-only review never fabricates patch content")
        summaryOnly.cancelPersistence()
        reloaded.cancelPersistence()
        reopened.cancelPersistence()
        runtime.cancelPersistence()
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let root = CaptureRun.storageRoot,
              root.path.contains("/build.noindex/verification/runs/") else { fatalError("Require isolated storage") }
        expect(Storage.root == root, "Never use the owner's app data")
        try FileManager.default.createDirectory(at: Storage.threadsDirectory, withIntermediateDirectories: true)
        _ = NSApplication.shared // No application entry point or windows.
        let app = AppModel()
        app.settings.notifyWhenFinished = false
        app.settings.chimeWhenFinished = false
        try await checkMerge(in: root, app: app, writes: false, foreign: false)
        try await checkMerge(in: root, app: app, writes: true, foreign: false)
        try await checkMerge(in: root, app: app, writes: false, foreign: true)
        try await checkWorktreeHistory(in: root, app: app)
        let git = Git(root.appendingPathComponent("merge-only").path)
        let snapshot = try await git.captureSnapshot()
        expect(try await git.attributionBase(from: CheckoutSnapshot(tree: snapshot.tree, head: nil), to: snapshot) == nil,
               "Unknown HEAD never falls back to a whole-checkout attribution")
        let legacy = try JSONDecoder().decode(TurnRecord.self, from: Data("{\"id\":\"\(UUID())\",\"index\":0,\"startedAt\":0,\"status\":\"completed\",\"hydraMerged\":false}".utf8))
        expect(legacy.baseSnapshot == nil && legacy.endSnapshot == nil, "Older records still decode without fabricated HEAD evidence")
        print("File attribution checks passed: \(checks)")
    }
}
