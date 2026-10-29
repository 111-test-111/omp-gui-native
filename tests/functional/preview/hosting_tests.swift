import AppKit
import Observation
import SwiftUI

// The generic modifier and cached chat root factory are extracted from source.
// Only their unrelated model/theme and ChatView content are substituted; the
// latter records the final environment that the actual controls would receive.
@MainActor final class PreviewEnvironmentProbe {
    var values: EnvironmentValues?
}

@MainActor @Observable final class AppModel {
    let settings = PreviewHostingSettings()
    let probe = PreviewEnvironmentProbe()
    func runtime(for id: UUID) -> PreviewEnvironmentProbe { probe }
    var webLinkHandler: ((URL, FilePreviewStore) -> Bool)?
    func openWebLink(_ url: URL, previews: FilePreviewStore) -> Bool { webLinkHandler?(url, previews) ?? false }
}

@MainActor @Observable final class WindowLiveResize {}
struct PreviewHostingSettings { var theme = AppTheme() }
struct AppTheme { var spec: PreviewHostingTheme { PreviewHostingTheme() } }
struct PreviewHostingTheme { var accent: Color? { nil } }
extension Font { static func ui(_ style: Font.TextStyle) -> Font { .system(style) } }
extension EnvironmentValues { @Entry var chatColumnIsShown = true }

@MainActor @Observable final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var isPresented = false
}

// Veil animation is outside the preview routing check. The production column
// visibility modifier itself is extracted and tested with a covered workspace.
struct ChatVeilVisibility: ViewModifier {
    func body(content: Content) -> some View { content }
}

// Intercept the production link dispatcher's external fallback. This module's
// spy deliberately shadows AppKit.NSWorkspace; no application can be opened.
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    private(set) var openedURLs: [URL] = []
    @discardableResult func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

struct ChatView: View {
    let runtime: PreviewEnvironmentProbe
    var previews: FilePreviewStore? = nil
    @Environment(\.self) private var values
    var body: some View {
        runtime.values = values
        return Color.clear.frame(width: 2, height: 2)
    }
}

private struct PreviewHostingFailure: Error, CustomStringConvertible {
    var description: String
}

