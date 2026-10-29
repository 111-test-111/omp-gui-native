import AppKit
import SwiftUI

struct WorkspaceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowLiveResize.self) private var liveResize
    let previews: FilePreviewStore
    var sidebarTargetWidth: CGFloat? = nil

    private var context: FilePreviewContext? {
        guard let thread = model.selectedThread, let project = model.executionProject(for: thread) else { return nil }
        return FilePreviewContext(threadID: thread.id, workingDirectory: thread.executionDirectory(projectPath: project.path))
    }

    var body: some View {
        WorkspacePreviewSplit(model: model, liveResize: liveResize, previews: previews, sidebarTargetWidth: sidebarTargetWidth)
            // One continuous surface behind both native hosts. Readers leave
            // their canvas clear so tabs and file types keep the chat backdrop.
            .overlay(alignment: .top) {
                if previews.isFullscreen, let thread = model.selectedThread, let context {
                    WorkspaceFullscreenToolbar(previews: previews, thread: thread, context: context)
                        .id(context)
                        .modifier(HostedEnvironment(model: model, liveResize: liveResize, previews: previews))
                }
            }
            .detailSheet()
            .onChange(of: context, initial: true) { _, next in previews.setContext(next) }
            .onDisappear { previews.suspend() }
    }
}

private struct WorkspaceFullscreenToolbar: View {
    @Environment(AppModel.self) private var model
    let previews: FilePreviewStore
    let thread: ChatThread
    let context: FilePreviewContext
    @State private var git = GitStatusModel()
    @State private var width: CGFloat = 0

    var body: some View {
        let runtime = model.runtime(for: thread.id)
        ChatChromeRow(runtime: runtime, title: thread.title, project: model.project(thread.projectID),
                      directory: context.workingDirectory, git: git, paneWidth: width,
                      titleLeading: 0, workspaceTabs: previews)
            .padding(.bottom, 6)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .task(id: context) { await git.refresh(context.workingDirectory, force: false) }
            .onChange(of: runtime.diffRevision) { Task { await git.refresh(context.workingDirectory) } }
    }
}

/// Native split sizing keeps the preview drag out of the conversation's SwiftUI
/// view graph. Both hosts keep their identity while the divider is dragged.
private struct WorkspacePreviewSplit: NSViewRepresentable {
    let model: AppModel
    let liveResize: WindowLiveResize
    let previews: FilePreviewStore
    let sidebarTargetWidth: CGFloat?

    func makeNSView(context: Context) -> PreviewSplitView {
        let split = PreviewSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.liveResize = liveResize
        split.delegate = context.coordinator
        let chat = FrameHostingView(rootView: AnyView(Color.clear))
        let chatClip = SidebarChatClip(chat: chat)
        let reader = FrameHostingView(rootView: AnyView(Color.clear))
        let clip = PreviewSidebarClip(reader: reader)
        split.addSubview(chatClip)
        split.addSubview(clip)
        split.chat = chat
        split.chatClip = chatClip
        split.reader = reader
        split.previewClip = clip
        context.coordinator.install(in: split, previews: previews)
        updateHosts(split)
        return split
    }

    func updateNSView(_ split: PreviewSplitView, context: Context) {
        updateHosts(split)
    }

