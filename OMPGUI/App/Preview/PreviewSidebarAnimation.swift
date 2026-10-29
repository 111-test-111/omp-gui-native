import AppKit
import QuartzCore
import SwiftUI

/// The same spring and reduced-motion timing as the conversation sidebar.
/// Sampling native geometry avoids rebuilding the file view on each frame.
struct PreviewSidebarSlide: Sendable {
    let from: CGFloat
    let to: CGFloat
    let velocity: CGFloat
    let started: TimeInterval
    let reducedMotion: Bool
    var duration: TimeInterval { reducedMotion ? 0.22 : 0.42 }

    func sample(at time: TimeInterval) -> (span: CGFloat, velocity: CGFloat, finished: Bool) {
        let elapsed = max(0, time - started)
        if elapsed >= duration { return (to, 0, true) }
        if reducedMotion {
            let progress = min(1, elapsed / 0.18)
            let eased = 1 - pow(1 - progress, 3)
            return (from + (to - from) * eased, 0, false)
        }
        let spring = Spring(response: 0.32, dampingRatio: 0.9)
        let position = spring.value(target: Double(to - from), initialVelocity: Double(velocity), time: elapsed)
        let speed = spring.velocity(target: Double(to - from), initialVelocity: Double(velocity), time: elapsed)
        return (from + CGFloat(position), CGFloat(speed), false)
    }
}

/// The file remains laid out at its final width. Only this outer viewport moves
/// and clips it, so wrapped text, PDF fit and images never resize during a slide.
final class PreviewSidebarClip: NSView {
    static let maximumSnapshotDimension: CGFloat = 2_048
    private let still = NSImageView()
    let reader: FrameHostingView
    private(set) var snapshotBytes = 0

    init(reader: FrameHostingView) {
        self.reader = reader
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        autoresizesSubviews = false
        still.imageScaling = .scaleAxesIndependently
        still.imageAlignment = .alignTopLeft
        still.isHidden = true
        addSubview(reader)
        addSubview(still)
    }

    required init?(coder: NSCoder) { nil }
    var hasSnapshot: Bool { still.image != nil }

    /// Capture before the store stops reading. The live document/player can be
    /// released immediately; a bounded viewport image lasts only for the slide.
    @discardableResult func freeze() -> Bool {
        if hasSnapshot { return true }
        let size = reader.bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        let scale = min(window?.backingScaleFactor ?? 2, Self.maximumSnapshotDimension / max(size.width, size.height))
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        bitmap.size = size
        reader.cacheDisplay(in: reader.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        still.image = image
        still.isHidden = false
        snapshotBytes = bitmap.bytesPerRow * bitmap.pixelsHigh
        return true
    }

    func discardSnapshot() {
        still.image = nil
        still.isHidden = true
        snapshotBytes = 0
    }

    func layOutReader(width: CGFloat, height: CGFloat, topInset: CGFloat = 0) {
        let frame = NSRect(x: 0, y: isFlipped ? topInset : 0, width: width, height: max(0, height - topInset))
        if reader.frame != frame { reader.frame = frame }
        if still.frame != frame { still.frame = frame }
    }
}

/// The conversation, composer and floating panels share one final layout width.
/// Moving the native viewport/host origin does not resize their SwiftUI tree.
final class SidebarChatClip: NSView {
    let chat: FrameHostingView

    init(chat: FrameHostingView) {
        self.chat = chat
        super.init(frame: .zero)
        clipsToBounds = true
        autoresizesSubviews = false
        chat.autoresizingMask = []
        addSubview(chat)
    }

    required init?(coder: NSCoder) { nil }

    func layOutChat(width: CGFloat, height: CGFloat) {
        let frame = NSRect(x: (bounds.width - width) / 2, y: 0, width: width, height: height)
        if chat.frame != frame { chat.frame = frame }
    }
}

final class PreviewSplitView: NSSplitView {
    weak var chat: FrameHostingView?
    weak var chatClip: SidebarChatClip?
    weak var reader: FrameHostingView?
    weak var previewClip: PreviewSidebarClip?
    weak var liveResize: WindowLiveResize?
    var preferredWidth: CGFloat = 480
    private(set) var isFullscreen = false
    private(set) var showsConversation = true
    var fullscreenHeaderHeight: CGFloat = 0

