import AppKit
import SwiftUI
@testable import OMPGUI

@main
private enum PreviewBrowserStateChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            expect(ContinuousClock.now < deadline, message)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func main() async throws {
        guard let output = CaptureRun.storageRoot else { fatalError("Require isolated capture storage") }
        _ = NSApplication.shared // Never order a window front or launch the application.
        let workspace = output.appendingPathComponent("workspace", isDirectory: true)
        let folder = workspace.appendingPathComponent("Expanded folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<160 {
            let file = folder.appendingPathComponent(String(format: "file-%03d.txt", index))
            try "Browser fixture \(index)\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let preview = nested.appendingPathComponent("Preview.txt")
        try "A file opened from the tree\n".write(to: preview, atomically: true, encoding: .utf8)
        let context = FilePreviewContext(threadID: UUID(), workingDirectory: workspace.path)
        let store = FilePreviewStore(persistenceURL: output.appendingPathComponent("browser-previews.json"))
        store.setContext(context)
        store.openPanel(.files)
        let browser = store.session!.browser
        browser.showsHidden = true
        browser.expandedFolders = [folder.standardizedFileURL.path, nested.standardizedFileURL.path]
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let resize = WindowLiveResize(window: window)
        let host = FrameHostingView(rootView: AnyView(
            WorkspaceSidebarPane(store: store)
                .modifier(HostedEnvironment(model: model, liveResize: resize, previews: store))
        ))
        window.contentView = host
        defer { store.suspend(); window.contentView = nil; window.close() }

        var tree: NSScrollView?
        try await eventually("Expanded folders must populate the real file-tree scroll document") {
            host.layoutSubtreeIfNeeded()
            tree = descendants(host).compactMap { $0 as? NSScrollView }.first {
                $0.bounds.width > 200 && $0.bounds.height > 100 && ($0.documentView?.frame.height ?? 0) > 3_000
            }
            return tree != nil
        }
        let originalTree = tree!
        let originalDocument = originalTree.documentView!
        originalTree.contentView.scroll(to: NSPoint(x: 0, y: 750))
        originalTree.reflectScrolledClipView(originalTree.contentView)
        host.layoutSubtreeIfNeeded()
        let offset = originalTree.contentView.bounds.origin.y
        expect(offset > 700, "The fixture must begin with a scrolled tree")
        expect(browser.expandedFolders.count == 2 && browser.showsHidden, "Both folder levels and the hidden-file policy start active")

        store.open(FilePreviewReference(path: preview.path), context: context)
        try await eventually("Opening a tree file must activate its native preview") {
            host.layoutSubtreeIfNeeded()
            return store.snapshot?.url == preview && store.isFileReaderSelected
        }
        expect(descendants(host).contains { $0 === originalTree }, "A file preview must retain the tree's native scroll container")
        expect(originalTree.documentView === originalDocument, "A preview must not replace the browser document")
        store.refresh() // Hidden folder tasks must not discard rows during a file refresh.
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        expect(abs(originalTree.contentView.bounds.origin.y - offset) < 1, "A hidden file refresh must preserve the browser's scroll offset")
        store.openPanel(.files)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        expect(descendants(host).contains { $0 === originalTree }, "Returning to Files must reuse its original scroller")
        expect(abs(originalTree.contentView.bounds.origin.y - offset) < 1, "Returning from the preview must restore the exact scroll position")
        expect(browser.expandedFolders == [folder.standardizedFileURL.path, nested.standardizedFileURL.path] && browser.showsHidden,
               "Returning must retain nested expansion and the hidden-file policy")
        expect(store.snapshot == nil && !store.isLoading, "Returning to Files must release the hidden file reader")

        store.togglePanelPicker()
        store.openPanel(.git)
        store.openPanel(.files)
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        expect(descendants(host).contains { $0 === originalTree } && abs(originalTree.contentView.bounds.origin.y - offset) < 1,
               "Picker and placeholder tabs must also preserve the Files viewport")
        store.setFullscreen(true)
        store.selectSidebarTab(.conversation)
        host.layoutSubtreeIfNeeded()
        expect(descendants(host).contains { $0 === originalTree } && !store.showsBrowser,
               "The fullscreen conversation must retain the hidden Files tree without directory reads")
        store.selectSidebarTab(.panel(.files))
        store.setFullscreen(false)
        host.layoutSubtreeIfNeeded()
        expect(descendants(host).contains { $0 === originalTree } && abs(originalTree.contentView.bounds.origin.y - offset) < 1,
               "Entering and leaving fullscreen must retain the native file-tree viewport")
        store.closeSidebarTab(.panel(.files))
        try await eventually("Closing Files must release its retained scroll container") {
            host.layoutSubtreeIfNeeded()
            return !descendants(host).contains { $0 === originalTree }
        }
        store.openPanel(.files)
        let secondContext = FilePreviewContext(threadID: UUID(), workingDirectory: workspace.path)
        store.setContext(secondContext)
        host.layoutSubtreeIfNeeded()
        expect(store.session?.browser !== browser && store.session?.browser.expandedFolders.isEmpty == true,
               "Another conversation must not inherit this browser's expansion state")
        expect(!window.isVisible, "Browser state checks must never show a window")
        try await fullscreenWorkspace(workspace: workspace, output: output)
        print("Browser state checks passed: \(checks)")
    }