    private func updateHosts(_ split: PreviewSplitView) {
        let visible = previews.isVisible && previews.context != nil && previews.isWindowPresented && previews.isWorkspacePresented
        let contextChanged = split.presentedContext != previews.context
        let visibilityChanged = split.requiresVisibilityUpdate(visible)
        let fullscreenChanged = split.isFullscreen != previews.isFullscreen
        let sidebarTargetChanged = split.conversationSlideTargetWidth != sidebarTargetWidth
        let animated = previews.isWorkspacePresented && split.lastVisible != nil && !contextChanged && !fullscreenChanged && !previews.isFullscreen && split.canAnimateVisibility
        if contextChanged { split.hideImmediately() }
        split.preferredWidth = previews.width
        split.conversationSlideTargetWidth = sidebarTargetWidth
        split.fullscreenHeaderHeight = Chrome.chromeTopPadding + Chrome.capsuleHeight + 6
        split.setFullscreen(previews.isFullscreen, showsConversation: previews.isConversationPresented)
        split.presentedContext = previews.context
        let identity = previews.isChoosingPanel ? "picker" : previews.showsBrowser
            ? "browser:" + (previews.browserDirectory?.path ?? "")
            : (previews.activeSidebarTab?.id ?? "empty") + ":" + String(previews.selectedTab?.reader.showsSource ?? false)
        split.presentationIdentity = identity
        if visibilityChanged || contextChanged {
            split.chat?.rootView = AnyView(DetailView(previews: previews).modifier(HostedEnvironment(model: model, liveResize: liveResize, previews: previews)))
        }
        if visible && (visibilityChanged || contextChanged) {
            split.reader?.rootView = AnyView(WorkspaceSidebarPane(store: previews).modifier(HostedEnvironment(model: model, liveResize: liveResize, previews: previews)))
            split.reader?.isHidden = false
        } else if !visible && (visibilityChanged || contextChanged) {
            // A prepared viewport image carries the close animation. Release
            // live PDF/image/player views immediately, including their observers.
            split.reader?.rootView = AnyView(Color.clear)
            split.reader?.isHidden = true
        }
        if visibilityChanged || contextChanged || fullscreenChanged || (sidebarTargetChanged && split.isSliding) {
            split.setPreviewVisible(visible, animated: animated)
        }
        split.lastVisible = visible
        split.resizeSubviews(withOldSize: split.bounds.size)
        split.installWindowScope()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ split: PreviewSplitView, coordinator: Coordinator) {
        coordinator.tearDown()
        split.scopeChanged = nil
        if let window = split.window as? ThreadWindow, window.filePreviewHost === split.reader {
            window.filePreviewHost = nil
            window.filePreviews = nil
            split.hideImmediately()
        }
        split.reader?.rootView = AnyView(Color.clear)
    }

    @MainActor final class Coordinator: NSObject, NSSplitViewDelegate {
        private weak var split: PreviewSplitView?
        private weak var previews: FilePreviewStore?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private weak var scopedWindow: NSWindow?

