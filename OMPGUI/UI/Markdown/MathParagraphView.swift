import AppKit
import SwiftUI

/// The text container stays at the visible width. Only its scrollable document
/// expands to expose oversized math attachments; neighbouring prose still wraps.
struct MathParagraphView: NSViewRepresentable {
    let paragraph: LinkParagraphView
    func makeCoordinator() -> LinkParagraphView.Coordinator { paragraph.makeCoordinator() }

    func makeNSView(context: Context) -> MathParagraphHost {
        let host = MathParagraphHost()
        host.paragraph.delegate = context.coordinator
        paragraph.onHost?(host.paragraph)
        return host
    }
    func updateNSView(_ view: MathParagraphHost, context: Context) {
        paragraph.updateTextView(view.paragraph, coordinator: context.coordinator, environment: context.environment)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MathParagraphHost, context: Context) -> CGSize? {
        let width: CGFloat
        if paragraph.hugsContent || proposal.width == nil || proposal.width?.isFinite == false {
            let natural = nsView.paragraph.naturalSize().width
            width = paragraph.hugsContent ? natural
                : proposal.width.flatMap { $0.isFinite && $0 > 0 ? min($0, natural) : nil } ?? natural
        } else { width = proposal.width! }
        guard width > 0 else { return .zero }
        return nsView.measure(width: width)
    }
    static func dismantleNSView(_ view: MathParagraphHost, coordinator: LinkParagraphView.Coordinator) {
        LinkParagraphView.dismantleNSView(view.paragraph, coordinator: coordinator)
    }
}

final class MathParagraphHost: NSScrollView {
    let paragraph = LinkTextView()
    private var usesNaturalWidth = false
    private let probeStorage = NSTextStorage()
    private let probeLayout = NSLayoutManager()
    private let probeContainer = NSTextContainer(size: .zero)
    private var probeRevision = UInt64.max
    private struct Key: Hashable { let width: CGFloat, wrapping: CGFloat }
    private struct Measurement {
        let size: NSSize, documentSize: NSSize
        let wrapping: CGFloat
        let scrolls: Bool
        let baselines: MarkdownBaselineMetrics.Snapshot?
    }
    private var measurements: [Key: Measurement] = [:]
    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        paragraph.autoresizingMask = []
        documentView = paragraph
        probeContainer.lineFragmentPadding = 0
        probeStorage.addLayoutManager(probeLayout)
        probeLayout.addTextContainer(probeContainer)
    }
    required init?(coder: NSCoder) { nil }

    func measure(width: CGFloat, contentWidth: CGFloat? = nil) -> NSSize {
        usesNaturalWidth = contentWidth != nil
        let measurement = measurement(width: width, contentWidth: contentWidth)
        if let baselines = measurement.baselines { paragraph.baselineMetrics?.store(baselines) }
        return measurement.size
    }

    /// SwiftUI makes speculative proposals, including Grid's intrinsic probes.
    /// None may resize the displayed document, change its text container, toggle
    /// a scroller or request native layout. Doing so creates a display-cycle loop.
    private func measurement(width: CGFloat, contentWidth: CGFloat? = nil) -> Measurement {
        if probeRevision != paragraph.layoutRevision {
            probeRevision = paragraph.layoutRevision
            probeStorage.setAttributedString(paragraph.textStorage ?? NSAttributedString())
            probeLayout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: probeStorage.length), actualCharacterRange: nil)
            measurements.removeAll(keepingCapacity: true)
        }
        let wrapping = contentWidth ?? width
        let key = Key(width: width, wrapping: wrapping)
        if let cached = measurements[key] { return cached }
        probeContainer.containerSize = NSSize(width: wrapping, height: .greatestFiniteMagnitude)
        probeLayout.ensureLayout(for: probeContainer)
        let height = ceil(probeLayout.usedRect(for: probeContainer).height)
        let expanded = MathRendering.overflowWidth(storage: probeStorage, layout: probeLayout, container: probeContainer, minimum: max(width, wrapping))
        let scrolls = expanded > width + 0.5
        let size = NSSize(width: width, height: height + (scrolls ? 14 : 0))
        let value = Measurement(size: size, documentSize: NSSize(width: expanded, height: size.height), wrapping: wrapping,
                                scrolls: scrolls, baselines: MarkdownBaselineMetrics.measure(layout: probeLayout, container: probeContainer))
        if measurements.count >= 8 { measurements.removeAll(keepingCapacity: true) }
        measurements[key] = value
        return value
    }
    private func actualMeasurement() -> Measurement {
        let natural = usesNaturalWidth ? paragraph.textStorage.map { MathRendering.formulaWidth(in: $0) } ?? 0 : 0
        return measurement(width: bounds.width, contentWidth: usesNaturalWidth ? max(bounds.width, natural) : nil)
    }
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.width.isFinite else { return }
        // Only the assigned viewport commits changes to the native text view.
        let value = actualMeasurement()
        paragraph.wrappingWidth = value.wrapping
        _ = paragraph.height(forWidth: value.wrapping)
        if hasHorizontalScroller != value.scrolls { hasHorizontalScroller = value.scrolls }
        if paragraph.frame.size != value.documentSize { paragraph.setFrameSize(value.documentSize) }
    }
    func mathGeometryChanged() {
        needsLayout = true
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: NSSize {
        guard bounds.width > 0, bounds.width.isFinite else { return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        return NSSize(width: NSView.noIntrinsicMetric, height: actualMeasurement().size.height)
    }
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), !event.modifierFlags.contains(.shift) {
            if let timeline = superview?.enclosingScrollView { timeline.scrollWheel(with: event) }
            else { nextResponder?.scrollWheel(with: event) }
        } else { super.scrollWheel(with: event) }
    }
}
