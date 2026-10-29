import AppKit
import SwiftUI
@testable import OMPGUI

private actor CommitGate {
    private(set) var entered = false
    private var reply: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { reply = $0 } }
    func release() { reply?.resume(); reply = nil }
}

@main private enum GitCommitChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message); checks += 1
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func command(_ git: Git, _ args: [String]) async throws -> String {
        let result = try await git.run(args, timeout: 15)
        try Git.check(result)
        return result.trimmedOutput
    }

    private static func write(_ text: String, _ root: URL, _ path: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private static func repository(_ root: URL) async throws -> GitRepositoryLocation {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = Git(root.path)
        _ = try await command(git, ["init", "--quiet", "--initial-branch=main"])
        for (key, value) in [("user.name", "Commit fixture"), ("user.email", "commit@localhost"),
                             ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
                             ("core.autocrlf", "false"), ("core.attributesfile", "/dev/null")] {
            _ = try await command(git, ["config", key, value])
        }
        return try await GitWorkspaceReader.locate(root.path)!
    }

    @MainActor private static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private static func reject(_ operation: () async throws -> Void,
                                         matching matches: (any Error) -> Bool, _ message: String) async {
        do { try await operation(); preconditionFailure(message) }
        catch { expect(matches(error), message + ": " + error.localizedDescription) }
    }

    private static func hook(_ location: GitRepositoryLocation, _ name: String, _ body: String) async throws {
        let hooks = location.gitDirectory.appendingPathComponent("commit-fixture-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let file = hooks.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        _ = try await command(Git(location.root.path), ["config", "core.hooksPath", hooks.path])
    }

    @MainActor private static func exactScope(_ root: URL) async throws -> GitRepositoryLocation {
        let location = try await repository(root)
        let canonical = try await GitWorkspaceReader.locate(location.root.path)
        expect(canonical == location, "A filesystem alias must resolve to exactly the same worktree and index identity")
        let git = Git(root.path)
        let literal = ":(glob)* [中文]\nfile.txt"
        try write("base\n", root, literal)
        try write("other base\n", root, "other.txt")
        try write("rename base\n", root, "old.txt")
        _ = try await command(git, ["add", "--all"])
        _ = try await command(git, ["commit", "--quiet", "-m", "Base"])
        try write("only staged text\n", root, literal)
        try write("other unstaged text\n", root, "other.txt")
        try write("untracked stays outside\n", root, "new.txt")
        var status = try await GitWorkspaceReader.status(location)
        let stale = status.revision!
        try await GitWorkspaceWriter.stage(location, stale, [status.files.first { $0.path == literal }!], false)
        try write("later working text\n", root, literal)
        status = try await GitWorkspaceReader.status(location)
        expect(status.files.filter { $0.path == literal }.count == 2, "Partial staging must retain both comparisons")
        let patch = try await GitWorkspaceWriter.patch(location, status.revision!)
        expect(patch.contains("only staged text") && !patch.contains("later working text") && !patch.contains("other unstaged text"),
               "Generation input must use only staged contents")
        let receipt = try await GitWorkspaceWriter.commit(location, status.revision!, "保留范围\n\nA literal staged-only commit")
        let committed = try await command(git, ["show", receipt.id + ":" + literal])
        let other = try await command(git, ["show", receipt.id + ":other.txt"])
        let files = try await command(git, ["diff-tree", "--no-commit-id", "--name-only", "-r", "-z", receipt.id])
        expect(committed == "only staged text" && other == "other base", "Commit must exclude later working edits and other files")
        expect(files == literal + "\0", "Pathspec-like, Unicode and newline names must remain one literal path")
        expect(try String(contentsOf: root.appendingPathComponent(literal), encoding: .utf8) == "later working text\n",
               "Committing must never overwrite working content")
        status = try await GitWorkspaceReader.status(location)
        expect(!status.files.contains { $0.side == .index } && status.files.contains { $0.path == "new.txt" && $0.side == .untracked },
               "Success must leave unstaged and untracked work intact")

        // A staged rename must unstage both paths without moving either file.
        try FileManager.default.moveItem(at: root.appendingPathComponent("old.txt"), to: root.appendingPathComponent("renamed.txt"))
        status = try await GitWorkspaceReader.status(location)
        try await GitWorkspaceWriter.stage(location, status.revision!, status.files.filter { ["old.txt", "renamed.txt"].contains($0.path) }, false)
        status = try await GitWorkspaceReader.status(location)
        let rename = status.files.first { $0.path == "renamed.txt" && $0.side == .index }!
        expect(rename.status == "R" && rename.oldPath == "old.txt", "Staged renames must retain the original path")
        try await GitWorkspaceWriter.stage(location, status.revision!, [rename], true)
        status = try await GitWorkspaceReader.status(location)
        expect(!status.files.contains { $0.side == .index } && !FileManager.default.fileExists(atPath: root.appendingPathComponent("old.txt").path)
               && FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path), "Unstaging renames must change only the index")

        try Data([0, 1, 255, 0, 12]).write(to: root.appendingPathComponent("binary.bin"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "other.txt")
        status = try await GitWorkspaceReader.status(location)
        try await GitWorkspaceWriter.stage(location, status.revision!, status.files.filter { $0.side == .working || $0.side == .untracked }, false)
        status = try await GitWorkspaceReader.status(location)
        expect(status.files.allSatisfy { $0.side == .index }, "Explicit Stage all must include deletions, binaries and symlinks")
        let link = try await command(git, ["ls-files", "--stage", "--", "link"])
        expect(link.hasPrefix("120000 "), "Staging a symlink must preserve the link rather than stage its target")
        try await GitWorkspaceWriter.stage(location, status.revision!, status.files, true)
        status = try await GitWorkspaceReader.status(location)
        expect(!status.files.contains { $0.side == .index }, "Explicit Unstage all must preserve working files")

        // An external index change must fail before touching the newer index.
        let oldRevision = status.revision!
        _ = try await command(git, ["add", "--", "other.txt"])
        let changedIndex = try Data(contentsOf: location.indexFile)
        await reject({ try await GitWorkspaceWriter.stage(location, oldRevision, [status.files.first { $0.path == "new.txt" }!], false) },
                     matching: { if case GitWriteError.changed = $0 { true } else { false } }, "Stale staging must be rejected")
        expect(try Data(contentsOf: location.indexFile) == changedIndex, "A stale action must not undo external staging")
        status = try await GitWorkspaceReader.status(location)
        let lock = URL(fileURLWithPath: location.indexFile.path + ".lock")
        try Data("owned elsewhere".utf8).write(to: lock)
        await reject({ _ = try await GitWorkspaceWriter.commit(location, status.revision!, "Locked") },
                     matching: { if case GitWriteError.busy = $0 { true } else { false } }, "A real Git lock must exclude commits")
        expect(try String(contentsOf: lock, encoding: .utf8) == "owned elsewhere", "Never delete another writer's lock")
        try FileManager.default.removeItem(at: lock)
        let beforeBranch = status.revision!
        _ = try await command(git, ["switch", "--quiet", "-c", "same-tree"])
        await reject({ _ = try await GitWorkspaceWriter.commit(location, beforeBranch, "Wrong branch") },
                     matching: { if case GitWriteError.changed = $0 { true } else { false } }, "A branch switch at the same commit must invalidate the review")
        status = try await GitWorkspaceReader.status(location)
        for text in ["", "bad\0message", String(repeating: "x", count: 65_537)] {
            await reject({ _ = try await GitWorkspaceWriter.commit(location, status.revision!, text) },
                         matching: { if case GitWriteError.invalidMessage = $0 { true } else { false } }, "Invalid messages must not reach Git")
        }
        try write(status.head! + "\n", location.gitDirectory, "MERGE_HEAD")
        await reject({ _ = try await GitWorkspaceWriter.commit(location, status.revision!, "Ongoing merge") },
                     matching: { if case GitWriteError.operation = $0 { true } else { false } }, "An ongoing operation must not be continued implicitly")
        try FileManager.default.removeItem(at: location.gitDirectory.appendingPathComponent("MERGE_HEAD"))
        return location
    }

    @MainActor private static func unbornAndLinked(_ root: URL) async throws {
        let location = try await repository(root.appendingPathComponent("unborn"))
        let git = Git(location.root.path)
        try write("first staged\n", location.root, "first.txt")
        var status = try await GitWorkspaceReader.status(location)
        try await GitWorkspaceWriter.stage(location, status.revision!, status.files, false)
        status = try await GitWorkspaceReader.status(location)
        try write("first working\n", location.root, "first.txt")
        try await GitWorkspaceWriter.stage(location, status.revision!, status.files.filter { $0.side == .index }, true)
        status = try await GitWorkspaceReader.status(location)
        expect(status.head == nil && status.files.first?.side == .untracked, "Unborn unstaging must remove only index entries")
        try await GitWorkspaceWriter.stage(location, status.revision!, status.files, false)
        status = try await GitWorkspaceReader.status(location)
        let first = try await GitWorkspaceWriter.commit(location, status.revision!, "First commit")
        let parents = try await command(git, ["show", "--no-patch", "--format=%P", first.id])
        expect(parents.isEmpty, "The first commit must have no invented parent")
        let mainIndex = try Data(contentsOf: location.indexFile)
        let linkedRoot = root.appendingPathComponent("linked")
        _ = try await command(git, ["worktree", "add", "--quiet", "-b", "linked-branch", linkedRoot.path])
        let linked = try await GitWorkspaceReader.locate(linkedRoot.path)!
        try write(first.id + "\n", location.gitDirectory, "MERGE_HEAD")
        try write("linked only\n", linked.root, "first.txt")
        status = try await GitWorkspaceReader.status(linked)
        expect(status.operations.isEmpty, "A linked worktree must not borrow the primary operation marker")
        try await GitWorkspaceWriter.stage(linked, status.revision!, status.files, false)
        status = try await GitWorkspaceReader.status(linked)
        let receipt = try await GitWorkspaceWriter.commit(linked, status.revision!, "Linked only")
        let mainHead = try await command(git, ["rev-parse", "HEAD"])
        let currentMainIndex = try Data(contentsOf: location.indexFile)
        expect(receipt.id != first.id && mainHead == first.id && currentMainIndex == mainIndex,
               "A linked commit must update only its own HEAD and index")
        try FileManager.default.removeItem(at: location.gitDirectory.appendingPathComponent("MERGE_HEAD"))

        let backup = location.gitDirectory.appendingPathComponent("index-backup")
        try FileManager.default.moveItem(at: location.indexFile, to: backup)
        try FileManager.default.createSymbolicLink(at: location.indexFile, withDestinationURL: backup)
        status = try await GitWorkspaceReader.status(location)
        expect(status.revision == nil, "A symlink index may be browsed but must never authorize writes")
        try FileManager.default.removeItem(at: location.indexFile)
        try FileManager.default.moveItem(at: backup, to: location.indexFile)

        try write("reviewed change\n", location.root, "first.txt")
        status = try await GitWorkspaceReader.status(location)
        try await GitWorkspaceWriter.stage(location, status.revision!, status.files, false)
        status = try await GitWorkspaceReader.status(location)
        try await hook(location, "pre-commit", "printf 'hook-added content\\n' > hook-added.txt\ngit add -- hook-added.txt")
        await reject({ _ = try await GitWorkspaceWriter.commit(location, status.revision!, "Hook expands scope") },
                     matching: { if case GitWriteError.committed = $0 { true } else { false } },
                     "A native hook-expanded commit must be identified as already committed and require inspection")
        let hookContents = try await command(git, ["show", "HEAD:hook-added.txt"])
        status = try await GitWorkspaceReader.status(location)
        expect(hookContents == "hook-added content" && !status.files.contains { $0.side == .index },
               "The native hook result must be preserved without creating a reverse staged change")
    }

    @MainActor private static func hooksAndRaces(_ location: GitRepositoryLocation) async throws {
        let git = Git(location.root.path)
        var status = try await GitWorkspaceReader.status(location)
        let oldHead = status.head!
        let original = try Data(contentsOf: location.indexFile)
        try await hook(location, "pre-commit", "echo 'Fixture rejects commit' >&2\nexit 1")
        await reject({ _ = try await GitWorkspaceWriter.commit(location, status.revision!, "Keep draft") },
                     matching: { $0 is ShellError }, "Native pre-commit rejection must propagate")
        let unchanged = try await command(git, ["rev-parse", "HEAD"])
        let unchangedIndex = try Data(contentsOf: location.indexFile)
        expect(unchanged == oldHead && unchangedIndex == original,
               "A hook rejection must leave HEAD and the real index unchanged")
        try await hook(location, "pre-commit", """
        gitdir=$(git rev-parse --absolute-git-dir) || exit 1
        : > "$gitdir/commit-entered"
        while [ ! -f "$gitdir/commit-release" ]; do /bin/sleep 0.02; done
        """)
        let expected = status.revision!
        let pending = Task { try await GitWorkspaceWriter.commit(location, expected, "Serialized commit") }
        try await eventually("The native hook must hold the submitted commit") { FileManager.default.fileExists(atPath: location.gitDirectory.appendingPathComponent("commit-entered").path) }
        let external = try await git.run(["add", "--", "new.txt"], timeout: 10)
        expect(!external.succeeded && external.errorOutput.contains("index.lock"), "A concurrent external Git add must not enter the commit")
        await reject({ try await GitWorkspaceWriter.stage(location, expected, status.files.filter { $0.side == .index }, true) },
                     matching: { if case GitWriteError.busy = $0 { true } else { false } }, "Two GUI stores must share mutation admission")
        try write("release", location.gitDirectory, "commit-release")
        let receipt = try await pending.value
        expect(receipt.id != oldHead, "The admitted commit must finish once its hook returns")
        _ = try await command(git, ["config", "core.hooksPath", "/dev/null"])
        try write("another staged edit\n", location.root, "other.txt")
        status = try await GitWorkspaceReader.status(location)
        try await GitWorkspaceWriter.stage(location, status.revision!, [status.files.first { $0.path == "other.txt" }!], false)
        status = try await GitWorkspaceReader.status(location)
        // Native Git may advance HEAD and then die while running post-commit.
        try await hook(location, "pre-commit", "exit 0")
        try await hook(location, "post-commit", "kill -TERM \"$PPID\"")
        let confirmed = try await GitWorkspaceWriter.commit(location, status.revision!, "Confirmed after post-commit exit")
        let head = try await command(git, ["rev-parse", "HEAD"])
        expect(confirmed.id == head, "A proven commit must not become a false failure after HEAD was advanced")
        _ = try await command(git, ["config", "core.hooksPath", "/dev/null"])
    }

    @MainActor private static func storeAndLayout(_ location: GitRepositoryLocation, _ output: URL) async throws {
        let git = Git(location.root.path)
        try write("draft fixture staged\n", location.root, "other.txt")
        var status = try await GitWorkspaceReader.status(location)
        try await GitWorkspaceWriter.stage(location, status.revision!, [status.files.first { $0.path == "other.txt" }!], false)
        let navigation = GitBrowseNavigation()
        let state = GitWorkspaceStore(navigation: navigation, watchFactory: { _, _ in nil })
        let context = FilePreviewContext(threadID: UUID(), workingDirectory: location.root.path)
        state.present(context)
        defer { state.suspend() }
        try await eventually("Store must read staged review") { state.status != nil && !state.isLoading }
        state.openCommitComposer(); state.commitMessage = "Keep this exact draft"
        expect(state.canSubmitCommit, "A current staged review and message must allow submission")
        state.submitCommit(allowed: { false })
        expect(!state.isWriting && state.commitMessage == "Keep this exact draft", "OMP activity must block a write without consuming the draft")
        try await hook(location, "pre-commit", "exit 1")
        state.submitCommit()
        try await eventually("Rejected native commit must finish") { !state.isWriting && navigation.writeError != nil }
        expect(state.commitMessage == "Keep this exact draft" && !navigation.needsCommitInspection,
               "A definite native failure must keep the draft and remain safely retryable")
        state.back(); state.openCommitComposer()
        expect(state.commitMessage == "Keep this exact draft", "Back and reopen must retain the same draft")
        _ = try await command(git, ["config", "core.hooksPath", "/dev/null"])
        try await eventually("Failure refresh must finish") { !state.isLoading }

        let gate = CommitGate()
        state.generateMessage { _, _, _ in await gate.hold(); return "late generated message" }
        try await eventually("Generation must use explicit action") { await gate.entered }
        state.commitMessage = "Typed while generating"
        await gate.release()
        try await eventually("Generation must finish") { !state.isGeneratingMessage }
        expect(state.commitMessage == "Typed while generating", "A late generated reply must never overwrite typed edits")
        _ = try await command(git, ["add", "--", "new.txt"])
        state.refresh()
        try await eventually("External staged changes must be observed") { !state.isLoading }
        expect(!state.reviewIsCurrent && !state.canSubmitCommit, "An updated index must require an explicit review refresh")
        state.refreshReview()
        try await eventually("Explicit refresh must accept a new review") { !state.isLoading && state.reviewIsCurrent }

        _ = NSApplication.shared
        let previews = FilePreviewStore(persistenceURL: output.appendingPathComponent("commit-layout.json"))
        previews.setContext(context); previews.openPanel(.git)
        let session = previews.session!
        let rendered = GitWorkspaceStore(navigation: session.gitNavigation, watchFactory: { _, _ in nil })
        let model = AppModel()
        let project = model.addProject(at: location.root)
        let otherChat = model.newThread(in: project, workspace: .local)!
        let otherRuntime = model.runtime(for: otherChat.id)
        otherRuntime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, settled: false, pendingAsyncWork: true)))
        expect(model.hasActiveGitTask(in: location), "A different chat's native background work in this worktree must block Git writes")
        otherRuntime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true)))
        expect(model.hasActiveGitTask(in: location), "Unknown native quiescence must not authorize a Git write")
        otherRuntime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, settled: true)))
        expect(!model.hasActiveGitTask(in: location), "A proven idle connected CLI must not prevent local commits")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let resize = WindowLiveResize(window: window)
        let host = FrameHostingView(rootView: AnyView(GitWorkspacePane(previews: previews, session: session, state: rendered)
            .modifier(HostedEnvironment(model: model, liveResize: resize, previews: previews))))
        window.contentView = host
        defer { rendered.suspend(); previews.suspend(); window.contentView = nil; window.close() }
        try await eventually("Production page must load for layout") { host.layoutSubtreeIfNeeded(); return rendered.status != nil && !rendered.isLoading }
        rendered.openCommitComposer()
        let emptyMessageGate = CommitGate()
        rendered.generateMessage { _, _, _ in await emptyMessageGate.hold(); return "Generated from the reviewed index" }
        try await eventually("Empty-message generation must enter its backend") { await emptyMessageGate.entered }
        try await eventually("Generation progress must reach the native placeholder") {
            host.layoutSubtreeIfNeeded()
            return descendants(host).compactMap { $0 as? NSTextView }.contains {
                $0.accessibilityPlaceholderValue() == Chrome.localized("Writing a message…")
            }
        }
        let emptyEditor = descendants(host).compactMap { $0 as? NSTextView }.first!
        expect(emptyEditor.string.isEmpty && emptyEditor.textStorage?.length == 0 && rendered.commitMessage.isEmpty
               && !rendered.canSubmitCommit && emptyEditor.bounds.width > 100 && emptyEditor.bounds.height > 20,
               "A visible native placeholder must not become editable, staged or submitted message text")
        await emptyMessageGate.release()
        try await eventually("A generated message must replace only the placeholder") {
            host.layoutSubtreeIfNeeded()
            return !rendered.isGeneratingMessage && emptyEditor.string == "Generated from the reviewed index"
                && emptyEditor.accessibilityPlaceholderValue() == nil
        }
        expect(rendered.commitMessage == emptyEditor.string, "The actual generated content must reach the retained draft")
        rendered.commitMessage = "Commit only the reviewed staged contents\n\n保留部分暂存与工作区内容。"
        expect(NSImage(systemSymbolName: "light.beacon.max", accessibilityDescription: nil) != nil,
               "The requested message-generation symbol must exist on the supported native system")
        for width in [260, 360, 480] {
            window.setContentSize(NSSize(width: width, height: 700)); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            let editors = descendants(host).compactMap { $0 as? NSTextView }
            expect(editors.contains { $0.string == rendered.commitMessage }, "The actual native editor must display the retained commit message")
            let editor = editors.first { $0.string == rendered.commitMessage }!
            expect(!editor.drawsBackground && editor.enclosingScrollView?.drawsBackground == false
                   && editor.bounds.width > 100 && editor.bounds.height > 20 && editor.bounds.height < 10_000,
                   "The native message field must retain transparent surfaces and a real narrow text viewport")
            func visualFrame(_ view: NSView) -> NSRect {
                var frame = view.convert(view.bounds, to: host)
                if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
                return frame
            }
            let textFrame = visualFrame(editor.enclosingScrollView!)
            let controls = descendants(host).compactMap { $0 as? NoWindowDragView }.map(visualFrame)
            expect(controls.contains { abs($0.maxX - textFrame.maxX) < 1 && $0.height >= 28
                && $0.minY >= textFrame.maxY && $0.maxY <= textFrame.maxY + 40 },
                   "The generator must have a separate bottom-right hit target below the native text viewport")
            // Diagnostic capture only: an unshown mixed AppKit/SwiftUI host may
            // omit composited layers. Native field assertions above are the
            // acceptance evidence; these PNGs cannot certify visible visuals.
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("git-commit-\(width).png"))
            expect(!window.isVisible && host.bounds.width == CGFloat(width), "Commit layout must fit an unshown narrow viewport")
        }
        rendered.openFile(rendered.commitReview!.files[0])
        try await eventually("Staged file review must drill into the exact index diff") { rendered.diff != nil && !rendered.isSelectionLoading }
        rendered.back()
        expect(rendered.route == .compose && !rendered.commitMessage.isEmpty, "Returning from a staged file must retain the composer and message")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let native = descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == rendered.commitMessage }!
        native.setSelectedRange(NSRange(location: 7, length: 4))
        let draftMessageGate = CommitGate()
        rendered.generateMessage { _, _, _ in await draftMessageGate.hold(); return "Do not replace a typed draft" }
        try await eventually("Draft generation must update only the native placeholder") {
            host.layoutSubtreeIfNeeded()
            return await draftMessageGate.entered
                && native.accessibilityPlaceholderValue() == Chrome.localized("Writing a message…")
        }
        expect(native.string == rendered.commitMessage && native.selectedRange() == NSRange(location: 7, length: 4)
               && native.isEditable, "Generating with a retained draft must preserve its text, selection and editing")
        native.string = "Native typing 中文 🧭"
        native.didChangeText()
        expect(rendered.commitMessage == "Native typing 中文 🧭", "Native edits must update the retained message without losing Unicode")
        await draftMessageGate.release()
        try await eventually("Native draft generation must finish without retaining its placeholder") {
            host.layoutSubtreeIfNeeded()
            return !rendered.isGeneratingMessage && native.accessibilityPlaceholderValue() == nil
        }
        expect(native.string == "Native typing 中文 🧭" && rendered.commitMessage == native.string,
               "A late generated result must preserve native edits while removing its progress placeholder")
        state.submitCommit()
        try await eventually("Confirmed commit must clear only the submitted message") { !state.isWriting && navigation.lastCommit != nil }
        expect(state.commitMessage.isEmpty && navigation.writeError == nil, "Only proven success may clear the submitted draft")

        // A submitted write belongs to the session, even after the old page is hidden.
        status = try await GitWorkspaceReader.status(location)
        try write("hidden write fixture\n", location.root, "other.txt")
        try await GitWorkspaceWriter.stage(location, status.revision!, [GitBrowseFile(path: "other.txt", status: "M", side: .working)], false)
        let writeGate = CommitGate()
        var writer = GitWorkspaceWriting.live
        writer.commit = { _, _, _, _ in await writeGate.hold(); return .init(id: String(repeating: "b", count: 40)) }
        let retained = GitBrowseNavigation()
        let hidden = GitWorkspaceStore(navigation: retained, writer: writer, watchFactory: { _, _ in nil })
        hidden.present(context)
        try await eventually("Hidden lifecycle fixture must load") { hidden.status != nil && !hidden.isLoading }
        hidden.openCommitComposer(); hidden.commitMessage = "Finish after hiding"
        hidden.submitCommit()
        try await eventually("Submitted write must enter its backend") { await writeGate.entered }
        hidden.suspend()
        expect(retained.isWriting, "Hiding must not cancel a submitted commit or pretend rollback")
        await writeGate.release()
        try await eventually("Hidden write must record its final outcome") { !retained.isWriting }
        expect(retained.commitMessage.isEmpty && retained.lastCommit != nil, "Hidden completion must remain attached to its originating session")

        var uncertainWriter = GitWorkspaceWriting.live
        uncertainWriter.commit = { _, _, _, _ in throw GitWriteError.uncertain }
        let uncertain = GitWorkspaceStore(writer: uncertainWriter, watchFactory: { _, _ in nil })
        uncertain.present(context)
        defer { uncertain.suspend() }
        try await eventually("Uncertain outcome fixture must load") { uncertain.status != nil && !uncertain.isLoading }
        uncertain.openCommitComposer(); uncertain.commitMessage = "Do not retry an unknown result"
        uncertain.navigation.lastCommit = .init(id: String(repeating: "b", count: 40))
        uncertain.submitCommit()
        try await eventually("Uncertain outcome must be recorded") { !uncertain.isWriting && uncertain.navigation.needsCommitInspection }
        expect(uncertain.commitMessage == "Do not retry an unknown result" && uncertain.navigation.lastCommit == nil && !uncertain.canSubmitCommit,
               "An unknown new result must retain the draft and must not reuse an older commit receipt")
        uncertain.inspectCommitResult()
        expect(uncertain.route == uncertain.status?.head.map(GitBrowseRoute.commit), "Inspection must open the actual current commit rather than a stale receipt")
    }

    @MainActor static func main() async throws {
        guard let output = CaptureRun.outputDirectory else { fatalError("Isolated capture storage required") }
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("omp-git-commit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let location = try await exactScope(fixtures.appendingPathComponent("repo 中文\nsource"))
        try await unbornAndLinked(fixtures)
        try await hooksAndRaces(location)
        try await storeAndLayout(location, output)
        print("Git commit checks passed: \(checks) assertions")
    }
}
