import AppKit
import SwiftUI

struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspaceTerminalAction) private var sidebarAction
    let runtime: ThreadRuntime
    let directory: String
    var isSidebar = false
    var onHide: (() -> Void)? = nil
    private var location: TerminalLocation { isSidebar ? .sidebar : .bottom }

    private func hide() {
        if let onHide { onHide() } else { runtime.isTerminalVisible = false }
    }

    @State private var dragOrigin: Double?
    /// The height while the edge is being dragged. Settings take it on release, so a drag
    /// never writes user defaults on every frame.
    @State private var dragHeight: Double?

    var body: some View {
        let terminals = model.terminals
        let sessions = terminals.sessions(for: runtime.threadID, in: location)
        let selected = terminals.selected(for: runtime.threadID, in: location)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(sessions) { session in
                            TerminalTab(
                                session: session,
                                isSelected: session.id == selected?.id,
                                select: {
                                    terminals.select(session)
                                    runtime.terminalFocusLocation = location
                                },
                                restart: { terminals.restart(session) },
                                close: { terminals.close(session) }
                            )
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                ChromeCapsule {
                    ChromeIconButton(symbol: "plus", help: "New terminal") {
                        terminals.open(threadID: runtime.threadID, directory: directory, in: location)
                        runtime.terminalFocusLocation = location
                    }
                    ChromeIconButton(symbol: isSidebar ? "rectangle.bottomthird.inset.filled" : "sidebar.right",
                                     isEnabled: sidebarAction.isAvailable,
                                     help: isSidebar ? "Open terminal in bottom panel" : "Open terminal in sidebar") {
                        model.moveTerminal(for: runtime.threadID, from: location, sidebar: sidebarAction)
                    }
                    ChromeIconButton(symbol: isSidebar ? "sidebar.right" : "chevron.down",
                                     help: Chrome.localized("Hide terminal") + (isSidebar ? "" : ShortcutStore.hint(for: .toggleTerminal))) { hide() }
                }
            }
            .padding(Chrome.workspaceToolbarInsets)

            if let selected {
                TerminalHost(session: selected, runtime: runtime, isDark: colorScheme == .dark,
                             theme: model.settings.theme, isSidebar: isSidebar) { hide() }
                    .id(selected.id)
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
            } else {
                // Every tab closed leaves the drawer open with nothing in it; the way
                // back is here rather than only on the plus in the corner.
                VStack(spacing: 10) {
                    Text("No shell open in this thread")
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.secondaryText)
                    Button("New shell") {
                        terminals.open(threadID: runtime.threadID, directory: directory, in: location)
                        runtime.terminalFocusLocation = location
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: isSidebar ? nil : dragHeight ?? model.settings.terminalHeight)
        .frame(maxHeight: isSidebar ? .infinity : nil)
        // The drag lives on a strip of its own at the very top edge, overlaid on the empty
        // band above the tabs: the whole tab row used to resize, so a sideways drag across
        // the tabs moved the drawer instead of scrolling them.
        .overlay(alignment: .top) {
            if !isSidebar {
                TerminalResizeHandle(
                    onBegin: { dragOrigin = model.settings.terminalHeight; runtime.isTerminalResizing = true },
                    onChange: { delta in
                        let origin = dragOrigin ?? model.settings.terminalHeight
                        dragHeight = min(760, max(140, origin + delta))
                    },
                    onEnd: {
                        if let dragHeight { model.settings.terminalHeight = dragHeight }
                        dragHeight = nil
                        dragOrigin = nil
                        runtime.isTerminalResizing = false
                    }
                )
                .frame(height: 8)
            }
        }
        .onAppear {
            terminals.ensureTerminal(threadID: runtime.threadID, directory: directory, in: location)
            runtime.terminalFocusLocation = location
            // A reused session can already be mounted before onAppear. The
            // focus request is deliberately unobserved, so handle that case
            // without waiting for an unrelated representable update.
            Task { @MainActor in
                guard runtime.terminalFocusLocation == location,
                      let view = terminals.selected(for: runtime.threadID, in: location)?.view,
                      let window = view.window else { return }
                runtime.terminalFocusLocation = nil
                window.makeFirstResponder(view)
            }
        }
    }
}