    func setFullscreen(_ fullscreen: Bool, showsConversation: Bool) {
        guard isFullscreen != fullscreen || self.showsConversation != showsConversation else { return }
        finishVisibilityTransition()
        isFullscreen = fullscreen
        self.showsConversation = showsConversation
        resizeSubviews(withOldSize: bounds.size)
        // A tab switch cannot leave keyboard input in the newly hidden host.
        if let responder = window?.firstResponder as? NSView {
            let hidden = fullscreen && !showsConversation ? chat : reader
            if let hidden, responder === hidden || responder.isDescendant(of: hidden), hidden.isHiddenOrHasHiddenAncestor {
                window?.makeFirstResponder(fullscreen && !showsConversation ? reader : chat)
            }
        }
    }
    /// Supplied from the window's final sidebar state, never its animated width.
    /// Both native readers keep this geometry while the left viewport changes.
    var conversationSlideTargetWidth: CGFloat?
    var lastVisible: Bool?
    var presentedContext: FilePreviewContext?
    var scopeChanged: (() -> Void)?
    private(set) var revealedSpan: CGFloat = 0
    private(set) var targetVisible = false
    private(set) var needsVisibilityUpdate = false
    private var slide: PreviewSidebarSlide?
    private var animationTask: Task<Void, Never>?
    private var generation = 0
    private var interruptedVelocity: CGFloat = 0
    private var chatTargetSpan: CGFloat?
    private var laidOutSize: NSSize = .zero
    private var frozenIdentity: String?
    var presentationIdentity: String? {
        didSet {
            if targetVisible, frozenIdentity != presentationIdentity { previewClip?.discardSnapshot() }
        }
    }

    isolated deinit { animationTask?.cancel() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowScope()
    }

    func installWindowScope() { scopeChanged?() }
    var isSliding: Bool { slide != nil }
    var canAnimateVisibility: Bool {
        window?.isVisible == true && window?.inLiveResize != true
            && liveResize?.isActive != true && liveResize?.isPaneResizing != true && liveResize?.isPreviewResizing != true
    }
    func requiresVisibilityUpdate(_ visible: Bool) -> Bool {
        lastVisible != visible || needsVisibilityUpdate || (visible && reader?.isHidden == true)
    }

    /// Preserve the intent even if SwiftUI coalesces false → true into the last
    /// presented value. The live reader may already have been released.
    func visibilityWillChange(_ visible: Bool) {
        needsVisibilityUpdate = true
        if visible { interruptVisibilityTransition() }
        else { _ = prepareClosingVisual() }
    }

    override var dividerThickness: CGFloat { isFullscreen ? 0 : min(super.dividerThickness, max(0, revealedSpan)) }

    override func drawDivider(in rect: NSRect) {
        guard !isFullscreen, revealedSpan > 0.5 else { return }
        super.drawDivider(in: rect)
    }

    private var fullReaderWidth: CGFloat {
        if isFullscreen { return layoutWidth }
        let total = max(0, layoutWidth - super.dividerThickness)
        let minimum = min(400, total / 2)
        let leftMinimum = min(320, total / 2)
        return min(max(minimum, preferredWidth), max(minimum, total - leftMinimum))
    }
    private var layoutWidth: CGFloat { max(0, conversationSlideTargetWidth ?? bounds.width) }
    private var fullSpan: CGFloat { min(layoutWidth, fullReaderWidth + super.dividerThickness) }

    /// A synchronous visibility intent cancels the old completion before the
    /// next SwiftUI update, including rapid reopen just before a close finishes.
    func interruptVisibilityTransition() {
        if let slide {
            let sample = slide.sample(at: CACurrentMediaTime())
            revealedSpan = min(fullSpan, max(0, sample.span))
            interruptedVelocity = sample.velocity
        }
        generation &+= 1
        animationTask?.cancel()
        animationTask = nil
        slide = nil
        resizeSubviews(withOldSize: bounds.size)
    }

    @discardableResult func prepareClosingVisual() -> Bool {
        interruptVisibilityTransition()
        guard !isFullscreen, canAnimateVisibility, revealedSpan > 0, previewClip?.freeze() == true else { return false }
        frozenIdentity = presentationIdentity
        reader?.rootView = AnyView(Color.clear)
        reader?.isHidden = true
        reader?.layoutSubtreeIfNeeded()
        return true
    }

