import Darwin
import Foundation

private struct PreviewStoreCheckFailure: Error, CustomStringConvertible {
    var description: String
}

/// Only publication timing is controlled. Resolution, reading, revision
/// checks, file events and the store itself remain production code.
@MainActor private final class PreviewPreparedGate {
    private var pathToHold: String?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isHeld = false

    func holdNext(_ path: String) { pathToHold = path; isHeld = false }

    func open(_ reference: FilePreviewReference, _ directory: String, _ readsContent: Bool,
              _ snapshot: PreviewFileSnapshot?) async throws -> PreviewFileOpening {
        let prepared = try await PreviewFileLoader.open(reference, relativeTo: directory,
                                                       readsContent: readsContent, reusing: snapshot)
        if pathToHold == reference.path {
            pathToHold = nil
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isHeld = true
            }
        }
        try Task.checkCancellation()
        return prepared
    }

    func release() {
        let pending = continuation
        continuation = nil
        isHeld = false
        pending?.resume()
    }
}

@MainActor private final class PreviewJobProbe {
    var active = 0
    var maximum = 0
    func began() { active += 1; maximum = max(maximum, active) }
    func ended() { active -= 1 }
}

@main @MainActor
private enum PreviewStoreChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PreviewStoreCheckFailure(description: message) }
    }

    private static func until(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= deadline { throw PreviewStoreCheckFailure(description: message) }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }

    private static func restored(_ store: FilePreviewStore, persistence: URL) async throws {
        let before = DiskWriter.shared.writes(to: persistence)
        try await until("Store restoration did not finish") {
            store.saveSynchronously()
            return DiskWriter.shared.writes(to: persistence) > before
        }
    }

    private static func loaded(_ store: FilePreviewStore, file: URL) async throws {
        try await until("Selected file did not finish loading: \(file.lastPathComponent)") {
            store.selectedTab?.url == file && store.snapshot?.url == file && !store.isLoading
        }
    }

    private static func reference(_ file: URL) -> FilePreviewReference { FilePreviewReference(path: file.path) }
    private static func descriptorCount() -> Int {
        (0..<1_024).reduce(into: 0) { count, descriptor in
            if fcntl(Int32(descriptor), F_GETFD) >= 0 { count += 1 }
        }
    }

    static func main() async {
        do { try await runChecks() }
        catch {
            print("FAIL store: \(error)")
            Darwin.exit(1)
        }
    }

    private static func runChecks() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("omp-preview-store-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let root = temporaryRoot.resolvingSymlinksInPath()
        DiskWriter.shared.configure(root: root)
        defer {
            DiskWriter.shared.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: root)
        }
        let files = ["A.swift", "B.swift", "C.swift"].map { root.appendingPathComponent($0) }
        for file in files { try Data(("// " + file.lastPathComponent + "\nlet value = 1\n").utf8).write(to: file) }
        let context = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        try linkRouting(root: root, context: context)
        print("PASS link routing: parsed URL escapes, literal OMP paths, line ranges and external application schemes")
        try await PreviewHostingChecks.run(root: root, context: context)
        print("PASS hosted routing: production cached chat root preserves sidebar/file actions, visibility and worker context")
        try await emptyPanePresentation(root: root, file: files[0], context: context)
        print("PASS empty pane: manual opening, launch restoration before/after context, conversation changes and final tab closure show the workspace tree")
        try await multifunctionSidebar(root: root, files: files, context: context)
        print("PASS sidebar: mixed tabs, review routing, hidden readers, cancelled opens, per-chat state, restoration and legacy migration")
        try await openingAndCancellation(root: root, files: files, context: context)
        print("PASS store opening: retained multi-open, latest selection, deduplication, close/select/hide/context cancellation")
        try await unrestrictedTabs(root: root, context: context)
        print("PASS unrestricted tabs: more than 24 normal/bulk files, canonical deduplication, bounded concurrent jobs and full persistence")
        try await openingPresentation(root: root, files: files, context: context)
        print("PASS opening presentation: prepared content, stable repeated navigation, real errors, hidden resources and one bounded folder cache")
        try await preparedOpeningRaces(root: root, context: context)
        print("PASS prepared opening races: newer watch revisions, appeared missing files and independent background pinning")
        try await fullscreenTabs(root: root, file: files[0], context: context)
        print("PASS fullscreen tabs: peer navigation, permanent conversation, cancelled reads, width restoration and last-tab collapse")
        try await fullscreenPersistence(root: root, context: context)
        print("PASS fullscreen persistence: per-conversation layout, restart ordering, late restore choices and last-tab collapse")
        try await markdownSwitching(root: root, context: context)
        print("PASS Markdown switching: retain the active document until the next source is ready")
        let saved = try await readingState(root: root, file: files[0], context: context)
        print("PASS store persistence: production JSON round trip restores selected tab and source/document/PDF/image/media reading state")
        try await delayedRestore(root: root, saved: saved, context: context)
        print("PASS store delayed restoration: intentional empty tabs, visibility and resized width take precedence")
        try await visibilityAndResources(root: root, saved: saved, file: files[0], context: context)
        print("PASS store lifecycle: browser select-current exit, hidden/window readers and watchers released, reopen/refresh, store deinit")
        try expect(DiskWriter.shared.errors.isEmpty, "Temporary persistence writes failed: \(DiskWriter.shared.errors)")
    }

    private static func emptyPanePresentation(root: URL, file: URL, context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("empty-pane.json")
        let store = FilePreviewStore(persistenceURL: persistence)
        defer { store.suspend() }
        store.setContext(context)
        store.setVisible(true)
        try await restored(store, persistence: persistence)
        try expect(store.showsBrowser && store.browserDirectory?.path == context.workingDirectory,
                   "Opening an empty pane did not show its workspace tree")
        store.saveSynchronously()
        let saved = try Data(contentsOf: persistence)
        for contextFirst in [true, false] {
            let restoredURL = root.appendingPathComponent("empty-pane-\(contextFirst).json")
            try saved.write(to: restoredURL)
            let next = FilePreviewStore(persistenceURL: restoredURL)
            defer { next.suspend() }
            if contextFirst { next.setContext(context) }
            try await restored(next, persistence: restoredURL)
            if !contextFirst { next.setContext(context) }
            try expect(next.isVisible && next.showsBrowser && next.browserDirectory?.path == context.workingDirectory,
                       "An empty pane restored without its tree when contextFirst=\(contextFirst)")
            try expect(next.selectedTab == nil && next.snapshot == nil && !next.isLoading,
                       "An empty browser started an unnecessary file reader")
        }
        store.open(reference(file))
        try await loaded(store, file: file)
        try expect(!store.showsBrowser, "An opened file did not replace the empty browser")
        store.close(file.path)
        try expect(store.showsBrowser && store.snapshot == nil, "Closing the final tab left a blank visible pane")
        store.open(reference(file))
        try await loaded(store, file: file)
        store.closeAll()
        try expect(store.showsBrowser && store.snapshot == nil, "Closing all tabs left a blank visible pane")
        let changed = FilePreviewContext(threadID: UUID(), workingDirectory: root.appendingPathComponent("other-workspace").path)
        store.setContext(changed)
        try expect(store.showsBrowser && store.browserDirectory?.path == changed.workingDirectory,
                   "Switching to an empty conversation retained the previous workspace or a blank pane")
        store.setVisible(false)
        store.setContext(context)
        try expect(!store.isVisible && !store.showsBrowser, "Changing conversation reopened a hidden pane")
        store.toggle()
        try expect(store.showsBrowser && store.browserDirectory?.path == context.workingDirectory,
                   "Reopening the hidden empty pane lost its workspace tree")
    }

    private static func multifunctionSidebar(root: URL, files: [URL], context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("sidebar.json")
        let gate = PreviewPreparedGate()
        let store = FilePreviewStore(persistenceURL: persistence) { reference, directory, reads, snapshot in
            try await gate.open(reference, directory, reads, snapshot)
        }
        defer { gate.release(); store.suspend() }
        store.setContext(context)
        try await restored(store, persistence: persistence)
        try expect(store.session?.reviewSelection == .latest, "A new sidebar lost the latest-turn review default")
        store.open(reference(files[0]), pinned: true)
        try await loaded(store, file: files[0])
        store.selectedTab?.reader.source = .init(x: 12, y: 34, selectionLocation: 3, selectionLength: 2)
        let readingState = store.selectedTab?.reader.snapshot
        let turn = UUID()
        try expect(store.reviewAction(threadID: context.threadID, turnID: turn), "Review did not accept its own chat")
        try expect(store.activeSidebarTab == .panel(.review) && store.session?.reviewTurnID == turn
                   && store.snapshot == nil && !store.isLoading, "Review kept the hidden file reader or lost its turn")
        try expect(!store.reviewAction(threadID: UUID(), turnID: UUID()) && store.session?.reviewTurnID == turn,
                   "A different chat's Review action changed this sidebar")
        store.openPanel(.git)
        store.openPanel(.git)
        try expect(store.session?.panels.filter { $0 == .git }.count == 1 && store.snapshot == nil,
                   "Placeholder opens duplicated a tab or loaded a file")
        store.openPanel(.review)
        store.togglePanelPicker()
        try expect(store.isChoosingPanel && store.activeSidebarTab == nil && store.snapshot == nil, "Picker left an active reader")
        store.select(files[0].path)
        try await loaded(store, file: files[0])
        try expect(!store.isChoosingPanel && store.selectedTab?.reader.snapshot == readingState, "Returning from the picker lost reading state")
        store.selectNeighbor(-1)
        try expect(store.activeSidebarTab == .panel(.git), "Keyboard tab navigation skipped panel tabs")
        store.openPanel(.review)
        store.saveSynchronously()
        let saved = try Data(contentsOf: persistence)
        let restoreURL = root.appendingPathComponent("sidebar-restored.json")
        try saved.write(to: restoreURL)
        let next = FilePreviewStore(persistenceURL: restoreURL)
        defer { next.suspend() }
        next.setContext(context)
        try await restored(next, persistence: restoreURL)
        try expect(next.activeSidebarTab == .panel(.review) && next.session?.reviewTurnID == turn
                   && next.snapshot == nil && next.selectedTab?.reader.snapshot == readingState,
                   "Restoration lost panel selection or read a hidden file")
        let other = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        next.setContext(other)
        try expect(next.activeSidebarTab == .panel(.files), "New chat inherited another chat's review")
        next.setContext(context)
        try expect(next.activeSidebarTab == .panel(.review) && next.session?.reviewTurnID == turn, "Chat switch lost review state")
        next.session?.reviewTurnID = nil
        next.openPanel(.git)
        next.openPanel(.review)
        try expect(next.session?.reviewSelection == .all, "Panel visits lost the all-changes selection")
        next.setContext(other)
        try expect(next.session?.reviewSelection == .latest, "All changes leaked into another chat")
        next.setContext(context)
        try expect(next.session?.reviewSelection == .all, "Chat switch lost the all-changes selection")
        next.saveSynchronously()
        let allRestoreURL = root.appendingPathComponent("sidebar-all-changes.json")
        try Data(contentsOf: restoreURL).write(to: allRestoreURL)
        let allRestored = FilePreviewStore(persistenceURL: allRestoreURL)
        defer { allRestored.suspend() }
        allRestored.setContext(context)
        try await restored(allRestored, persistence: allRestoreURL)
        try expect(allRestored.activeSidebarTab == .panel(.review) && allRestored.session?.reviewSelection == .all,
                   "Restoration confused all changes with the latest-turn default")
        try expect(allRestored.reviewAction(threadID: context.threadID, turnID: turn)
                   && allRestored.session?.reviewSelection == .turn(turn),
                   "A completed-turn Review action did not leave all changes for its own turn")
        next.closeSidebarTab(.file(files[0].path))
        try expect(next.activeSidebarTab == .panel(.review) && next.snapshot == nil, "Closing a background file replaced the active review")
        next.closeOtherSidebarTabs(.panel(.review))
        try expect(next.sidebarTabs == [.panel(.review)], "Close others retained unrelated tabs")
        next.closeAllSidebarTabs()
        next.setVisible(false)
        next.setVisible(true)
        try expect(next.isChoosingPanel && next.sidebarTabs.isEmpty && next.snapshot == nil,
                   "Closing all sidebar tabs did not retain the picker on reopen")
        next.saveSynchronously()
        let emptyRestore = FilePreviewStore(persistenceURL: restoreURL)
        defer { emptyRestore.suspend() }
        emptyRestore.setContext(context)
        try await restored(emptyRestore, persistence: restoreURL)
        try expect(emptyRestore.isChoosingPanel && emptyRestore.sidebarTabs.isEmpty, "An intentionally empty sidebar resurrected the file tree")

        // A prepared file read must not steal the destination chosen afterward.
        gate.holdNext(files[1].path)
        store.open(reference(files[1]))
        try await until("Delayed sidebar file read never prepared") { gate.isHeld }
        store.openPanel(.review)
        gate.release()
        try await settle()
        try expect(store.activeSidebarTab == .panel(.review) && store.session?.tabs.map(\.url) == [files[0]]
                   && store.snapshot == nil, "A cancelled file read took over the review")

        // The previous schema had only file tabs. Its reader state still migrates.
        var legacy = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        var sessions = legacy["sessions"] as! [[String: Any]]
        for index in sessions.indices {
            for key in ["panels", "activePanel", "isChoosingPanel", "reviewTurnID", "reviewAllChanges", "isFullscreen"] { sessions[index].removeValue(forKey: key) }
        }
        legacy["sessions"] = sessions
        let legacyURL = root.appendingPathComponent("sidebar-legacy.json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
        let migrated = FilePreviewStore(persistenceURL: legacyURL)
        defer { migrated.suspend() }
        migrated.setContext(context)
        try await restored(migrated, persistence: legacyURL)
        try await loaded(migrated, file: files[0])
        try expect(migrated.selectedTab?.reader.snapshot == readingState && migrated.sidebarTabs.contains(.panel(.files)) && !migrated.isFullscreen,
                   "Legacy preview state did not migrate into the multifunction sidebar")
    }

    private static func fullscreenTabs(root: URL, file: URL, context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("fullscreen.json")
        let gate = PreviewPreparedGate()
        let store = FilePreviewStore(persistenceURL: persistence) { reference, directory, reads, snapshot in
            try await gate.open(reference, directory, reads, snapshot)
        }
        defer { gate.release(); store.suspend() }
        store.setContext(context)
        try await restored(store, persistence: persistence)
        store.setWidth(540)
        store.open(reference(file))
        try await loaded(store, file: file)
        store.selectedTab?.reader.source = .init(x: 12, y: 34, selectionLocation: 3, selectionLength: 2)
        let readingState = store.selectedTab?.reader.snapshot
        store.setFullscreen(true)
        try expect(store.isFullscreen && store.isVisible && store.activeSidebarTab == .file(file.path),
                   "Entering fullscreen must expand the current sidebar destination")
        try expect(store.sidebarTabs.first == .conversation && !store.isConversationPresented,
                   "Fullscreen must add the conversation as a peer without selecting it")
        store.selectSidebarTab(.conversation)
        try expect(store.isConversationPresented && !store.isFileReaderSelected && store.snapshot == nil && !store.isLoading,
                   "The conversation tab must stop hidden file reads")
        store.closeSidebarTab(.conversation)
        try expect(store.activeSidebarTab == .conversation && store.isFullscreen && store.sidebarTabs.count == 3,
                   "Closing the permanent conversation tab must do nothing")
        store.selectNeighbor(1)
        try expect(store.activeSidebarTab == .panel(.files) && store.isFullscreen, "Tab navigation must include the conversation and panels")
        store.selectNeighbor(-1)
        try expect(store.activeSidebarTab == .conversation, "Reverse tab navigation must return to the conversation")
        store.selectSidebarTab(.file(file.path))
        try await loaded(store, file: file)
        try expect(store.selectedTab?.reader.snapshot == readingState, "Fullscreen tab visits lost the file's reading state")
        store.setFullscreen(false)
        try expect(store.isVisible && store.width == 540 && !store.sidebarTabs.contains(.conversation),
                   "Exiting fullscreen must restore split layout and the saved divider width")
        store.setFullscreen(true)
        gate.holdNext(file.path)
        store.open(reference(file))
        try await until("Fullscreen delayed file read never prepared") { gate.isHeld }
        store.selectSidebarTab(.conversation)
        gate.release()
        try await settle()
        try expect(store.activeSidebarTab == .conversation && store.snapshot == nil && !store.hasPendingOpen,
                   "A late file open must not steal the fullscreen conversation")
        store.closeSidebarTab(.panel(.files))
        try expect(store.isFullscreen && store.isVisible, "A remaining file tab must keep fullscreen open")
        store.closeSidebarTab(.file(file.path))
        try expect(!store.isFullscreen && !store.isVisible && store.sidebarTabs.isEmpty && store.isConversationPresented,
                   "Closing the last sidebar tab from the conversation must exit fullscreen and collapse")
        store.toggle()
        try expect(store.isVisible && !store.isFullscreen && store.isChoosingPanel && store.width == 540,
                   "Reopening an empty sidebar must use the panel picker in split layout")
        store.openPanel(.git)
        store.setFullscreen(true)
        store.closeSidebarTab(.panel(.git))
        try expect(!store.isFullscreen && !store.isVisible, "Closing the last active panel must also collapse")
        store.openPanel(.review)
        store.setFullscreen(true)
        store.closeAllSidebarTabs()
        try expect(!store.isFullscreen && !store.isVisible, "Close all must exit fullscreen and collapse")
        store.open(reference(file))
        try await loaded(store, file: file)
        store.setFullscreen(true)
        store.closeAll()
        try expect(!store.isFullscreen && !store.isVisible && store.sidebarTabs.isEmpty,
                   "The file toolbar's Close all preview tabs must collapse a file-only fullscreen workspace")
        store.openPanel(.files)
        store.setFullscreen(true)
        let other = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        store.setContext(other)
        try expect(!store.isFullscreen && store.activeSidebarTab == .panel(.files),
                   "A new conversation must begin in split layout rather than inheriting fullscreen")
        store.setFullscreen(true)
        store.setContext(context)
        try expect(store.isFullscreen && store.activeSidebarTab == .conversation, "Returning to a fullscreen conversation must focus its chat")
        store.setVisible(false)
        store.setVisible(true)
        try expect(!store.isFullscreen && store.activeSidebarTab == .panel(.files),
                   "The sidebar toggle must leave fullscreen and restore the last panel")
        store.saveSynchronously()
        let restoredStore = FilePreviewStore(persistenceURL: persistence)
        defer { restoredStore.suspend() }
        restoredStore.setContext(context)
        try await restored(restoredStore, persistence: persistence)
        try expect(!restoredStore.isFullscreen && restoredStore.width == 540,
                   "Explicitly leaving fullscreen must persist without overwriting the saved split width")
    }

    private static func fullscreenPersistence(root: URL, context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("fullscreen-persistence.json")
        let other = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        let store = FilePreviewStore(persistenceURL: persistence)
        defer { store.suspend() }
        store.setContext(context)
        try await restored(store, persistence: persistence)
        store.setWidth(540)
        store.openPanel(.git)
        store.setFullscreen(true)
        store.setContext(other)
        try expect(!store.isFullscreen, "Fullscreen is independent for conversations sharing the same working directory")
        store.openPanel(.review)
        store.setVisible(false)
        store.saveSynchronously()
        let saved = try Data(contentsOf: persistence)

        for contextFirst in [true, false] {
            let url = root.appendingPathComponent("fullscreen-restart-\(contextFirst).json")
            try saved.write(to: url)
            let next = FilePreviewStore(persistenceURL: url)
            defer { next.suspend() }
            if contextFirst { next.setContext(context) }
            try await restored(next, persistence: url)
            if !contextFirst { next.setContext(context) }
            try expect(next.isFullscreen && next.isVisible && next.activeSidebarTab == .conversation && next.width == 540,
                       "Restart restores the conversation's fullscreen layout before or after selecting its context")
            try expect(next.session?.panels.contains(.git) == true, "Restoring fullscreen retains the saved sidebar panels")
            next.setContext(other)
            try expect(!next.isFullscreen && next.activeSidebarTab == .panel(.review), "The other conversation restores its own split layout")
            next.setContext(context)
            try expect(next.isFullscreen, "Visiting a split conversation cannot clear another conversation's fullscreen choice")
            next.setFullscreen(false)
            next.saveSynchronously()
            let split = FilePreviewStore(persistenceURL: url)
            defer { split.suspend() }
            split.setContext(context)
            try await restored(split, persistence: url)
            try expect(!split.isFullscreen && split.width == 540, "An explicit fullscreen exit also survives restarting")
        }

        for action in ["exit", "hide", "enter"] {
            let url = root.appendingPathComponent("fullscreen-late-\(action).json")
            try saved.write(to: url)
            let gate = DiskWriter.shared.pauseReads()
            let next = FilePreviewStore(persistenceURL: url)
            defer { next.suspend() }
            next.setContext(action == "enter" ? other : context)
            try await until("Fullscreen restore did not reach the gated read") { gate.hasEntered }
            if action == "hide" { next.setVisible(false) }
            else { next.setFullscreen(action == "enter") }
            DiskWriter.shared.releaseReads(gate)
            try await restored(next, persistence: url)
            try expect(next.isFullscreen == (action == "enter"), "Late disk restoration must preserve the user's latest fullscreen choice")
            try expect(next.session?.panels.contains(action == "enter" ? .review : .git) == true,
                       "A layout choice during restoration must still restore the saved sidebar tabs")
            if action == "hide" { try expect(!next.isVisible, "A late fullscreen restore cannot reopen an explicitly hidden sidebar") }
        }

        store.setContext(context)
        store.closeAllSidebarTabs()
        store.saveSynchronously()
        let empty = FilePreviewStore(persistenceURL: persistence)
        defer { empty.suspend() }
        empty.setContext(context)
        try await restored(empty, persistence: persistence)
        try expect(!empty.isFullscreen && !empty.isVisible && empty.sidebarTabs.isEmpty,
                   "Closing the last sidebar tabs persists the fullscreen exit and folded sidebar")
        empty.toggle()
        try expect(!empty.isFullscreen && empty.isChoosingPanel, "Reopening the empty sidebar after restart uses split layout")
    }

    private static func markdownSwitching(root: URL, context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("markdown-switching.json")
        let store = FilePreviewStore(persistenceURL: persistence)
        defer { store.suspend() }
        store.setContext(context)
        try await restored(store, persistence: persistence)
        let files = ["first.md", "second.md"].map { root.appendingPathComponent($0) }
        for (i, file) in files.enumerated() {
            try Data("# Document \(i)\n\n$x^2$".utf8).write(to: file)
            store.open(reference(file), pinned: true)
            try await loaded(store, file: file)
        }
        store.select(files[0].path)
        try expect(store.isLoading && store.snapshot?.url == files[1], "Markdown tab switch discarded its engine host before reading the next file")
        try await loaded(store, file: files[0])
        store.select(files[1].path)
        try expect(store.snapshot?.url == files[0], "Reverse tab switch discarded its current source")
        try await loaded(store, file: files[1])
    }

    private static func linkRouting(root: URL, context: FilePreviewContext) throws {
        let spaced = root.appendingPathComponent("a b.swift")
        let literalPercent = root.appendingPathComponent("a%20b.swift")
        for file in [spaced, literalPercent] { try Data("let value = 1\n".utf8).write(to: file) }
        var captured: FilePreviewReference?
        let action = FilePreviewAction { reference, source, pinned in
            captured = reference
            return source == context && pinned
        }
        func target(_ url: URL) throws -> FilePreviewTarget {
            captured = nil
            try expect(action(url, context: context, pinned: true), "A local URL was not routed with its context and pin state")
            guard let captured else { throw PreviewStoreCheckFailure(description: "Local URL action lost its reference") }
            return try FilePreviewResolver.resolve(captured, relativeTo: root.path)
        }

        let spaceTarget = try target(URL(string: "a%20b.swift")!)
        try expect(spaceTarget.url == spaced, "A parsed URL opened a literal percent filename instead of its escaped space")
        let percentTarget = try target(URL(string: "a%2520b.swift")!)
        try expect(percentTarget.url == literalPercent, "A parsed URL decoded its percent escape twice")
        let absoluteTarget = try target(spaced)
        try expect(absoluteTarget.url == spaced, "An absolute file URL lost URL escaping")
        let rangeTarget = try target(URL(string: "A.swift:2-3")!)
        try expect(rangeTarget.url == root.appendingPathComponent("A.swift") && rangeTarget.location?.line == 2,
                   "A bare file line range was misclassified as an external application scheme")
        let escapedLocation = try target(URL(string: "file:missing.swift%3A12%23L5")!)
        try expect(escapedLocation.url == root.appendingPathComponent("missing.swift:12#L5") && escapedLocation.location == nil,
                   "Escaped filename delimiters became navigation selectors")
        captured = nil
        try expect(action(FilePreviewReference(path: literalPercent.path), context: context, pinned: true), "Raw OMP path routing failed")
        let rawTarget = try FilePreviewResolver.resolve(captured!, relativeTo: root.path)
        try expect(rawTarget.url == literalPercent, "Raw OMP filenames acquired URL decoding")
        for link in ["https://example.com/file.swift", "mailto:reader@example.com", "codex://threads/example", "app:sample"] {
            captured = nil
            try expect(!action(URL(string: link)!, context: context, pinned: true) && captured == nil,
                       "An external application URL was routed into the local file pane")
        }
    }

    private static func openingAndCancellation(root: URL, files: [URL], context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("opening.json")
        let store = FilePreviewStore(persistenceURL: persistence)
        defer { store.suspend() }
        store.setContext(context)
        try await restored(store, persistence: persistence)

        // All calls are made before yielding the actor. The asynchronous opens
        // overlap regardless of which native filesystem lookup finishes first.
        store.open(reference(files[0]))
        store.open(reference(files[1]))
        try await loaded(store, file: files[1])
        try await settle()
        try expect(Set(store.session?.tabs.map(\.url) ?? []) == Set(files.prefix(2)) && store.selectedTab?.url == files[1],
                   "Normal opens must retain both tabs and keep the newest one selected")
        store.closeAll()
        store.open(reference(files[0]), pinned: true)
        store.open(reference(files[1]), pinned: true)
        try await loaded(store, file: files[1])
        try await until("Pinned multi-open lost a file") { store.session?.tabs.count == 2 }
        try expect(store.session?.tabs.allSatisfy(\.isPinned) == true, "Pinned multi-open created a temporary tab")
        store.open(reference(files[0]), pinned: true)
        try await loaded(store, file: files[0])
        try expect(store.session?.tabs.count == 2, "Opening the same canonical file duplicated a tab")

        // Selecting the current tab must cancel a pending new open too.
        store.open(reference(files[2]))
        store.select(files[0].path)
        try await settle()
        try expect(store.selectedTab?.url == files[0] && store.session?.tabs.count == 2, "Selecting the current tab did not cancel a pending open")
        store.open(reference(files[2]), pinned: true)
        store.closeOthers(files[0].path)
        try await settle()
        try expect(store.session?.tabs.map(\.url) == [files[0]], "Pending pinned open revived a tab after Close others")
        store.open(reference(files[2]))
        store.showFiles()
        try await settle()
        try expect(store.showsBrowser && store.snapshot == nil && store.session?.tabs.map(\.url) == [files[0]], "Pending open took over after an explicit browser action")
        store.select(files[0].path)
        try await loaded(store, file: files[0])
        store.open(reference(files[2]), pinned: true)
        store.close(files[0].path)
        try await settle()
        try expect(store.session?.tabs.isEmpty == true && store.snapshot == nil, "Pending open revived a tab after Close")
        store.open(reference(files[0]), pinned: true)
        try await loaded(store, file: files[0])
        store.open(reference(files[2]), pinned: true)
        store.closeAll()
        try await settle()
        try expect(store.session?.tabs.isEmpty == true, "Pending open revived a tab after Close all")
        store.open(reference(files[0]), pinned: true)
        try await loaded(store, file: files[0])
        store.open(reference(files[2]), pinned: true)
        store.setVisible(false)
        try await settle()
        try expect(!store.isVisible && store.snapshot == nil && store.session?.tabs.map(\.url) == [files[0]], "Hiding the pane did not cancel a pending open")
        store.setVisible(true)
        try await loaded(store, file: files[0])
        store.open(reference(files[2]), pinned: true)
        store.setContext(FilePreviewContext(threadID: UUID(), workingDirectory: context.workingDirectory))
        store.setContext(context)
        try await loaded(store, file: files[0])
        try await settle()
        try expect(store.session?.tabs.map(\.url) == [files[0]], "A stale context open inserted into the restored source session")
    }

    private static func unrestrictedTabs(root: URL, context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("many-tabs.json")
        let jobs = PreviewJobProbe()
        let store = FilePreviewStore(persistenceURL: persistence) { reference, directory, reads, snapshot in
            await jobs.began()
            do {
                let result = try await PreviewFileLoader.open(reference, relativeTo: directory, readsContent: reads, reusing: snapshot)
                await jobs.ended()
                return result
            } catch {
                await jobs.ended()
                throw error
            }
        }
        defer { store.suspend() }
        store.setContext(context)
        try await restored(store, persistence: persistence)
        let files = (0..<40).map { root.appendingPathComponent("many-\($0).txt") }
        for file in files { try Data("Tab fixture\n".utf8).write(to: file) }
        for file in files.prefix(30) { store.open(reference(file)) }
        try await until("Normal opens were limited or replaced earlier files") { store.session?.tabs.count == 30 && !store.hasPendingOpen }
        store.openFiles(Array(files.suffix(10)))
        try await until("Bulk opens were limited or dropped queued files") { store.session?.tabs.count == 40 && !store.hasPendingOpen }
        try expect(jobs.maximum <= FilePreviewStore.maximumConcurrentOpens, "Unlimited tabs created unbounded concurrent file jobs")
        store.open(reference(files[0]))
        try await loaded(store, file: files[0])
        try expect(store.session?.tabs.count == 40 && store.session?.tabs.allSatisfy(\.isPinned) == true,
                   "Reopening duplicated a file or left replaceable tabs")
        store.saveSynchronously()
        let next = FilePreviewStore(persistenceURL: persistence)
        defer { next.suspend() }
        next.setContext(context)
        try await restored(next, persistence: persistence)
        try await loaded(next, file: files[0])
        try expect(next.session?.tabs.count == 40, "Persistence truncated tabs beyond the old limit")
    }

    private static func openingPresentation(root: URL, files: [URL], context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("opening-presentation.json")
        let store = FilePreviewStore(persistenceURL: persistence)
        defer { store.suspend() }
        store.setContext(context)
        try await restored(store, persistence: persistence)
        store.open(reference(files[0]))
        try expect(store.hasPendingOpen && store.selectedTab == nil && store.snapshot == nil,
                   "Opening did not expose the pending request before the empty-pane placeholder")
        try await loaded(store, file: files[0])
        try await until("Prepared open was not released") { !store.hasPendingOpen }
        let original = store.selectedTab!
        let revision = store.snapshot!.revision
        store.open(FilePreviewReference(path: files[0].path, line: 2))
        try expect(store.snapshot?.revision == revision && !store.isLoading,
                   "Repeated navigation discarded the current file before validating it")
        try await until("Repeated file navigation was not applied") { !store.hasPendingOpen && original.reader.navigationRequest > 0 }
        try expect(store.selectedTab === original && store.snapshot?.revision == revision && !store.isLoading,
                   "Repeated file navigation remounted a valid reader")
        store.open(reference(files[1]))
        try expect(store.selectedTab === original && store.snapshot?.url == files[0],
                   "A new open replaced the current visual before its content was ready")
        try await loaded(store, file: files[1])
        let missing = root.appendingPathComponent("missing-preview.swift")
        store.open(reference(missing))
        try await until("A real file error was not presented in its resolved tab") {
            !store.hasPendingOpen && store.selectedTab?.url == missing && store.error != nil
        }
        try expect(store.snapshot == nil && !store.isLoading, "File errors stayed in a pending state")

        store.windowHidden()
        store.open(reference(files[0]))
        try await until("Hidden opening request did not finish") { !store.hasPendingOpen }
        try expect(store.snapshot == nil && !store.isLoading, "Hidden opening retained prepared file resources")
        store.windowPresented()
        try await loaded(store, file: files[0])
        store.showFiles()
        let listing = try await PreviewDirectoryBrowser.list(root)
        store.rememberDirectoryListing(listing, at: root, showHidden: false, context: context)
        try expect(store.cachedDirectoryListing(at: root, showHidden: false, context: context)?.entries == listing.entries,
                   "Remounting the browser could not reuse its recent bounded folder rows")
        try expect(store.cachedDirectoryListing(at: root, showHidden: true, context: context) == nil,
                   "Folder rows were reused across incompatible hidden-file policies")
        let nested = root.appendingPathComponent("single-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        store.browserDirectory = nested
        let nestedListing = try await PreviewDirectoryBrowser.list(nested)
        store.rememberDirectoryListing(nestedListing, at: nested, showHidden: false, context: context)
        try expect(store.cachedDirectoryListing(at: root, showHidden: false, context: context) == nil,
                   "The browser accumulated folder caches instead of retaining only one")
        store.forgetDirectoryListing(at: nested)
        try expect(store.cachedDirectoryListing(at: nested, showHidden: false, context: context) == nil,
                   "Unreadable/removed folder rows survived invalidation")
        store.rememberDirectoryListing(nestedListing, at: nested, showHidden: false, context: context)
        store.setContext(FilePreviewContext(threadID: UUID(), workingDirectory: nested.path))
        try expect(store.cachedDirectoryListing(at: nested, showHidden: false, context: context) == nil,
                   "Folder rows survived a workspace change")
    }

    private static func preparedOpeningRaces(root: URL, context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("prepared-races.json")
        let gate = PreviewPreparedGate()
        let store = FilePreviewStore(persistenceURL: persistence, opener: { try await gate.open($0, $1, $2, $3) })
        defer { gate.release(); store.suspend() }
        let file = root.appendingPathComponent("prepared-race.swift")
        try Data("let version = 1\n".utf8).write(to: file)
        store.setContext(context)
        try await restored(store, persistence: persistence)
        store.open(reference(file))
        try await loaded(store, file: file)
        try await until("Initial prepared opening did not finish") { !store.hasPendingOpen }
        gate.holdNext(file.path)
        store.open(reference(file))
        try await until("Old prepared snapshot was not held") { gate.isHeld }
        let newer = "let version = 2\n"
        try Data(newer.utf8).write(to: file, options: .atomic)
        try await until("The active watcher did not observe the newer file") { store.snapshot?.text == newer && !store.isLoading }
        gate.release()
        try await until("Old prepared snapshot was not published") { !store.hasPendingOpen }
        try await until("A prepared old snapshot replaced the new watch baseline permanently") { store.snapshot?.text == newer && !store.isLoading }

        let appeared = root.appendingPathComponent("appeared-before-watch.swift")
        gate.holdNext(appeared.path)
        store.open(reference(appeared))
        try await until("Prepared missing-file result was not held") { gate.isHeld }
        try Data("let appeared = true\n".utf8).write(to: appeared)
        gate.release()
        try await loaded(store, file: appeared)
        try expect(store.error == nil, "An appeared file remained stuck behind its prepared error")

        gate.holdNext(file.path)
        store.open(reference(file), pinned: true)
        try await until("The nonselected pinned task was not held") { gate.isHeld }
        let missing = root.appendingPathComponent("latest-pinned-missing.swift")
        store.open(reference(missing), pinned: true)
        try await until("The latest pinned file did not finish with its real error") {
            store.selectedTab?.url == missing && store.error != nil && !store.isLoading
        }
        try expect(!store.hasPendingOpen && gate.isHeld,
                   "A background pin masked the selected file's completed error with a pending state")
        gate.release()
        try await until("The delayed pinned tab was lost") { store.session?.tabs.contains(where: { $0.url == file && $0.isPinned }) == true }
        try expect(store.selectedTab?.url == missing && store.error != nil, "A delayed pin replaced the selected file's error")
    }

    private static func readingState(root: URL, file: URL, context: FilePreviewContext) async throws -> Data {
        let persistence = root.appendingPathComponent("reader-state.json")
        let store = FilePreviewStore(persistenceURL: persistence)
        defer { store.suspend() }
        store.setContext(context)
        try await restored(store, persistence: persistence)
        store.open(reference(file), pinned: true)
        try await loaded(store, file: file)
        guard let state = store.selectedTab?.reader else { throw PreviewStoreCheckFailure(description: "Reading state unavailable") }
        state.showsSource = true
        state.showsDiff = true
        state.wrapsLines = true
        state.source = .init(x: 20, y: 300, selectionLocation: 5, selectionLength: 3)
        state.document = .init(x: 0, y: 180, selectionLocation: 2, selectionLength: 6)
        state.pdfPage = 3
        state.pdfScale = 1.4
        state.pdfAutoScales = false
        state.pdfX = 40
        state.pdfY = 50
        state.imageScale = 2
        state.imageX = 10
        state.imageY = 11
        state.mediaTime = 12.5
        let findRequest = state.findRequest
        store.find()
        try expect(state.findRequest == findRequest, "Diff find targeted an invisible source reader")
        try expect(store.questionContext(includingSelection: true) == nil, "Diff mode quoted an old source selection")
        let expected = state.snapshot
        store.setWidth(620)
        store.saveSynchronously()
        let data = try Data(contentsOf: persistence)
        let nextPersistence = root.appendingPathComponent("reader-state-restored.json")
        try data.write(to: nextPersistence)
        let next = FilePreviewStore(persistenceURL: nextPersistence)
        defer { next.suspend() }
        next.setContext(context)
        try await restored(next, persistence: nextPersistence)
        try await loaded(next, file: file)
        try expect(next.width == 620 && next.isVisible && next.selectedTab?.isPinned == true && !next.showsBrowser, "Pane and selected-tab state did not restore")
        try expect(next.selectedTab?.reader.snapshot == expected, "Production reading-state JSON changed on restore")
        next.open(FilePreviewReference(path: file.path, line: 2))
        try await until("Explicit line navigation did not leave Diff for source") {
            next.selectedTab?.reader.showsDiff == false && (next.selectedTab?.reader.navigationRequest ?? 0) > 0
        }
        return data
    }

    private static func delayedRestore(root: URL, saved: Data, context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("delayed-restore.json")
        try saved.write(to: persistence)
        let gate = DiskWriter.shared.pauseReads()
        let store = FilePreviewStore(persistenceURL: persistence)
        defer { store.suspend() }
        store.setContext(context)
        try await until("Delayed restore did not reach its disk read") { gate.hasEntered }
        store.closeAll()
        store.setWidth(444)
        store.setVisible(false)
        DiskWriter.shared.releaseReads(gate)
        try await restored(store, persistence: persistence)
        try expect(store.session?.tabs.isEmpty == true && store.selectedTab == nil, "Delayed restoration repopulated intentionally closed tabs")
        try expect(store.width == 444 && !store.isVisible && !store.isLoading && store.snapshot == nil, "Delayed restoration overrode an explicit width/visibility choice")
    }

    private static func visibilityAndResources(root: URL, saved: Data, file: URL, context: FilePreviewContext) async throws {
        let persistence = root.appendingPathComponent("visibility.json")
        try saved.write(to: persistence)
        var store: FilePreviewStore? = FilePreviewStore(persistenceURL: persistence)
        weak let weakStore = store
        store?.setContext(context)
        guard let active = store else { throw PreviewStoreCheckFailure(description: "Store was not created") }
        // This helper checks visibility while a strong reference is in scope;
        // the final deinit check uses a separate temporary store below.
        try await restored(active, persistence: persistence)
        try await loaded(active, file: file)
        try await settle()
        let withWatcher = descriptorCount()
        active.showFiles()
        try await settle()
        try expect(active.showsBrowser && active.snapshot == nil && !active.isLoading, "Browser kept a hidden source reader")
        try expect(descriptorCount() <= withWatcher - 1, "Browser retained vnode watcher descriptors")
        active.refresh()
        try await settle()
        try expect(active.snapshot == nil && !active.isLoading, "Refresh loaded a file behind the browser")
        active.select(file.path)
        try await loaded(active, file: file)
        try expect(!active.showsBrowser, "Selecting the current tab did not leave the browser")
        let revision = active.renderRevision
        active.refresh()
        try await loaded(active, file: file)
        try expect(active.renderRevision > revision, "Explicit refresh did not invalidate unchanged renderer content")
        var capturedBeforeHide = false
        active.visibilityWillChange = { [weak active] visible in
            if !visible { capturedBeforeHide = active?.isVisible == true && active?.snapshot?.url == file }
        }
        active.setVisible(false)
        try expect(capturedBeforeHide, "Closing visuals could not be captured before visibility and file resources were cleared")
        active.visibilityWillChange = nil
        try await settle()
        let hiddenDescriptors = descriptorCount()
        active.refresh()
        try await settle()
        try expect(active.snapshot == nil && !active.isLoading && descriptorCount() <= hiddenDescriptors + 1, "Hidden preview restarted a reader/watcher")
        active.setVisible(true)
        try await loaded(active, file: file)
        active.windowHidden()
        active.setVisible(true)
        active.refresh()
        try await settle()
        try expect(!active.isWindowPresented && active.snapshot == nil && !active.isLoading, "Hidden window retained a reader/watcher")
        active.windowPresented()
        try await loaded(active, file: file)
        let selectedBeforeSettings = active.selectedTab?.id
        active.setWorkspacePresented(false)
        active.refresh()
        active.windowPresented()
        try await settle()
        try expect(active.isVisible && !active.isWorkspacePresented && active.snapshot == nil && !active.isLoading,
                   "Covered workspace releases readers without changing the saved preview visibility")
        try expect(active.selectedTab?.id == selectedBeforeSettings, "Settings keeps the selected preview tab")
        active.setWorkspacePresented(true)
        try await loaded(active, file: file)
        try expect(active.selectedTab?.id == selectedBeforeSettings, "Returning from settings resumes the same preview")
        active.suspend()
        store = nil
        try expect(weakStore != nil, "Scope-local reference unexpectedly disappeared")

        let temporaryPersistence = root.appendingPathComponent("deinit.json")
        var temporary: FilePreviewStore? = FilePreviewStore(persistenceURL: temporaryPersistence)
        weak let released = temporary
        temporary?.setContext(context)
        if let temporary {
            try await restored(temporary, persistence: temporaryPersistence)
            temporary.open(reference(file), pinned: true)
            try await loaded(temporary, file: file)
        }
        try await settle()
        let beforeRelease = descriptorCount()
        temporary = nil
        try expect(released == nil, "Store teardown has a retain cycle")
        try await settle()
        try expect(descriptorCount() <= beforeRelease - 1, "Store deinit retained vnode watcher descriptors")
    }
}
