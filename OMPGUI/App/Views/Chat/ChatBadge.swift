import AppKit
import SwiftUI

/// A pill like the Hydra badges in the conversation: an optional glyph, a title,
/// an optional caption and a chevron, opening its detail in a popover. `tint`
/// recolors the fill and title for a semantic kind (amber approval, purple
/// question); nil keeps the theme accent.
/// `needsAttention` means the reader has to do something here: the accent dot
/// wave runs along the badge's top quarter, in the theme's accent, until it is
/// dealt with.
struct ChatBadge<Glyph: View, Detail: View>: View {
    let title: String
    var caption: String? = nil
    /// A semantic color for the fill and title; nil follows the window's accent.
    var tint: Color? = nil
    var showsChevron = true
    var needsAttention = false
    var isEnabled = true
    /// The detail's fixed width when its popover should track the content's height
    /// live (the ask sheet's pages) instead of freezing at the opening measurement.
    var liveDetailWidth: CGFloat? = nil
    @Binding var isPresented: Bool
    @ViewBuilder let glyph: () -> Glyph
    @ViewBuilder let detail: () -> Detail

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coordinator = BadgePopoverCoordinator()

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                if Glyph.self != EmptyView.self {
                    glyph()
                        .frame(width: 18, height: 18)
                }
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(.callout, weight: .medium))
                    .foregroundStyle(tint ?? Chrome.primaryText.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let caption {
                    Text(verbatim: Chrome.localized(caption))
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if showsChevron {
                    Image(systemName: "chevron.right").font(.symbol(.caption2, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            // The whole pill takes the click, padding included, as the Hydra pills do.
            .padding(.leading, TimelineMetrics.pillLeading)
            .padding(.trailing, TimelineMetrics.pillTrailing)
            .padding(.vertical, TimelineMetrics.pillVertical)
            .background(fill, in: RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .overlay(alignment: .top) {
            if needsAttention {
                GeometryReader { proxy in
                    DotFieldLayerView.Representable(color: Chrome.accentNSColor, animated: !reduceMotion)
                        .scaleEffect(y: -1)
                        .frame(height: proxy.size.height * 0.25)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
        .windowRectAnchor { coordinator.setAnchor(windowRect: $0) }
        .onChange(of: isPresented) { _, shown in
            if shown {
                if !coordinator.isShown {
                    if let liveDetailWidth {
                        coordinator.showFollowingContentHeight(detail(), width: liveDetailWidth)
                    } else {
                        coordinator.show(detail().presentedChrome())
                    }
                }
            } else {
                coordinator.close()
            }
        }
        .onAppear { coordinator.onClose = { isPresented = false } }
        .onDisappear { coordinator.close() }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 96)
        .accessibilityLabel(Text(verbatim: Chrome.localized(title)))
        .accessibilityValue(Text(verbatim: needsAttention ? Chrome.localized("Needs your attention") : ""))
    }

    private var fill: AnyShapeStyle {
        if let tint { AnyShapeStyle(tint.opacity(0.12)) } else { AnyShapeStyle(.tint.opacity(0.1)) }
    }
}

extension ChatBadge where Glyph == EmptyView {
    /// A badge without a glyph: color and text carry its kind.
    init(title: String, caption: String? = nil, tint: Color? = nil, showsChevron: Bool = true,
         needsAttention: Bool = false, isEnabled: Bool = true, isPresented: Binding<Bool>,
         liveDetailWidth: CGFloat? = nil, @ViewBuilder detail: @escaping () -> Detail) {
        self.init(title: title, caption: caption, tint: tint, showsChevron: showsChevron,
                  needsAttention: needsAttention, isEnabled: isEnabled, liveDetailWidth: liveDetailWidth,
                  isPresented: isPresented, glyph: { EmptyView() }, detail: detail)
    }
}

extension View {
    /// `detail` as the anchored popover the chat's pills open (see `BadgePopoverCoordinator`),
    /// for a pill that draws itself rather than through `ChatBadge`: it hangs from this
    /// view's window rect with the popover's own animation, growing out of the pill. A
    /// SwiftUI `.popover` on the same pill came in from the top edge instead.
    func badgePopover(isPresented: Binding<Bool>, liveDetailWidth: CGFloat? = nil, dismissDisabled: Bool = false,
                      usesViewAnchor: Bool = false,
                      @ViewBuilder detail: @escaping () -> some View) -> some View {
        modifier(BadgePopoverModifier(isPresented: isPresented, liveDetailWidth: liveDetailWidth,
                                      dismissDisabled: dismissDisabled, usesViewAnchor: usesViewAnchor, detail: { AnyView(detail()) }))
    }
}

private struct BadgePopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let liveDetailWidth: CGFloat?
    let dismissDisabled: Bool
    let usesViewAnchor: Bool
    let detail: () -> AnyView
    @State private var coordinator = BadgePopoverCoordinator()
    @State private var presentationTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background {
                if usesViewAnchor {
                    AttachmentAnchorCapture {
                        coordinator.setAnchor(view: $0)
                        if isPresented, !coordinator.isShown { schedulePresentation() }
                    }
                }
            }
            .windowRectAnchor {
                coordinator.setAnchor(windowRect: $0)
                if isPresented, !coordinator.isShown { schedulePresentation() }
            }
            .onChange(of: isPresented, initial: true) { _, shown in
                presentationTask?.cancel()
                if shown {
                    schedulePresentation()
                } else {
                    coordinator.close()
                }
            }
            .onAppear { coordinator.onClose = { isPresented = false } }
            .onChange(of: dismissDisabled, initial: true) { _, disabled in coordinator.dismissDisabled = disabled }
            .onDisappear { presentationTask?.cancel(); presentationTask = nil; coordinator.close() }
    }

    private func schedulePresentation() {
        presentationTask?.cancel()
        // A newly configured OAuth row can mount with its login already requested.
        // Wait until its window anchor exists and the current SwiftUI layout has finished.
        presentationTask = Task { @MainActor in
            guard !Task.isCancelled, isPresented, !coordinator.isShown else { return }
            if let liveDetailWidth {
                coordinator.showFollowingContentHeight(detail(), width: liveDetailWidth)
            } else {
                coordinator.show(detail().presentedChrome())
            }
            presentationTask = nil
        }
    }
}

/// The badge's detail as an anchored popover instead of a SwiftUI popover, so
/// the arrow starts on the badge. Content is measured once and frozen (see
/// setFixedContent), or — via showFollowingContentHeight — followed in height
/// as its pages change, re-anchored so the bottom edge never moves.
@MainActor
final class BadgePopoverCoordinator: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var anchorRect: CGRect?
    private weak var anchorView: NSView?
    private var monitors: [Any] = []
    private weak var shownIn: NSWindow?
    private var shownRect: NSRect = .zero
    var onClose: (() -> Void)?
    var dismissDisabled = false

    override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    func setAnchor(windowRect: CGRect) {
        anchorRect = windowRect
    }

    func setAnchor(view: NSView) {
        anchorView = view
    }

    private func resolvedAnchor() -> (view: NSView, rect: NSRect)? {
        if let anchorView {
            guard let content = anchorView.window?.contentView else { return nil }
            return (content, content.convert(anchorView.bounds, from: anchorView))
        }
        return anchorRect.flatMap(WindowRectAnchor.target(for:))
    }

    var isShown: Bool { popover.isShown }

    func show<Content: View>(_ content: Content) {
        guard let anchor = resolvedAnchor() else { return }
        // Opened again while the last one is still fading out: that one goes at once.
        if popover.isShown { popover.close() }
        // The content closes the popover itself through the environment (a sheet that
        // answers, a card whose button acts), the way rows in an AppKit popover do.
        let content = content.environment(\.closePopover, { [weak self] in self?.close() })
        var size = NSHostingView(rootView: content.font(.ui(.body))).fittingSize
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: 460, height: 320) }
        popover.setFixedContent(content, size: size)
        shownIn = anchor.view.window
        shownRect = anchor.view.convert(anchor.rect, to: nil)
        let edge = PopoverPlacement.edge(contentSize: size, relativeTo: anchor.rect, of: anchor.view,
                                         preferred: anchor.view.isFlipped ? .minY : .maxY)
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: edge)
        startMonitors()
    }

    /// The ask sheet's variant: pinned to `width`, the panel's height follows the
    /// content's own as its pages change. The arrow stays on the badge, so the
    /// footer keeps its place while the top edge takes the difference.
    func showFollowingContentHeight<Content: View>(_ content: Content, width: CGFloat) {
        guard let anchor = resolvedAnchor() else { return }
        if popover.isShown { popover.close() }
        let content = content
            .environment(\.closePopover, { [weak self] in self?.close() })
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                Task { @MainActor [weak self] in self?.resize(toHeight: height) }
            }
            .popoverChrome()
        // As in setFixedContent: the hosting controller never publishes a size of
        // its own, contentSize is the only one AppKit positions against.
        let host = NSHostingController(rootView: content)
        host.sizingOptions = []
        popover.contentViewController = host
        var size = host.view.fittingSize
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: width, height: 320) }
        popover.contentSize = size
        shownIn = anchor.view.window
        shownRect = anchor.view.convert(anchor.rect, to: nil)
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.view.isFlipped ? .minY : .maxY)
        startMonitors()
    }

    /// A content-driven height change re-anchors the shown popover: setting
    /// contentSize alone lets AppKit pick the fixed point, which can slide the
    /// arrow off the badge. Re-showing pins the arrow — and with it the footer's
    /// bottom edge — so the new height only moves the top edge. Re-showing a
    /// shown popover moves it without replaying the appearance (see
    /// AttachmentPreviewPanel).
    private func resize(toHeight height: CGFloat) {
        guard popover.isShown, height > 0, abs(popover.contentSize.height - height) > 0.5,
              let anchor = resolvedAnchor() else { return }
        popover.contentSize = NSSize(width: popover.contentSize.width, height: height)
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.view.isFlipped ? .minY : .maxY)
    }

    /// Closes on the popover's own animation; `onClose` follows once it has closed (see
    /// `popoverDidClose`), once, whichever way it went.
    func close() {
        guard popover.isShown else { return }
        stopMonitors()
        popover.performClose(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            // An older close notification may arrive after a rapid reopen.
            guard let self, !popover.isShown else { return }
            stopMonitors()
            popover.contentViewController = nil
            onClose?()
        }
    }

    private func startMonitors() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // Escape in the popover or the chat window it hangs from; another window's
            // Escape (Settings, a file picker) is that window's own.
            guard let self, event.keyCode == 53, // Escape
                  event.window === shownIn || event.window === popover.contentViewController?.view.window
            else { return event }
            if !dismissDisabled { close() }
            return nil
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            self?.handleMouseDown(event) ?? event
        }) {
            monitors.append(monitor)
        }
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let shownIn, window === shownIn else { return event }
        if shownRect.contains(event.locationInWindow) { return event }
        if !dismissDisabled { close() }
        return event
    }

    private func stopMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}
