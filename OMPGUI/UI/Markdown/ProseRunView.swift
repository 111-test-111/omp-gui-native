import AppKit
import SwiftUI

struct ProseRunView: View {
    let blocks: [MarkdownBlock]
    @Environment(\.markdownPointSize) private var pointSize
    @Environment(\.markdownDimmed) private var dimmed
    @Environment(\.hydraMentionPersonas) private var hydraMentionPersonas
    @Environment(\.hydraMentionTargets) private var hydraMentionTargets
    @Environment(\.openURL) private var openURL
    @State private var linkView = WeakView()
    @State private var showsHand = false
    @State private var hoveredHeadID: UUID?
    @State private var faviconRevision = 0

    var body: some View {
        let _ = AppFont.revision
        let resolvedSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        let scaled = (resolvedSize * 2).rounded() / 2
        let sources = ProseRunRepresentable.joinedSources(blocks)
        let linkKey = RichLink.linkAssetKey(for: sources)
        let linkBox = linkView
        let targets = hydraMentionTargets
        let prose = ProseRunRepresentable(blocks: blocks, pointSize: scaled, dimmed: dimmed, revision: faviconRevision, mentions: hydraMentionPersonas, targets: hydraMentionTargets, onOpenHead: { url in openURL(url) }, onHost: { [weak linkBox] view in linkBox?.value = view })
        Group {
            if MarkdownMath.contains(sources) { MathProseRunRepresentable(prose: prose) }
            else { prose }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LinkHoverModifier(linkView: linkBox, showsHand: $showsHand, hoveredHeadID: $hoveredHeadID, personas: hydraMentionPersonas, targets: targets))
            .task(id: linkKey) { [sources, linkKey, revision = $faviconRevision] in
                if !linkKey.isEmpty {
                    await InlineText.fetchLinkAssets(source: sources, streaming: false, revision: revision)
                }
            }
    }
}

