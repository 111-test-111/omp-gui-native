import AppKit
import SwiftUI

/// Native frosted material, independent of the main window's opacity setting.
struct PopoverBackdropStyle: Equatable {
    let isSolid: Bool

    init(performanceMode: Bool, reduceTransparency: Bool) {
        isSolid = performanceMode || reduceTransparency
    }
}

extension View {
    /// Keep all SwiftUI presentations on the same background path as native NSPopovers.
    func chromePopover<Content: View>(
        isPresented: Binding<Bool>,
        attachmentAnchor: PopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: Edge? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        popover(isPresented: isPresented, attachmentAnchor: attachmentAnchor, arrowEdge: arrowEdge) {
            content().popoverChrome()
        }
    }

    /// Apply only to the root content of a popover, never a sheet or main window.
    func popoverChrome() -> some View {
        presentedChrome().background { PopoverBackdrop() }
    }
}

private struct PopoverBackdrop: NSViewRepresentable {
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard)
    private var performanceMode = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> PopoverBackdropProbe {
        PopoverBackdropProbe()
    }

    func updateNSView(_ view: PopoverBackdropProbe, context: Context) {
        view.style = PopoverBackdropStyle(performanceMode: performanceMode,
                                         reduceTransparency: reduceTransparency)
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: PopoverBackdropProbe, coordinator: ()) {
        view.stop()
    }
}

