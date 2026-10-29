import Foundation
import AppKit
import SwiftUI
@testable import OMPGUI

@MainActor private final class ViewportChanges {
    var count = 0
}

@main
struct MemoryConnectionChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(root.path.contains("/build.noindex/verification/runs/") && CaptureRun.isEnabled)
        let defaults = CaptureRun.defaults!
        defaults.removePersistentDomain(forName: CaptureRun.suiteName)
        defer { defaults.removePersistentDomain(forName: CaptureRun.suiteName) }
        try await checkFilePreviews(root)
        await checkFileCache(root)
        try await checkUnsentTaskInspection(root)
        precondition(!OMPMemoryConfiguration().enabled)
        for status in [0, 17] {
            let marker = root.appendingPathComponent("saved-\(status)")
            let rpc = OMPRPC()
            let script = """
            import sys,json,pathlib
            assert json.loads(pathlib.Path(sys.argv[4]).read_text()) == {'memory':{'backend':'off'}}
            print(json.dumps({'ready':True}),flush=True)
            for line in sys.stdin: pass
            pathlib.Path(sys.argv[1]).write_text('native disposal finished')
            sys.exit(int(sys.argv[2]))
            """
            try rpc.start(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script, marker.path, String(status)], directory: root,
                environment: ProcessInfo.processInfo.environment)
            var succeeded = false
            do { try await rpc.drainAndWait(); succeeded = true } catch { precondition(status != 0) }
            precondition(succeeded == (status == 0), "A failing native disposal must fail the setting transition")
            precondition(!rpc.isRunning && FileManager.default.fileExists(atPath: marker.path),
                "A setting change must wait for actual process exit and native saving")
        }
        let interrupted = OMPRPC()
        try interrupted.start(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys,time; sys.stdin.read(); time.sleep(1)"], directory: root,
            environment: ProcessInfo.processInfo.environment)
        let closing = Task { try await interrupted.drainAndWait() }
        while !interrupted.isDraining { await Task.yield() }
        interrupted.stop()
        do { try await closing.value; preconditionFailure("An interrupted drain cannot commit new memory settings") }
        catch { }
        print("PASS memory connection transition: default off, EOF saving, failing disposal and explicit interruption")
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func checkUnsentTaskInspection(_ root: URL) async throws {
        let app = AppModel()
        let binary = app.settings.binaryPath(for: .omp)
        let configuration = app.settings.ompMemory
        defer {
            app.settings.setBinaryPath(binary, for: .omp)
            app.settings.ompMemory = configuration
        }
        // Stop at the SDK capability gate: never use an installed OMP or native profile.
        app.settings.setBinaryPath("/usr/bin/false", for: .omp)
        app.settings.ompMemory.enabled = true
        try FileManager.default.createDirectory(at: Storage.root, withIntermediateDirectories: true)
        try JSONEncoder.storage.encode(Library()).write(to: Storage.libraryURL)
        await app.bootstrap()
        let task = app.newThread(affiliation: .standalone)!
        let directory = app.executionProject(for: task)!.path
        precondition(!FileManager.default.fileExists(atPath: directory), "An unsent task has no workspace before an explicit native operation")
        let runtime = app.runtime(for: task.id)
        await runtime.ensureLoaded()
        runtime.draft = ComposerDraft(text: "Keep the unsent task draft")
        await app.loadMemoryFiles()
        precondition(FileManager.default.fileExists(atPath: directory),
                     "Global memory discovery prepares an unsent task's directory before launching its native connection")
        precondition(app.memoryFiles.error?.contains("Mnemopi SDK") == true,
                     "An independent task reaches the native SDK gate rather than a missing workspace error")
        precondition(app.thread(task.id)?.hasStartedTurn == false && app.thread(task.id)?.providerSessionID == nil
                     && runtime.turns.isEmpty && runtime.draft.text == "Keep the unsent task draft" && app.projects.isEmpty,
                     "Inspecting global memory starts no user turn, clears no draft and adds no saved project")

        let previewTask = app.newThread(affiliation: .standalone)!
        let previewDirectory = app.executionProject(for: previewTask)!.path
        let file = OMPMemoryFile(["bank": "global", "path": .string(root.appendingPathComponent("global/mnemopi.db").path), "scope": "global"])!
        do {
            _ = try await app.runtime(for: previewTask.id).previewMemory(file)
            preconditionFailure("The fixture must reject the unavailable SDK")
        } catch {
            precondition(error.localizedDescription.contains("Mnemopi SDK"), "Cold previews use the same guarded native startup")
        }
        precondition(FileManager.default.fileExists(atPath: previewDirectory) && app.thread(previewTask.id)?.hasStartedTurn == false,
                     "A cold global preview also prepares the task directory without sending a prompt")

        let missing = root.appendingPathComponent("missing-user-project")
        let project = app.addProject(at: missing)
        let chat = app.newThread(in: project, workspace: .local)!
        do { _ = try await app.runtime(for: chat.id).inspectMemory() } catch { }
        precondition(!FileManager.default.fileExists(atPath: missing.path),
                     "Memory inspection never recreates a missing user-owned project directory")
        print("PASS unsent task memory: discovery/preview directory preparation, native SDK gating, draft/turn preservation and project boundary")
    }

    @MainActor private static func checkFileCache(_ root: URL) async {
        var configuration = OMPMemoryConfiguration()
        configuration.enabled = true
        let first = MemoryFileCache.Context(threadID: UUID(), configuration: configuration)
        let next = MemoryFileCache.Context(threadID: UUID(), configuration: configuration)
        let inspection = OMPMemoryInspection(["files": [
            ["bank": "project", "path": "/project/mnemopi.db", "scope": "project"],
            ["bank": "shared", "path": "/global/mnemopi.db", "scope": "global"]]])
        let cache = MemoryFileCache()
        var reads = 0
        await cache.load(for: first) { reads += 1; return inspection }
        await cache.load(for: first) { reads += 1; return inspection }
        precondition(reads == 1 && cache.hasLoaded && cache.files.count == 1 && cache.files[0].isGlobal,
                     "Reopening settings reuses discovery and displays only global files")
        await cache.load(for: first, refresh: true) { reads += 1; return inspection }
        precondition(reads == 2, "The compact refresh action must force a new read")
        await cache.load(for: first, refresh: true) { throw ProviderError.failed("Fixture read failed") }
        let displayedFiles = cache.files
        let displayedError = cache.error
        precondition(cache.hasLoaded && !displayedFiles.isEmpty && displayedError != nil,
                     "A failed refresh must preserve the cached file rows")
        var complete: CheckedContinuation<OMPMemoryInspection, Never>?
        let pending = Task {
            await cache.load(for: first, refresh: true) {
                await withCheckedContinuation { complete = $0 }
            }
        }
        while complete == nil { await Task.yield() }
        precondition(cache.isLoading && cache.hasLoaded && cache.files == displayedFiles && cache.error == displayedError,
                     "An in-flight refresh must not remove existing file or error rows")
        await cache.load(for: first) { preconditionFailure("Concurrent openings must share the pending read") }
        cache.invalidate()
        await cache.load(for: next) { OMPMemoryInspection(["files": []]) }
        complete?.resume(returning: inspection)
        await pending.value
        precondition(cache.hasLoaded && cache.files.isEmpty && !cache.isLoading && cache.error == nil,
                     "A late previous-conversation reply cannot refill the current cache")
        var disabled = configuration
        disabled.enabled = false
        await cache.load(for: .init(threadID: next.threadID, configuration: disabled)) {
            preconditionFailure("Disabled memory cannot launch a discovery read")
        }
        precondition(!cache.hasLoaded && cache.files.isEmpty)

        let app = AppModel()
        let original = app.settings.ompMemory
        defer { app.settings.ompMemory = original }
        app.settings.ompMemory = configuration
        app.selectedThreadID = first.threadID
        await app.memoryFiles.load(for: first) { inspection }
        app.selectedThreadID = next.threadID
        precondition(!app.memoryFiles.hasLoaded, "Conversation changes must invalidate the app-owned cache immediately")
        await app.memoryFiles.load(for: next) { inspection }
        disabled = configuration
        disabled.enabled = false
        await app.changeMemory(disabled)
        precondition(!app.settings.ompMemory.enabled && !app.memoryFiles.hasLoaded,
                     "Turning memory off must discard cached file metadata")
        print("PASS memory cache: first read, reopening, stable refresh rows, global-only filtering, coalescing, stale replies and clean invalidation")
    }

    @MainActor private static func checkFilePreviews(_ root: URL) async throws {
        let project: JSONValue = ["bank": "project", "path": .string(root.appendingPathComponent("project/mnemopi.db").path), "scope": "project"]
        let global: JSONValue = ["bank": "global", "path": .string(root.appendingPathComponent("mnemopi.db").path), "scope": "global"]
        let invalid: JSONValue = ["bank": "unrelated", "path": "relative.db", "scope": "unknown"]
        let files = OMPMemoryInspection(["files": [project, global, project, invalid]])
        precondition(files.files.count == 2 && !files.files[0].isGlobal && files.files[1].isGlobal,
                     "Keep distinct native files, deduplicate replies and reject malformed paths/scopes")
        let preview = OMPMemoryPreview(["items": [["content": "用户：保存项目知识😀\n助手：已保存。",
                                                   "source": "coding-agent-transcript", "timestamp": "2026-10-17"],
                                                  ["content": "共享偏好", "source": "coding-agent-retain", "truncated": true]], "limited": true])
        precondition(preview.text.contains("coding-agent-transcript") && preview.text.contains("coding-agent-retain")
                     && preview.text.contains("2026-10-17") && preview.limited && !preview.isEmpty,
                     "A file preview must retain source/date information without system prompt instructions")
        precondition(OMPMemoryPreview(["items": []]).isEmpty)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let document = MemoryFilePreviewDocument(file: files.files[0], preview: preview,
            reader: PreviewReaderState(snapshot: .init(wrapsLines: true)), revision: "fixture")
            .frame(width: 600, height: 280)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: document)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 280),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let text = descendants(host).compactMap { $0 as? NSTextView }
        precondition(text.contains { !$0.isEditable && $0.isSelectable && $0.string.contains("用户：保存项目知识😀") },
                     "Click-through previews use the real read-only, selectable native file reader")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("memory-preview.png"))
        }
        guard let native = descendants(host).compactMap({ $0 as? PreviewTextHost }).first else {
            preconditionFailure("Memory preview must use the shared native text reader")
        }
        let viewportChanges = ViewportChanges()
        native.contentView.postsFrameChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
            object: native.contentView, queue: nil) { _ in
                MainActor.assumeIsolated { viewportChanges.count += 1 }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<3 { native.tile() }
        precondition(viewportChanges.count == 0,
                     "Tiling an unchanged preview must not transiently resize the text viewport beneath its line-number ruler")
        let content = String(repeating: "保存项目知识😀", count: 180)
        let full = OMPMemoryPreview(["items": .array((0..<16).map { index in
            ["content": .string(content), "source": "coding-agent-transcript", "timestamp": .string("2026-10-21 \(index)")]
        }), "limited": true])
        let fullHost = NSHostingView(rootView: MemoryFilePreviewDocument(file: files.files[1], preview: full,
            reader: PreviewReaderState(snapshot: .init(wrapsLines: true)), revision: "bounded")
            .frame(width: 496, height: 310))
        let fullWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 496, height: 310),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        fullWindow.isReleasedWhenClosed = false
        fullWindow.contentView = fullHost
        defer { fullWindow.close() }
        fullHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        fullHost.layoutSubtreeIfNeeded()
        precondition(descendants(fullHost).compactMap { $0 as? NSTextView }.contains { $0.string == full.text },
                     "A full bounded preview must finish native layout without losing content")
        let app = AppModel()
        let page = NSHostingView(rootView: MemorySettingsPage().environment(app).frame(width: 600))
        precondition(page.fittingSize.width == 600 && !app.settings.ompMemory.enabled,
                     "The settings page resolves its environment and preserves the opt-in default")
        print("PASS memory files: identities, provenance, empty/limited content, stable native viewport and bounded CJK preview")
    }
}