struct ProseRunRepresentable: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    var pointSize: CGFloat = TypeScale.shared.content(13)
    var codePointSize: CGFloat = TypeScale.shared.code(12)
    var dimmed: Bool = false
    var revision: Int = 0
    var mentions: [HydraPersona] = []
    var targets: [String: HydraMentionTarget] = [:]
    var onOpenHead: ((URL) -> Void)?
    var onHost: ((LinkTextView) -> Void)?

    func makeCoordinator() -> LinkParagraphView.Coordinator {
        LinkParagraphView.Coordinator()
    }

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView()
        configure(view, coordinator: context.coordinator, environment: context.environment)
        return view
    }

    func configure(_ view: LinkTextView, coordinator: LinkParagraphView.Coordinator, environment: EnvironmentValues) {
        view.delegate = coordinator
        view.passesProseThrough = false
        onHost?(view)
        view.mergeTarget = environment.mergeRequestTarget
        view.filePreviewAction = environment.filePreviewAction
        view.filePreviewContext = environment.filePreviewContext
        let openURL = environment.openURL
        view.onOpenURL = { openURL($0) }
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        updateTextView(view, coordinator: context.coordinator, environment: context.environment)
    }

    func updateTextView(_ view: LinkTextView, coordinator: LinkParagraphView.Coordinator, environment: EnvironmentValues) {
        view.selectionOwner = environment.markdownSelectionOwner
        view.mathPreparation = environment.markdownVeiled ? nil : environment.chatMathPreparation
        _ = revision
        let source = Self.joinedSources(blocks)
        let mentionNames = mentions.map(\.name)
        let headLinks = targets.mapValues(\.url)
        let accent = Chrome.accentNSColor
        let fontRevision = AppFont.revision
        if coordinator.renderedView !== view
            || coordinator.lastBlocks != blocks || coordinator.lastPointSize != pointSize
            || coordinator.lastCodePointSize != codePointSize
            || coordinator.lastDimmed != dimmed || coordinator.lastRevision != revision
            || coordinator.lastFontRevision != fontRevision
            || coordinator.lastAccent != accent
            || coordinator.lastMentions != mentionNames || coordinator.lastHeads != headLinks {
            coordinator.lastSource = source
            coordinator.lastBlocks = blocks
            coordinator.lastPointSize = pointSize
            coordinator.lastCodePointSize = codePointSize
            coordinator.lastDimmed = dimmed
            coordinator.lastRevision = revision
            coordinator.lastFontRevision = fontRevision
            coordinator.lastAccent = accent
            coordinator.lastMentions = mentionNames
            coordinator.lastHeads = headLinks
            view.render(Self.attributed(blocks: blocks, pointSize: pointSize, dimmed: dimmed, mentions: mentions, targets: targets))
            coordinator.renderedView = view
        }
        // Outside the render check: the click handler is the environment's, and a new one
        // must land even on an update that drew nothing.
        view.onOpenHead = onOpenHead
        view.mergeTarget = environment.mergeRequestTarget
        view.filePreviewAction = environment.filePreviewAction
        view.filePreviewContext = environment.filePreviewContext
        let openURL = environment.openURL
        view.onOpenURL = { openURL($0) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LinkTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.measuredHeight(forWidth: width))
    }

    static func dismantleNSView(_ view: LinkTextView, coordinator: LinkParagraphView.Coordinator) {
        MathRendering.detach(from: view)
        view.selectionOwner = nil
        view.delegate = nil
        view.onOpenHead = nil
        view.mergeTarget = nil
        view.filePreviewAction = FilePreviewAction()
        view.filePreviewContext = nil
        view.onOpenURL = nil
    }

    static func joinedSources(_ blocks: [MarkdownBlock]) -> String {
        var parts: [String] = []
        collect(blocks, into: &parts)
        return parts.joined(separator: "\n")
    }

    private static func collect(_ blocks: [MarkdownBlock], into parts: inout [String]) {
        for block in blocks {
            switch block {
            case .paragraph(let text), .heading(_, let text):
                parts.append(text)
            case .list(_, _, let items):
                for item in items {
                    parts.append(item.text)
                    collect(item.children, into: &parts)
                }
            case .quote(let inner), .alert(_, let inner):
                collect(inner, into: &parts)
            case .code, .math, .table, .rule:
                break
            }
        }
    }

    @MainActor
    static func attributed(blocks: [MarkdownBlock], pointSize: CGFloat, dimmed: Bool, mentions: [HydraPersona], targets: [String: HydraMentionTarget] = [:]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for block in blocks {
            append(block, depth: 0, indent: 0, dimmed: dimmed, spacing: MarkdownParagraphLayout.blockSpacing, pointSize: pointSize, mentions: mentions, targets: targets, to: out)
        }
        return out
    }

    @MainActor
    private static func append(_ block: MarkdownBlock, depth: Int, indent: CGFloat, dimmed: Bool, spacing: CGFloat, pointSize: CGFloat, mentions: [HydraPersona], targets: [String: HydraMentionTarget], to out: NSMutableAttributedString) {
        let base = NSFont.systemFont(ofSize: pointSize)
        let color = dimmed ? NSColor.labelColor.withAlphaComponent(0.7) : NSColor.labelColor
        switch block {
        case .paragraph(let text):
            separate(to: out, font: base, color: color)
            let line = NSMutableAttributedString(attributedString: LinkParagraphView.attributed(source: text, pointSize: pointSize, codePointSize: TypeScale.shared.code(max(9, pointSize - CGFloat(TypeScale.shared.content - TypeScale.stockContent) - 1)), dimmed: dimmed, mentions: mentions, targets: targets))
            let style = MarkdownParagraphLayout.paragraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacing = spacing
            MarkdownParagraphLayout.apply(style, to: line)
            out.append(line)
        case .heading(let level, let text):
            separate(to: out, font: base, color: color)
            let headingStockSize: CGFloat
            switch level {
            case 1: headingStockSize = 17
            case 2: headingStockSize = 15
            case 3: headingStockSize = 13
            default: headingStockSize = 11
            }
            let size = TypeScale.shared.content(headingStockSize)
            let line = NSMutableAttributedString(attributedString: LinkParagraphView.attributed(source: text, pointSize: size, codePointSize: TypeScale.shared.code(max(9, headingStockSize - 1)), weight: .semibold, dimmed: dimmed, mentions: mentions, targets: targets))
            let style = MarkdownParagraphLayout.paragraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacingBefore = level <= 2 ? 6 : 2
            style.paragraphSpacing = MarkdownParagraphLayout.blockSpacing
            MarkdownParagraphLayout.apply(style, to: line)
            out.append(line)
        case .list(let ordered, let start, let items):
            for (index, item) in items.enumerated() {
                separate(to: out, font: base, color: color, listBoundary: index > 0 || depth > 0)
                let marker: String
                if let checked = item.checked {
                    marker = checked ? "☑" : "☐"
                } else if ordered {
                    marker = "\(start + index)."
                } else {
                    marker = depth == 0 ? "•" : "◦"
                }
                let line = NSMutableAttributedString(string: marker + "\t", attributes: [
                    .font: base,
                    .foregroundColor: Chrome.accentNSColor.withAlphaComponent(dimmed ? 0.55 : 0.9),
                ])
                if !item.text.isEmpty {
                    line.append(LinkParagraphView.attributed(source: item.text, pointSize: pointSize, codePointSize: TypeScale.shared.code(max(9, pointSize - CGFloat(TypeScale.shared.content - TypeScale.stockContent) - 1)), dimmed: dimmed, mentions: mentions, targets: targets))
                }
                let style = MarkdownParagraphLayout.paragraphStyle()
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 18
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
                style.defaultTabInterval = 18
                style.paragraphSpacing = MarkdownParagraphLayout.listSpacing
                MarkdownParagraphLayout.apply(style, to: line)
                out.append(line)
                for child in item.children {
                    append(child, depth: depth + 1, indent: indent + 18, dimmed: dimmed, spacing: MarkdownParagraphLayout.listSpacing, pointSize: pointSize, mentions: mentions, targets: targets, to: out)
                }
            }
            // Only the actual end of the list receives the surrounding block gap;
            // a final item with children must keep its internal list spacing.
            if !items.isEmpty { setTrailingSpacing(spacing, in: out) }
        case .quote(let inner):
            for child in inner {
                append(child, depth: depth, indent: indent + 14, dimmed: true, spacing: spacing, pointSize: pointSize, mentions: mentions, targets: targets, to: out)
            }
        case .code, .math, .table, .rule, .alert:
            break
        }
    }

    @MainActor
    private static func separate(to out: NSMutableAttributedString, font: NSFont, color: NSColor, listBoundary: Bool = false) {
        guard out.length > 0 else { return }
        if listBoundary {
            let last = out.mutableString.rangeOfComposedCharacterSequence(at: out.length - 1)
            out.addAttribute(MarkdownParagraphLayout.listItemBoundary, value: true, range: last)
        }
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: font,
            .foregroundColor: color,
        ]))
    }

    @MainActor
    private static func setTrailingSpacing(_ spacing: CGFloat, in text: NSMutableAttributedString) {
        guard text.length > 0,
              let style = text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil) as? NSParagraphStyle else { return }
        let updated = style.mutableCopy() as! NSMutableParagraphStyle
        updated.paragraphSpacing = spacing
        let paragraph = text.mutableString.paragraphRange(for: NSRange(location: text.length - 1, length: 1))
        text.addAttribute(.paragraphStyle, value: updated, range: paragraph)
    }
}

/// Cold history combines prose into one selectable native view. Give that path
/// the same bounded horizontal math overflow as a live streaming paragraph.
private struct MathProseRunRepresentable: NSViewRepresentable {
    let prose: ProseRunRepresentable
    func makeCoordinator() -> LinkParagraphView.Coordinator { prose.makeCoordinator() }
    func makeNSView(context: Context) -> MathParagraphHost {
        let host = MathParagraphHost()
        prose.configure(host.paragraph, coordinator: context.coordinator, environment: context.environment)
        return host
    }
    func updateNSView(_ view: MathParagraphHost, context: Context) {
        prose.updateTextView(view.paragraph, coordinator: context.coordinator, environment: context.environment)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MathParagraphHost, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return nsView.measure(width: width)
    }
    static func dismantleNSView(_ view: MathParagraphHost, coordinator: LinkParagraphView.Coordinator) {
        ProseRunRepresentable.dismantleNSView(view.paragraph, coordinator: coordinator)
    }
}
