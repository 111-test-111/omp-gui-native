import AppKit
import SwiftUI

/// Builds Tivano's windows the way the app builds its settings window: a plain titled AppKit window
/// with a clear background and a SwiftUI glass pane, so no scene background draws a second corner.
/// Every window is a `DCDisplayCycleGuardedWindow`: SwiftUI under a transparent title bar makes
/// AppKit evaluate the view graph inside its own display cycle, and the guard is what keeps the
/// passes that evaluation asks for from ending the app on macOS 26 and later.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    let model = AppModel()

    private var mainWindow: NSWindow?
    private weak var chatResponder: NSResponder?

    var filePreviews: FilePreviewStore? { (mainWindow as? ThreadWindow)?.filePreviews }

    func openFilesInPreview() {
        showMain()
        filePreviews?.chooseFiles(in: mainWindow)
    }

    func toggleFilePreview() {
        showMain()
        filePreviews?.toggle()
    }

    func toggleTerminal() {
        if let id = model.selectedThreadID {
            model.runtime(for: id).isTerminalVisible.toggle()
        }
    }

    func selectPreviewTab(offset: Int) {
        showMain()
        filePreviews?.selectNeighbor(offset)
    }

    private enum Size {
        static let main = NSSize(width: 1320, height: 860)
        static let mainMinimum = NSSize(width: 860, height: 560)
    }

    private static let mainFrameName = "TivanoMainWindow"

    func showMain() {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        present(window)
    }

    func showSettings(page: SettingsPage? = nil) {
        if !SettingsNavigation.shared.isPresented { chatResponder = mainWindow?.firstResponder }
        model.isCommandPalettePresented = false
        SettingsNavigation.shared.present(page: page)
        showMain()
        mainWindow?.makeFirstResponder(nil)
    }

    func hideSettings() {
        SettingsNavigation.shared.dismiss()
        if let responder = chatResponder {
            DispatchQueue.main.async { [weak self, weak responder] in self?.mainWindow?.makeFirstResponder(responder) }
        }
        chatResponder = nil
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMainWindow() -> NSWindow {
        let window = makeWindow(title: AppInfo.name, size: Size.main, resizable: true, windowClass: ThreadWindow.self) { RootView() }
        (window as? ThreadWindow)?.selectThread = { [weak model] offset in model?.selectThread(offset: offset) }
        (window as? ThreadWindow)?.selectThreadNumber = { [weak model] number in model?.selectThread(number: number) }
        window.contentMinSize = Size.mainMinimum
        if !window.setFrameUsingName(Self.mainFrameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.mainFrameName)
        return window
    }

    /// The main window for the onboarding captures: the same window, at a fixed size, with
    /// no frame autosave, so the run never reads or writes where the real window sits.
    func makeCaptureWindow(size: NSSize, threadControls: Bool = false) -> NSWindow {
        let window = makeWindow(title: AppInfo.name, size: size, resizable: true,
                                windowClass: threadControls ? ThreadWindow.self : DCDisplayCycleGuardedWindow.self) { RootView() }
        if let threadWindow = window as? ThreadWindow {
            mainWindow = window // Route native menu commands to the verification window too.
            threadWindow.selectThread = { [weak model] offset in model?.selectThread(offset: offset) }
            threadWindow.selectThreadNumber = { [weak model] number in model?.selectThread(number: number) }
        }
        return window
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        resizable: Bool,
        windowClass: DCDisplayCycleGuardedWindow.Type = DCDisplayCycleGuardedWindow.self,
        @ViewBuilder content: () -> Content
    ) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let frame = NSRect(origin: .zero, size: size)
        let window = windowClass.init(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.tabbingMode = .disallowed
        WindowChrome.configure(window)

        let liveResize = WindowLiveResize(window: window)
        let hosting = FrameHostingView(rootView: AnyView(HostedRoot(model: model, liveResize: liveResize, content: content())))
        hosting.frame = frame
        let container = NSView(frame: frame)
        container.addSubview(hosting)
        window.contentView = container
        return window
    }
}