    @MainActor private static func fullscreenWorkspace(workspace: URL, output: URL) async throws {
        let model = AppModel()
        model.settings.performanceMode = true
        model.settings.hasSeenHydraIntro = true
        model.settings.autoHideTopControls = false
        let project = model.addProject(at: workspace)
        let thread = model.newThread(in: project, workspace: .local)!
        let runtime = model.runtime(for: thread.id)
        runtime.draft.text = "Keep this draft while switching fullscreen tabs"
        let store = FilePreviewStore(persistenceURL: output.appendingPathComponent("fullscreen-workspace.json"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 720),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let resize = WindowLiveResize(window: window)
        let host = FrameHostingView(rootView: AnyView(
            WorkspaceDetailView(previews: store)
                .modifier(HostedEnvironment(model: model, liveResize: resize, previews: store))
        ))
        window.contentView = host
        defer { store.suspend(); window.contentView = nil; window.close() }
        func layout() {
            host.layoutSubtreeIfNeeded()
            for child in descendants(host).compactMap({ $0 as? FrameHostingView }) { child.layoutSubtreeIfNeeded() }
        }
        try await eventually("The production workspace must acquire its conversation context") {
            layout()
            return store.context?.threadID == thread.id
        }
        store.openPanel(.files)
        var nativeSplit: PreviewSplitView?
        try await eventually("The production split must mount both native hosts") {
            layout()
            nativeSplit = descendants(host).compactMap { $0 as? PreviewSplitView }.first
            return nativeSplit?.reader?.isHidden == false && nativeSplit?.chat != nil
        }
        let split = nativeSplit!, chat = split.chat!, reader = split.reader!
        let splitWidth = reader.frame.width
        store.setFullscreen(true)
        try await eventually("The sidebar must fill the production fullscreen workspace") {
            layout()
            return split.isFullscreen && split.chatClip?.isHidden == true && reader.frame.width == split.bounds.width
        }
        expect(reader.frame.height == split.bounds.height - Chrome.chromeTopPadding - Chrome.capsuleHeight - 6,
               "Fullscreen panels must reserve exactly the shared toolbar's height")
        try await Task.sleep(for: .milliseconds(120))
        layout()
        let readerBounds = reader.convert(reader.bounds, to: host)
        let topInset = host.isFlipped ? readerBounds.minY : host.bounds.height - readerBounds.maxY
        expect(topInset >= Chrome.chromeTopPadding + Chrome.capsuleHeight + 6 - 0.5,
               "The live reader must remain below the shared toolbar after AppKit completes its layout")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("workspace-fullscreen.png"))
            }
        }
        store.selectSidebarTab(.conversation)
        try await eventually("The conversation tab must reveal the retained chat across the workspace") {
            layout()
            return split.chatClip?.isHidden == false && split.previewClip?.isHidden == true
        }
        expect(split.chat === chat && split.reader === reader && chat.frame.width == split.bounds.width,
               "The production fullscreen switch must retain its hosts and use the entire conversation width")
        expect(runtime.draft.text == "Keep this draft while switching fullscreen tabs", "Fullscreen visits must preserve the composer draft")
        store.setFullscreen(false)
        try await eventually("Leaving fullscreen must restore the production split") {
            layout()
            return !split.isFullscreen && reader.frame.width == splitWidth && split.previewClip?.isHidden == false
        }
        store.setFullscreen(true)
        store.closeSidebarTab(.panel(.files))
        try await eventually("Closing the final panel must collapse the production sidebar") {
            layout()
            return !store.isFullscreen && !store.isVisible && split.previewClip?.isHidden == true
        }
        expect(split.chat === chat && runtime.draft.text == "Keep this draft while switching fullscreen tabs",
               "Last-tab collapse must retain the conversation and its draft")
        expect(!window.isVisible, "Fullscreen checks must never show a window")

        store.openPanel(.files)
        store.setFullscreen(true)
        store.saveSynchronously()
        let reopened = FilePreviewStore(persistenceURL: output.appendingPathComponent("fullscreen-workspace.json"))
        let reopenedWindow = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        reopenedWindow.isReleasedWhenClosed = false
        let reopenedResize = WindowLiveResize(window: reopenedWindow)
        let reopenedHost = FrameHostingView(rootView: AnyView(
            WorkspaceDetailView(previews: reopened)
                .modifier(HostedEnvironment(model: model, liveResize: reopenedResize, previews: reopened))
        ))
        reopenedWindow.contentView = reopenedHost
        defer { reopened.suspend(); reopenedWindow.contentView = nil; reopenedWindow.close() }
        try await eventually("A recreated workspace must restore fullscreen from disk in its native hosts") {
            reopenedHost.layoutSubtreeIfNeeded()
            for child in descendants(reopenedHost).compactMap({ $0 as? FrameHostingView }) { child.layoutSubtreeIfNeeded() }
            guard let restoredSplit = descendants(reopenedHost).compactMap({ $0 as? PreviewSplitView }).first else { return false }
            return reopened.isFullscreen && reopened.isVisible && reopened.activeSidebarTab == .conversation
                && restoredSplit.isFullscreen && restoredSplit.previewClip?.isHidden == true
                && restoredSplit.chatClip?.isHidden == false && restoredSplit.chat?.frame.width == restoredSplit.bounds.width
        }
        if let bitmap = reopenedHost.bitmapImageRepForCachingDisplay(in: reopenedHost.bounds) {
            reopenedHost.cacheDisplay(in: reopenedHost.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("workspace-fullscreen-restored.png"))
            }
        }
        expect(!reopenedWindow.isVisible, "Restored fullscreen checks must never show a window")
    }

}