        func install(in split: PreviewSplitView, previews: FilePreviewStore) {
            self.split = split
            self.previews = previews
            previews.visibilityWillChange = { [weak split] visible in
                split?.visibilityWillChange(visible)
            }
            split.scopeChanged = { [weak self, weak previews, weak split] in
                guard let split, let self else { return }
                previews?.window = split.window
                if let window = split.window as? ThreadWindow {
                    window.filePreviews = previews
                    window.filePreviewHost = split.reader
                }
                self.observeWindow(split.window)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        private func observeWindow(_ window: NSWindow?) {
            guard window !== scopedWindow else { return }
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            scopedWindow = window
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hideWindowReaders() }
                })
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        if window?.isVisible == true, window?.isMiniaturized == false { self?.previews?.windowPresented() }
                    }
                })
            }
            observers.append(center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideWindowReaders() }
            })
            observers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if window?.isVisible == true, window?.isMiniaturized == false { self?.previews?.windowPresented() }
                }
            })
        }

        private func hideWindowReaders() {
            split?.hideImmediately()
            previews?.windowHidden()
            split?.reader?.rootView = AnyView(Color.clear)
            split?.lastVisible = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let split, let previews, let window = split.window,
                  previews.isWorkspacePresented,
                  event.window === window, window.attachedSheet == nil,
                  let reader = split.reader, !reader.isHidden else { return event }
            if event.type != .keyDown {
                guard !reader.isHiddenOrHasHiddenAncestor else { return event }
                let point = reader.convert(event.locationInWindow, from: nil)
                if reader.bounds.contains(point) {
                    // A toolbar or image click owns preview shortcuts too;
                    // native text controls then take their own first responder.
                    window.makeFirstResponder(reader)
                }
                return event
            }
            let readerFocused = !reader.isHiddenOrHasHiddenAncestor && Self.ownsFocus(window.firstResponder, in: reader)
            let chatFocused = split.chat.map { !$0.isHiddenOrHasHiddenAncestor && Self.ownsFocus(window.firstResponder, in: $0) } == true
            guard readerFocused || (previews.isFullscreen && chatFocused) else { return event }
            let chord = KeyChord(keyCode: Int(event.keyCode), modifiers: event.modifierFlags)
            if previews.isFullscreen {
                if chord == ShortcutStore.shared.chord(for: .nextPreviewTab) { previews.selectNeighbor(1); return nil }
                if chord == ShortcutStore.shared.chord(for: .previousPreviewTab) { previews.selectNeighbor(-1); return nil }
                // The permanent conversation tab is not a closeable document.
                if previews.activeSidebarTab == .conversation, chord == KeyChord(keyCode: 13, modifiers: .command) { return nil }
            }
            guard readerFocused else { return event }
            if previews.activeSidebarTab == .panel(.browser),
               let browser = previews.session?.webBrowser {
                if chord == KeyChord(keyCode: 37, modifiers: .command) { browser.selectedPage?.addressFocus &+= 1; return nil }
                if chord == KeyChord(keyCode: 3, modifiers: .command) { browser.selectedPage?.showsFind = true; return nil }
                if chord == KeyChord(keyCode: 15, modifiers: .command) { browser.selectedPage?.reload(); return nil }
                if chord == KeyChord(keyCode: 13, modifiers: .command), let page = browser.selectedPage { page.requestClose(); return nil }
                if chord == KeyChord(keyCode: 17, modifiers: .command) {
                    do { let page = try browser.open(); page.addressFocus &+= 1 } catch { browser.error = error.localizedDescription }
                    return nil
                }
            }
            let modifiers = event.modifierFlags.intersection(KeyChord.allowedModifiers)
            if (modifiers == .command || modifiers == [.command, .shift]), previews.isFileReaderSelected,
               let tab = previews.selectedTab, let kind = previews.snapshot?.kind,
               [24, 27, 29].contains(event.keyCode) {
                let step = event.keyCode == 24 ? 1 : event.keyCode == 27 ? -1 : 0
                if kind == .image {
                    if step == 0 { tab.reader.resetImageZoom() } else { tab.reader.stepImageZoom(step) }
                    return nil
                }
                if kind == .pdf, let host = Self.pdfHost(in: reader) {
                    host.stepPreviewZoom(step)
                    return nil
                }
            }
            if chord == KeyChord(keyCode: 13, modifiers: .command) {
                if let tab = previews.activeSidebarTab { previews.closeSidebarTab(tab) } else { previews.setVisible(false) }
                return nil
            }
            if chord == KeyChord(keyCode: 3, modifiers: .command), previews.isFileReaderSelected {
                previews.find()
                return nil
            }
            if chord == ShortcutStore.shared.chord(for: .nextThread) || chord == ShortcutStore.shared.chord(for: .nextPreviewTab) {
                previews.selectNeighbor(1)
                return nil
            }
            if chord == ShortcutStore.shared.chord(for: .previousThread) || chord == ShortcutStore.shared.chord(for: .previousPreviewTab) {
                previews.selectNeighbor(-1)
                return nil
            }
            return event
        }

        private static func pdfHost(in view: NSView) -> PreviewPDFHost? {
            if let host = view as? PreviewPDFHost { return host }
            for child in view.subviews {
                if let host = pdfHost(in: child) { return host }
            }
            return nil
        }

        private static func ownsFocus(_ responder: NSResponder?, in host: NSView) -> Bool {
            if let view = responder as? NSView, view === host || view.isDescendant(of: host) { return true }
            // AppKit may host a control's field editor outside the pane's view
            // hierarchy. Ask the actual controls which one owns that editor.
            guard let text = responder as? NSText, text.isFieldEditor else { return false }
            return ownsEditor(text, in: host)
        }

        private static func ownsEditor(_ editor: NSText, in view: NSView) -> Bool {
            if let control = view as? NSControl, control.currentEditor() === editor { return true }
            return view.subviews.contains { ownsEditor(editor, in: $0) }
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            min(320, max(120, splitView.bounds.width - 400 - splitView.dividerThickness))
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            max(120, splitView.bounds.width - 400 - splitView.dividerThickness)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let split, !split.isFullscreen, split.liveResize?.isPreviewResizing == true, split.reader != nil else { return }
            let width = max(0, split.bounds.width - (split.previewClip?.frame.minX ?? split.bounds.width))
            split.preferredWidth = width
            previews?.setWidth(width)
        }

        func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
            split?.isFullscreen == true || (split?.revealedSpan ?? 0) <= 0.5
        }

        func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            split?.hideImmediately()
            previews?.visibilityWillChange = nil
            previews?.suspend()
        }
    }
}