/// Whether the window is being dragged to a new size right now. Views read it from the
/// environment to hold their settle animations and heavier layout work until the drag
/// ends: a spring restarted on every frame of a live resize is what made panels lag
/// behind the window and land somewhere else. Flipped by AppKit's live-resize
/// notifications for this one window, so a resize elsewhere leaves it alone.
@MainActor @Observable
final class WindowLiveResize {
    private(set) var isActive = false
    /// Whether the sidebar's edge or the terminal's divider is being dragged: the pane
    /// changes width or height every frame the way a live resize does, so the timeline
    /// steps its row width and holds its animations exactly as it does for one. Written
    /// by the chat view, which is where both drags are observed.
    var isPaneResizing = false
    var isPreviewResizing = false
    /// A native file-pane slide holds expensive timeline rows at their final
    /// width, just as the conversation sidebar does during its own motion.
    var isPreviewSliding = false
    var previewSlideDelta: CGFloat = 0
    /// The window or a pane is changing size by a drag or a file-pane slide.
    var isReshaping: Bool { isActive || isPaneResizing || isPreviewResizing || isPreviewSliding }

    /// The window keeps this alive for as long as it exists, so the observations are
    /// never taken down: a window is not made twice.
    init(window: NSWindow) {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = true }
        }
        center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = false }
        }
    }
}

/// Shared environment for every hosted window, plus the app-wide appearance choice.
private struct HostedRoot<Content: View>: View {
    let model: AppModel
    let liveResize: WindowLiveResize
    let content: Content

    var body: some View {
        content
            .modifier(HostedEnvironment(model: model, liveResize: liveResize))
            .preferredColorScheme(model.settings.theme.spec.scheme)
            .onChange(of: model.settings.theme, initial: true) { _, theme in
                NSApp.appearance = switch theme.spec.scheme {
                case nil: nil
                case .light: NSAppearance(named: .aqua)
                case .dark: NSAppearance(named: .darkAqua)
                @unknown default: nil
                }
            }
    }
}

/// The environment every hosted view tree starts from: a window's root, and a chat column
/// hosted on its own inside the main window (see `ThreadColumns`).
struct HostedEnvironment: ViewModifier {
    @Environment(\.workspaceTerminalAction) private var inheritedTerminalAction
    @Environment(\.workspaceReviewAction) private var inheritedReviewAction
    @Environment(\.filePreviewAction) private var inheritedPreviewAction
    @Environment(\.filePreviewToggle) private var inheritedPreviewToggle
    @Environment(\.filePreviewIsVisible) private var inheritedPreviewIsVisible
    @Environment(\.openURL) private var inheritedOpenURL
    let model: AppModel
    let liveResize: WindowLiveResize
    var previews: FilePreviewStore? = nil

    func body(content: Content) -> some View {
        // Cached chat columns already carry the window's preview scope. A host
        // without its own store must preserve that scope rather than reset it.
        let previewAction = previews?.action ?? inheritedPreviewAction
        let openURL = previews.map { previews in
            OpenURLAction { url in
                if previewAction(url) { return .handled }
                if model.openWebLink(url, previews: previews) { return .handled }
                return .systemAction
            }
        } ?? inheritedOpenURL
        content
            .environment(model)
            .environment(liveResize)
            .environment(\.workspaceTerminalAction, previews?.terminalAction ?? inheritedTerminalAction)
            .environment(\.filePreviewAction, previewAction)
            .environment(\.workspaceReviewAction, previews?.reviewAction ?? inheritedReviewAction)
            .environment(\.filePreviewToggle, previews?.toggleAction ?? inheritedPreviewToggle)
            .environment(\.filePreviewIsVisible, previews?.isVisible ?? inheritedPreviewIsVisible)
            .environment(\.openURL, openURL)
            .font(.ui(.body))
            .buttonBorderShape(.capsule)
            .modifier(ThemeTint(theme: model.settings.theme))
    }
}

/// Tints prominent glass buttons, toggles and progress views with the
/// theme's accent. System/Light/Dark keep the system control accent.
private struct ThemeTint: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        // One branch, never two: an `if` here made the whole window's content a different
        // view once a theme with an accent replaced one without, so every page was built
        // afresh and Settings jumped back to its top on a theme change. A nil tint keeps
        // the system accent.
        content.tint(theme.spec.accent)
    }
}

/// Lets the frame it is given define the hosting view's size instead of the content
/// hugging it: a window's content view, or a chat column filling the detail pane.
final class FrameHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Every window here holds focusable text (the composer, a search field), so the
    /// answer is always yes. SwiftUI's own answer searches the whole view tree for a
    /// navigable item, and AppKit asks on every display cycle while content scrolls
    /// under the title bar to work out the window's drag region.
    override var acceptsFirstResponder: Bool { true }

    /// A hidden chat column keeps its buttons' shortcuts to itself: AppKit offers a chord to
    /// hidden views too, and a Return meant for the shown column's card must not land on
    /// one behind it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        !isHiddenOrHasHiddenAncestor && super.performKeyEquivalent(with: event)
    }
}