    func setPreviewVisible(_ visible: Bool, animated: Bool, reducedMotion: Bool? = nil) {
        interruptVisibilityTransition()
        needsVisibilityUpdate = false
        targetVisible = visible
        if visible, frozenIdentity != presentationIdentity { previewClip?.discardSnapshot() }
        let destination = visible ? fullSpan : 0
        let canSlide = !isFullscreen && animated && (visible || previewClip?.hasSnapshot == true) && abs(destination - revealedSpan) > 0.5
        guard canSlide else { finishVisibilityTransition(); return }
        generation &+= 1
        let current = generation
        slide = PreviewSidebarSlide(from: revealedSpan, to: destination, velocity: interruptedVelocity,
                                    started: CACurrentMediaTime(), reducedMotion: reducedMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        chatTargetSpan = destination
        interruptedVelocity = 0
        liveResize?.previewSlideDelta = revealedSpan - destination
        liveResize?.isPreviewSliding = true
        previewClip?.isHidden = false
        resizeSubviews(withOldSize: bounds.size)
        guard generation == current, slide != nil else { return }
        animationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.advanceVisibilityTransition(generation: current) == true else { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func advanceVisibilityTransition(generation current: Int) -> Bool {
        guard generation == current, let slide else { return false }
        let sample = slide.sample(at: CACurrentMediaTime())
        revealedSpan = min(fullSpan, max(0, sample.span))
        resizeSubviews(withOldSize: bounds.size)
        if sample.finished { finishVisibilityTransition(); return false }
        return true
    }

    func finishVisibilityTransition() {
        generation &+= 1
        animationTask?.cancel()
        animationTask = nil
        slide = nil
        chatTargetSpan = nil
        interruptedVelocity = 0
        needsVisibilityUpdate = false
        revealedSpan = targetVisible ? fullSpan : 0
        liveResize?.isPreviewSliding = false
        liveResize?.previewSlideDelta = 0
        previewClip?.discardSnapshot()
        frozenIdentity = nil
        if !targetVisible {
            reader?.rootView = AnyView(Color.clear)
            reader?.isHidden = true
        }
        resizeSubviews(withOldSize: bounds.size)
    }

    func hideImmediately() {
        targetVisible = false
        finishVisibilityTransition()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard let chatClip, let previewClip else { return }
        if slide != nil, laidOutSize != .zero, laidOutSize != bounds.size,
           conversationSlideTargetWidth == nil || laidOutSize.height != bounds.height {
            finishVisibilityTransition()
            return
        }
        laidOutSize = bounds.size
        if slide == nil, animationTask == nil {
            // Interrupted motions retain their presentation span until retargeted.
            if liveResize?.isPreviewSliding != true { revealedSpan = targetVisible ? fullSpan : 0 }
        }
        chatClip.isHidden = isFullscreen && !showsConversation && targetVisible
        if isFullscreen, targetVisible {
            chatClip.frame = bounds
            chatClip.layOutChat(width: layoutWidth, height: bounds.height)
            // NSSplitView requires arranged views to span its cross axis.
            // Reserve the toolbar inside the clip so AppKit never corrects
            // its height and pulls the reader back underneath the tabs.
            previewClip.frame = bounds
            previewClip.layOutReader(width: layoutWidth, height: bounds.height, topInset: fullscreenHeaderHeight)
            previewClip.isHidden = showsConversation
            needsDisplay = true
            return
        }
        let span = min(bounds.width, max(0, revealedSpan))
        let viewport = NSRect(x: 0, y: 0, width: max(0, bounds.width - span), height: bounds.height)
        if chatClip.frame != viewport { chatClip.frame = viewport }
        chatClip.layOutChat(width: max(0, layoutWidth - (chatTargetSpan ?? revealedSpan)), height: bounds.height)
        previewClip.frame = NSRect(x: bounds.width - span + dividerThickness, y: 0,
                                   width: max(0, span - dividerThickness), height: bounds.height)
        previewClip.isHidden = span == 0 && slide == nil
        previewClip.layOutReader(width: fullReaderWidth, height: bounds.height)
        needsDisplay = true
    }

    override func viewWillStartLiveResize() {
        finishVisibilityTransition()
        super.viewWillStartLiveResize()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isFullscreen else { return }
        finishVisibilityTransition()
        liveResize?.isPreviewResizing = true
        defer { liveResize?.isPreviewResizing = false }
        super.mouseDown(with: event)
    }
}