/// Only the native background is changed. NSVisualEffectView.maskImage masks its
/// material, explicitly excluding subviews, so controls, text and media stay opaque.
/// Native shape masks, arrows, event handling and popover sizing stay with AppKit.
@MainActor
final class PopoverBackdropProbe: NSView {
    var style = PopoverBackdropStyle(performanceMode: false, reduceTransparency: false)
    private weak var styledWindow: NSWindow?
    private var originalWindowColor: NSColor?
    private var originalWindowIsOpaque = false
    private var materials: [MaterialState] = []
    private var glasses: [GlassState] = []
    private var updatePending = false
    private var isActive = true
    private var appliedStyle: PopoverBackdropStyle?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window !== styledWindow { restore() }
        scheduleUpdate()
    }

    override func layout() {
        super.layout()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        guard isActive, !updatePending else { return }
        updatePending = true
        Task { @MainActor [weak self] in
            guard let self, isActive else { return }
            updatePending = false
            apply()
        }
    }

    func stop() {
        isActive = false
        restore()
    }

    private func apply() {
        guard let window, let frame = window.contentView?.superview else { return }
        // A hosting controller's view is the presentation content. Do not descend
        // into it: a button/field's own effect must never become a background target.
        var responder: NSResponder? = self
        var contentRoot: NSView?
        for _ in 0..<64 {
            guard let current = responder else { break }
            if let controller = current as? NSViewController {
                contentRoot = controller.view
                break
            }
            responder = current.nextResponder
        }
        guard let contentRoot else { return }
        apply(to: window, frame: frame, excluding: contentRoot)
    }

    /// Kept independent of showing a popover so ownership, masks and fallbacks can
    /// also be verified in an invisible AppKit window.
    func apply(to window: NSWindow, frame: NSView, excluding content: NSView) {
        if styledWindow !== window {
            restore()
            styledWindow = window
            originalWindowColor = window.backgroundColor
            originalWindowIsOpaque = window.isOpaque
        }
        var remaining = 256
        func visit(_ view: NSView) {
            guard view !== content, remaining > 0 else { return }
            remaining -= 1
            if let material = view as? NSVisualEffectView,
               !materials.contains(where: { $0.view === material }) {
                materials.append(MaterialState(material))
            }
            if let glass = view as? NSGlassEffectView,
               !glasses.contains(where: { $0.view === glass }) {
                glasses.append(GlassState(glass))
            }
            for child in view.subviews { visit(child) }
        }
        visit(frame)
        guard !materials.isEmpty || !glasses.isEmpty else { return }
        // Modern native popovers have a glass background inside a legacy visual-
        // effect frame, with the app's content beside it. Treat that glass as the
        // single background. Fading both layers or adding an opaque tint makes
        // the combined result almost solid again.
        let independentGlass = glasses.filter { state in
            guard let view = state.view else { return false }
            return !content.isDescendant(of: view)
        }
        // An opaque window base would hide the alpha in the native material.
        window.isOpaque = false
        window.backgroundColor = .clear
        for material in materials { material.apply(style, suppressed: !independentGlass.isEmpty) }
        for glass in glasses {
            let isBackground = independentGlass.contains { $0 === glass }
            let isNested = independentGlass.contains { other in
                guard other !== glass, let view = glass.view, let ancestor = other.view else { return false }
                return view.isDescendant(of: ancestor)
            }
            if !isNested { glass.apply(style, backgroundOnly: isBackground) }
        }
        if appliedStyle != style { window.invalidateShadow() }
        appliedStyle = style
    }

    func restore() {
        for material in materials { material.restore() }
        for glass in glasses { glass.restore() }
        materials.removeAll()
        glasses.removeAll()
        if let window = styledWindow, let originalWindowColor {
            window.backgroundColor = originalWindowColor
            window.isOpaque = originalWindowIsOpaque
        }
        styledWindow = nil
        originalWindowColor = nil
        appliedStyle = nil
    }

    @MainActor private final class MaterialState {
        weak var view: NSVisualEffectView?
        var originalMask: NSImage?
        let originalMaterial: NSVisualEffectView.Material
        let originalBlending: NSVisualEffectView.BlendingMode
        let originalState: NSVisualEffectView.State
        var appliedMask: NSImage?
        var appliedStyle: PopoverBackdropStyle?
        var isSuppressed = false

        init(_ view: NSVisualEffectView) {
            self.view = view
            originalMask = view.maskImage
            originalMaterial = view.material
            originalBlending = view.blendingMode
            originalState = view.state
        }

        func apply(_ style: PopoverBackdropStyle, suppressed: Bool) {
            guard let view else { return }
            let shapeChanged = view.maskImage !== appliedMask
            if shapeChanged { originalMask = view.maskImage }
            guard shapeChanged || appliedStyle != style || isSuppressed != suppressed else { return }
            view.material = style.isSolid ? .windowBackground : .popover
            view.blendingMode = style.isSolid ? .withinWindow : .behindWindow
            view.state = style.isSolid ? .inactive : .active
            let mask = originalMask
            // Preserve full material coverage. Fading a blur layer blends sharp
            // pixels from behind the window back into the finished backdrop.
            let alpha: CGFloat = suppressed ? 0 : 1
            let size = mask?.size ?? NSSize(width: 1, height: 1)
            let coverage = NSImage(size: size, flipped: false) { rect in
                if let mask {
                    mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
                } else {
                    NSColor.white.withAlphaComponent(alpha).setFill()
                    rect.fill()
                }
                return true
            }
            coverage.capInsets = mask?.capInsets ?? NSEdgeInsets()
            coverage.resizingMode = mask?.resizingMode ?? .stretch
            appliedMask = coverage
            view.maskImage = coverage
            appliedStyle = style
            isSuppressed = suppressed
        }

        func restore() {
            guard let view else { return }
            if view.maskImage === appliedMask { view.maskImage = originalMask }
            view.material = originalMaterial
            view.blendingMode = originalBlending
            view.state = originalState
        }
    }

    /// Newer systems may expose their existing popover background as glass.
    /// Adjust only that native background; never add glass to a large container.
    @MainActor private final class GlassState {
        weak var view: NSGlassEffectView?
        let originalStyle: NSGlassEffectView.Style
        let originalTint: NSColor?
        let originalAlpha: CGFloat
        var appliedStyle: PopoverBackdropStyle?
        var wasBackgroundOnly: Bool?

        init(_ view: NSGlassEffectView) {
            self.view = view
            originalStyle = view.style
            originalTint = view.tintColor
            originalAlpha = view.alphaValue
        }

        func apply(_ style: PopoverBackdropStyle, backgroundOnly: Bool) {
            guard let view, appliedStyle != style || wasBackgroundOnly != backgroundOnly else { return }
            // Regular glass provides blur and contrast for text-heavy popovers.
            // Clear glass and a faded effect let the underlying text remain legible.
            view.style = style.isSolid ? originalStyle : .regular
            view.tintColor = style.isSolid ? .windowBackgroundColor : originalTint
            view.alphaValue = backgroundOnly ? 1 : originalAlpha
            appliedStyle = style
            wasBackgroundOnly = backgroundOnly
        }

        func restore() {
            view?.style = originalStyle
            view?.tintColor = originalTint
            view?.alphaValue = originalAlpha
        }
    }
}