@MainActor enum PreviewHostingChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PreviewHostingFailure(description: message) }
    }

    private static func render<V: View>(_ content: V, model: AppModel) throws -> EnvironmentValues {
        model.probe.values = nil
        let renderer = ImageRenderer(content: content)
        try expect(renderer.cgImage != nil, "Offscreen SwiftUI environment evaluation failed")
        guard let values = model.probe.values else {
            throw PreviewHostingFailure(description: "The hosted child did not receive an environment")
        }
        return values
    }

    static func run(root: URL, context: FilePreviewContext) async throws {
        try expect(NSApp == nil, "The headless routing check must not run an application")
        let model = AppModel()
        let liveResize = WindowLiveResize()
        let store = FilePreviewStore(persistenceURL: root.appendingPathComponent("hosting.json"))
        defer { store.suspend() }
        store.setContext(context)

        // This is ThreadColumns.Coordinator.root itself, including the same
        // modifier order that previously hid the supplied actions from ChatView.
        let column = PreviewChatRoot.root(context.threadID, isShown: true, model: model, liveResize: liveResize,
                                          action: store.action, toggle: store.toggleAction, visible: false, review: store.reviewAction, terminal: store.terminalAction)
        let source = FilePreviewContext(threadID: UUID(), workingDirectory: root.appendingPathComponent("worker").path)
        let inherited = try render(column.environment(\.filePreviewContext, source), model: model)
        try expect(inherited.filePreviewAction == store.action, "The cached chat host replaced its supplied file action")
        try expect(inherited.filePreviewToggle == store.toggleAction, "The cached chat host replaced its supplied sidebar button action")
        try expect(!inherited.filePreviewIsVisible && inherited.filePreviewContext == source,
                   "The cached chat host changed preview visibility or the originating directory")
        try expect(inherited.workspaceReviewAction == store.reviewAction, "The cached chat host replaced its review action")
        let requestedTurn = UUID()
        try expect(inherited.workspaceReviewAction(threadID: context.threadID, turnID: requestedTurn)
                   && store.session?.reviewTurnID == requestedTurn && store.activeSidebarTab == .panel(.review),
                   "The hosted Review action did not select the requested turn")
        store.setVisible(false)
        SettingsNavigation.shared.isPresented = true
        let covered = try render(column, model: model)
        try expect(!covered.chatColumnIsShown, "Settings must pause the cached chat's visible-only work")
        SettingsNavigation.shared.isPresented = false
        let resumed = try render(column, model: model)
        try expect(resumed.chatColumnIsShown, "Returning from settings restores the selected chat's visibility")
        let fullscreenColumn = PreviewChatRoot.root(context.threadID, isShown: true, model: model, liveResize: liveResize,
            action: store.action, toggle: store.toggleAction, visible: true, review: store.reviewAction,
            terminal: store.terminalAction, previews: store)
        store.setFullscreen(true)
        let hiddenChat = try render(fullscreenColumn, model: model)
        try expect(!hiddenChat.chatColumnIsShown,
                   "A fullscreen sidebar tab must pause the retained chat's visible-only work")
        store.selectSidebarTab(.conversation)
        let fullscreenChat = try render(fullscreenColumn, model: model)
        try expect(fullscreenChat.chatColumnIsShown,
                   "Selecting the fullscreen conversation must resume the same cached chat")
        store.setVisible(false)
        inherited.filePreviewToggle()
        try expect(store.isVisible, "The hosted sidebar button did not open the pane")

        let visibleColumn = PreviewChatRoot.root(context.threadID, isShown: true, model: model, liveResize: liveResize,
                                                 action: store.action, toggle: store.toggleAction, visible: true, review: store.reviewAction, terminal: store.terminalAction)
        let visible = try render(visibleColumn, model: model)
        try expect(visible.filePreviewIsVisible, "The cached chat host hid the button's active state")
        visible.filePreviewToggle()
        try expect(!store.isVisible, "The hosted sidebar button did not close the pane")

        let terminalColumn = PreviewChatRoot.root(context.threadID, isShown: true, model: model, liveResize: liveResize,
                                                 action: store.action, toggle: store.toggleAction, visible: true,
                                                 review: store.reviewAction, terminal: store.terminalAction)
        let terminal = try render(terminalColumn, model: model)
        try expect(terminal.workspaceTerminalAction == store.terminalAction,
                   "The cached chat host must preserve the sidebar terminal action")
        try expect(terminal.workspaceTerminalAction(threadID: context.threadID, isOpen: true)
                   && store.activeSidebarTab == .panel(.terminal), "The hosted terminal action must open this window's tab")
        try expect(!terminal.workspaceTerminalAction(threadID: UUID(), isOpen: false),
                   "A different conversation must not close this window's terminal tab")
        try expect(terminal.workspaceTerminalAction(threadID: context.threadID, isOpen: false)
                   && store.session?.panels.contains(.terminal) == false, "The hosted terminal action must close its tab")
        let genericTerminal = try render(ChatView(runtime: model.probe)
            .modifier(HostedEnvironment(model: model, liveResize: liveResize))
            .environment(\.workspaceTerminalAction, store.terminalAction), model: model)
        try expect(genericTerminal.workspaceTerminalAction == store.terminalAction,
                   "A generic host must inherit the terminal action instead of resetting it")
        let otherAction = WorkspaceTerminalAction(identity: UUID()) { _, _ in false }
        let ownScope = try render(ChatView(runtime: model.probe)
            .modifier(HostedEnvironment(model: model, liveResize: liveResize, previews: store))
            .environment(\.workspaceTerminalAction, otherAction), model: model)
        try expect(ownScope.workspaceTerminalAction == store.terminalAction,
                   "An explicit window scope must replace an unrelated inherited terminal action")

        let file = URL(fileURLWithPath: source.workingDirectory).appendingPathComponent("output.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// worker output\nlet value = 1\n".utf8).write(to: file)
        MarkdownLinkOpener.open(URL(string: "output.swift:2")!, previewAction: inherited.filePreviewAction,
                                context: inherited.filePreviewContext)
        try expect(NSWorkspace.shared.openedURLs.isEmpty, "The hosted Markdown file link opened an external application")
        let deadline = ContinuousClock.now + .seconds(3)
        while store.snapshot?.url != file || store.isLoading {
            try expect(ContinuousClock.now < deadline, "The hosted file link did not load its originating worker file")
            try await Task.sleep(for: .milliseconds(15))
        }
        try expect(store.selectedTab?.origin == source && store.selectedTab?.location?.line == 2,
                   "The hosted link lost its source context or line navigation")
        let external = URL(string: "https://example.com/document")!
        MarkdownLinkOpener.open(external, previewAction: inherited.filePreviewAction, context: inherited.filePreviewContext)
        try expect(NSWorkspace.shared.openedURLs == [external], "The hosted Markdown link intercepted an external website")

        var webURLs: [URL] = []
        model.webLinkHandler = { url, owner in
            precondition(owner === store, "Web links must retain their window's preview owner")
            webURLs.append(url)
            return true
        }
        let routedColumn = try render(PreviewChatRoot.root(context.threadID, isShown: true, model: model, liveResize: liveResize,
            action: store.action, toggle: store.toggleAction, visible: true, review: store.reviewAction,
            terminal: store.terminalAction, previews: store), model: model)
        MarkdownLinkOpener.open(external, previewAction: routedColumn.filePreviewAction,
            context: source, openURL: { routedColumn.openURL($0) })
        try expect(webURLs == [external] && NSWorkspace.shared.openedURLs == [external],
                   "Cached chat hosts and native Markdown must share the window's web-link route")
        model.webLinkHandler = nil

        // A window with an explicit store establishes its own scope. A generic
        // host without either an inherited scope or store remains unhandled.
        let scoped = try render(ChatView(runtime: model.probe).modifier(HostedEnvironment(model: model, liveResize: liveResize, previews: store)), model: model)
        try expect(scoped.filePreviewAction == store.action && scoped.filePreviewToggle == store.toggleAction && scoped.filePreviewIsVisible,
                   "A window host did not establish its explicit preview scope")
        let empty = try render(ChatView(runtime: model.probe).modifier(HostedEnvironment(model: model, liveResize: liveResize)), model: model)
        try expect(!empty.filePreviewAction(file) && !empty.filePreviewIsVisible, "A host without a scope acquired a file handler")
        var inheritedURLs: [URL] = []
        let routed = try render(ChatView(runtime: model.probe)
            .modifier(HostedEnvironment(model: model, liveResize: liveResize))
            .environment(\.openURL, OpenURLAction { url in
                inheritedURLs.append(url)
                return .handled
            }), model: model)
        let internalURL = URL(string: "omp-preview-host-checks://inherited-route")!
        routed.openURL(internalURL)
        try expect(inheritedURLs == [internalURL], "A generic host replaced the inherited URL router")
        try expect(NSApp == nil, "Offscreen routing verification created an application")
    }
}