/// The drawer's resize grip along its top edge, the same affordance as the sidebar's edge.
private struct TerminalResizeHandle: View {
    let onBegin: () -> Void
    /// How far the pointer has travelled since the press, positive upward, which is the
    /// direction the drawer grows.
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        DragHandle(
            axis: .vertical,
            grip: DragHandleView.Grip(restLength: 12, shownLength: 28, thickness: 2.5),
            cursor: .resizeUpDown,
            onBegin: onBegin,
            onChange: { onChange($0.height) },
            onEnd: onEnd
        )
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let restart: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.symbol(.caption))
            Text(session.title)
                .lineLimit(1)
            // An exited shell used to be a dead tab that could only be closed.
            if !session.isRunning {
                Button(action: restart) {
                    Image(systemName: "arrow.clockwise")
                        .font(.symbol(.caption2, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Chrome.secondaryText)
                .help("Start a new shell in this tab")
                .accessibilityLabel(Text("Restart \(session.title)"))
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.symbol(.caption2, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Chrome.secondaryText)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close terminal")
            .accessibilityLabel(Text("Close \(session.title)"))
            // Hidden means unclickable, so a tab that shows no cross takes no tap
            // where its cross would be and selects like the rest of the tab.
            .allowsHitTesting(isHovering || isSelected)
        }
        .font(.ui(.callout))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(isSelected ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(Color.clear), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .opacity(session.isRunning ? 1 : 0.55)
        .help(Text(verbatim: session.isRunning ? session.title : String(format: Chrome.localized("%@ · the shell has exited"), session.title)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: session.isRunning ? session.title : String(format: Chrome.localized("%@, the shell has exited"), session.title)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Hosts a long-lived terminal view, moving it between containers as threads change.
/// The container coalesces the terminal's own re-wrap while the window resizes (see
/// `TerminalHostContainer`); outside a resize the view resizes exactly as before.
struct TerminalHost: NSViewRepresentable {
    @Environment(\.openURL) private var openURL
    let session: TerminalSession
    let runtime: ThreadRuntime
    let isDark: Bool
    var theme: AppTheme = .system
    var isSidebar = false
    private var location: TerminalLocation { isSidebar ? .sidebar : .bottom }
    /// Escape in the terminal with the shell at its prompt: the panel closes the way ⌘J
    /// closes it. A program in the foreground (vim, claude, less) gets its Escape as ever.
    let onEscapeAtPrompt: () -> Void

    final class Coordinator {
        weak var session: TerminalSession?
        var keyMonitor: Any?

        init(session: TerminalSession) { self.session = session }

        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSView {
        let container = TerminalHostContainer()
        attach(to: container)
        let view = session.view
        let onEscapeAtPrompt = onEscapeAtPrompt
        context.coordinator.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view, weak container] event in
            guard let view, let container, view.superview === container, event.keyCode == 53, // Escape
                  event.modifierFlags.intersection(KeyChord.allowedModifiers).isEmpty,
                  event.window?.firstResponder === view,
                  TerminalSession.foregroundJobIsTheShell(view.process.shellPid) else { return event }
            onEscapeAtPrompt()
            return nil
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let container = container as? TerminalHostContainer,
              session.viewPlacement.register(session.view, in: container, location: location, owner: session.location) else { return }
        let openURL = openURL
        session.view.onOpenURL = { openURL($0) }
        _ = AppFont.revision
        session.applyFont()
        session.applyAppearance(isDark: isDark, theme: theme)
        // A terminal the reader just opened takes the keyboard, once it is in its window;
        // a click elsewhere afterwards moves it as ever. Off the update, which may not
        // write the runtime.
        guard runtime.terminalFocusLocation == location else { return }
        let runtime = runtime
        let view = session.view
        Task { @MainActor in
            guard runtime.terminalFocusLocation == location, let window = view.window else { return }
            runtime.terminalFocusLocation = nil
            window.makeFirstResponder(view)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        if let container = container as? TerminalHostContainer, let session = coordinator.session {
            if session.view.superview === container { session.view.onOpenURL = nil }
            session.viewPlacement.unregister(session.view, from: container, owner: session.location)
        }
        if let monitor = coordinator.keyMonitor { NSEvent.removeMonitor(monitor) }
        coordinator.keyMonitor = nil
    }

    private func attach(to container: TerminalHostContainer) {
        guard session.viewPlacement.register(session.view, in: container, location: location, owner: session.location) else { return }
        let openURL = openURL
        session.view.onOpenURL = { openURL($0) }
        session.applyFont()
        session.applyAppearance(isDark: isDark, theme: theme)
    }
}

/// SwiftUI can update an outgoing host after its replacement has mounted, then
/// dismantle it. Only the session's explicit location may claim its native view.
@MainActor
final class TerminalViewPlacement {
    private struct Host {
        weak var container: TerminalHostContainer?
        let location: TerminalLocation
    }
    private var hosts: [Host] = []

    @discardableResult
    func register(_ view: NSView, in container: TerminalHostContainer, location: TerminalLocation, owner: TerminalLocation) -> Bool {
        hosts.removeAll { $0.container == nil }
        if !hosts.contains(where: { $0.container === container }) {
            hosts.append(Host(container: container, location: location))
        }
        synchronize(view, owner: owner)
        return view.superview === container
    }

    func unregister(_ view: NSView, from container: TerminalHostContainer, owner: TerminalLocation) {
        hosts.removeAll { $0.container == nil || $0.container === container }
        container.hostedView = nil
        if view.superview === container { view.removeFromSuperview() }
        synchronize(view, owner: owner)
    }

    private func synchronize(_ view: NSView, owner: TerminalLocation) {
        guard let destination = hosts.last(where: { $0.location == owner })?.container else {
            (view.superview as? TerminalHostContainer)?.hostedView = nil
            view.removeFromSuperview()
            return
        }
        if view.superview !== destination {
            (view.superview as? TerminalHostContainer)?.hostedView = nil
            view.removeFromSuperview()
            view.frame = destination.bounds
            view.autoresizingMask = [.width, .height]
            destination.addSubview(view)
        }
        destination.hostedView = view
    }
}

/// Holds the terminal view while the window resizes. SwiftTerm re-wraps its buffer on every
/// frame-size change, so a live resize that moved the frame every frame reflowed per frame.
/// While the drag lasts the view's autoresizing is parked, and its frame (hence one re-wrap)
/// lands at most every beat; the settled size lands once at the end.
final class TerminalHostContainer: NSView {
    /// The terminal view being held. Set on attach; nil only before the first one.
    weak var hostedView: NSView?
    /// A coalesced frame sync after the last beat, cancelled by the next one.
    private var pendingSync: DispatchWorkItem?
    /// Resize observers for this container's window, re-registered on window moves.
    private var resizeObservers: [NSObjectProtocol] = []

    // Isolated, so the main-actor state can be torn down here at all.
    isolated deinit {
        pendingSync?.cancel()
        for observer in resizeObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in resizeObservers { NotificationCenter.default.removeObserver(observer) }
        resizeObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        resizeObservers.append(center.addObserver(
            forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hostedView?.autoresizingMask = [] }
        })
        resizeObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishResize() }
        })
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard hostedView != nil, window?.inLiveResize == true else { return }
        // Autoresizing is parked, so without this the view would sit at its old size for
        // the whole drag; with it the frame (and its one re-wrap) follows at most per beat.
        guard pendingSync == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSync = nil
            self?.syncFrame()
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    /// The settled size, once: autoresizing back on and the frame replayed through the
    /// terminal view, so SwiftTerm recomputes its columns and rows a final time.
    private func finishResize() {
        pendingSync?.cancel()
        pendingSync = nil
        hostedView?.autoresizingMask = [.width, .height]
        syncFrame()
    }

    private func syncFrame() {
        guard let hostedView, hostedView.superview === self else { return }
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0, hostedView.frame != bounds else { return }
        hostedView.frame = bounds
    }
}
