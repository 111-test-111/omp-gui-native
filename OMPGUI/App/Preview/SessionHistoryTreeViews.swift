import AppKit
import SwiftUI

/// The disclosure and every connector use this same coordinate system. Title
/// anchors supply Y, so wrapping, font changes and tall text values cannot move
/// the elbow away from the disclosure's center.
struct SessionHistoryTreeGeometry {
    let depth: Int
    let step: CGFloat
    let maximumIndent: CGFloat
    var indent: CGFloat { min(CGFloat(depth) * step, maximumIndent) }
    var markerX: CGFloat { 19 + indent }
    var gutterWidth: CGFloat { 24 + indent }

    struct Segment: Equatable { let from: CGPoint; let to: CGPoint }

    func segments(height: CGFloat, anchorY: CGFloat, ancestors: [Bool], last: Bool, expanded: Bool,
                  hasDisclosure: Bool = true) -> [Segment] {
        let shownDepth = min(depth, Int(maximumIndent / step))
        let hiddenDepth = depth - shownDepth
        var result: [Segment] = []
        for column in 0..<shownDepth {
            let logical = column + hiddenDepth
            let x = 19 + CGFloat(column) * step
            if column == shownDepth - 1 {
                result.append(.init(from: .init(x: x, y: 0), to: .init(x: x, y: last ? anchorY : height)))
                let endX = hasDisclosure ? markerX - 7 : gutterWidth + 5
                result.append(.init(from: .init(x: x, y: anchorY), to: .init(x: endX, y: anchorY)))
            } else if ancestors.indices.contains(logical + 1), ancestors[logical + 1] {
                result.append(.init(from: .init(x: x, y: 0), to: .init(x: x, y: height)))
            }
        }
        if expanded {
            result.append(.init(from: .init(x: markerX, y: anchorY + 7), to: .init(x: markerX, y: height)))
        }
        return result
    }
}

struct SessionHistoryTitleAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

struct SessionHistoryTreeDecoration: ViewModifier {
    let geometry: SessionHistoryTreeGeometry
    let ancestors: [Bool]
    let last: Bool
    let expanded: Bool
    let connectsChildren: Bool
    var hasDisclosure = true
    var enabled = true
    var active = false
    let title: String
    let toggle: () -> Void

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(SessionHistoryTitleAnchor.self) { anchor in
            GeometryReader { proxy in
                let titleRect = anchor.map { proxy[$0] }
                let centerY = titleRect?.midY ?? min(22, proxy.size.height / 2)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        for segment in geometry.segments(height: size.height, anchorY: centerY, ancestors: ancestors,
                                                         last: last, expanded: connectsChildren && expanded,
                                                         hasDisclosure: hasDisclosure) {
                            var path = Path(); path.move(to: segment.from); path.addLine(to: segment.to)
                            context.stroke(path, with: .color(active ? Color.accentColor.opacity(0.45) : Chrome.overlay(0.16)),
                                           style: .init(lineWidth: 1, lineCap: .butt))
                        }
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                    if hasDisclosure {
                        Button(action: toggle) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.symbol(.caption2)).foregroundStyle(Chrome.secondaryText)
                                .frame(width: 20, height: 28).contentShape(.rect)
                        }
                        .buttonStyle(.plain).disabled(!enabled)
                        .offset(x: geometry.markerX - 10, y: centerY - 14)
                        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized(expanded ? "Collapse %@" : "Expand %@"), title)))
                        .accessibilityValue(Text(expanded ? "Expanded" : "Collapsed"))
                    }
                }
            }
        }
    }
}

struct SessionHistoryDetailValueRow: View {
    let row: OMPSessionDetailRow
    let state: SessionHistoryStore
    let width: CGFloat
    let identity: String

    private var geometry: SessionHistoryTreeGeometry {
        .init(depth: row.depth, step: width < 420 ? 12 : 14, maximumIndent: width < 420 ? 36 : 56)
    }

    private var valuePreview: String {
        switch row.valueKind {
        case .object: String(format: Chrome.localized(row.count == 1 ? "Object · %d field" : "Object · %d fields"), row.count)
        case .array: String(format: Chrome.localized(row.count == 1 ? "Array · %d item" : "Array · %d items"), row.count)
        case .text: String(format: Chrome.localized("Text · %d characters"), row.count)
        case .scalar: row.preview
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    key
                    Text(verbatim: valuePreview).font(.code(.caption)).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 3) {
                    key
                    Text(verbatim: valuePreview).font(.code(.caption)).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(row.valueKind == .scalar ? 3 : 1).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            if row.valueKind == .text, !row.isExpanded {
                Text(verbatim: row.preview).font(.code(.caption)).foregroundStyle(Chrome.secondaryText)
                    .lineLimit(2).textSelection(.enabled).padding(.bottom, 8)
            }
            if let text = row.text {
                SessionHistoryTextValue(text: text, identity: identity + ":\(row.page)")
                    .padding(.bottom, 8)
                if row.pageCount > 1 {
                    HStack(spacing: 6) {
                        ChromeCapsule {
                            ChromeIconButton(symbol: "chevron.left", isEnabled: row.page > 0, help: "Previous text page") {
                                state.detailBranchPage(row.path, page: row.page - 1)
                            }
                            ChromeIconButton(symbol: "chevron.right", isEnabled: row.page + 1 < row.pageCount, help: "Next text page") {
                                state.detailBranchPage(row.path, page: row.page + 1)
                            }
                        }
                        Text(verbatim: String(format: Chrome.localized("%d / %d"), row.page + 1, row.pageCount))
                            .font(.ui(.caption)).monospacedDigit().foregroundStyle(Chrome.secondaryText)
                    }.padding(.bottom, 8)
                }
            }
        }
        .padding(.leading, geometry.gutterWidth).padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionHistoryTreeDecoration(geometry: geometry, ancestors: row.ancestorContinuations,
            last: row.isLastSibling, expanded: row.isExpanded, connectsChildren: row.valueKind != .text && row.loadedCount > 0,
            hasDisclosure: row.canExpand, enabled: !state.isDetailPending && (row.isExpanded || state.canExpandDetail),
            active: state.detailFocusPath == row.path, title: row.key.title) { state.toggleDetail(row.path) })
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(verbatim: String(format: Chrome.localized("Level %d"), row.depth + 1)))
    }

    private var key: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if CGFloat(row.depth) * geometry.step > geometry.maximumIndent {
                Text(verbatim: String(format: Chrome.localized("L%d"), row.depth + 1)).font(.code(.caption2)).foregroundStyle(Chrome.secondaryText)
            }
            Text(verbatim: row.key.title).font(.code(.callout)).lineLimit(1).truncationMode(.middle)
                .anchorPreference(key: SessionHistoryTitleAnchor.self, value: .bounds) { $0 }
        }
        .textSelection(.enabled)
        .help(row.path.map(\.title).joined(separator: " › "))
    }
}

struct SessionHistoryTextValue: View {
    let text: String
    let identity: String
    static let maximumHeight: CGFloat = 240

    var body: some View {
        Group {
            if text.unicodeScalars.count > 480 || text.split(separator: "\n", omittingEmptySubsequences: false).prefix(9).count > 8 {
                SessionHistoryScrollableText(text: text, identity: identity)
                    .frame(height: Self.maximumHeight)
            } else {
                Text(verbatim: text).font(.code(.callout)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10, style: .continuous))
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }
}

/// Each expanded long value owns a stable, read-only native text view. Updates
/// to siblings do not replace its storage, selection or scroll origin.
struct SessionHistoryScrollableText: NSViewRepresentable {
    let text: String
    let identity: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var identity = "" }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.setAccessibilityIdentifier("session-history.text-value")
        let editor = NSTextView(frame: .zero)
        editor.isEditable = false; editor.isSelectable = true; editor.isRichText = false
        editor.drawsBackground = false; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.minSize = .zero
        editor.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = .init(width: 10, height: 10)
        editor.usesFindBar = true
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let font = AppFont.monospaced(size: TypeScale.shared.code(TypeScale.stockPointSize(.callout)))
        if editor.font != font { editor.font = font }
        editor.textColor = .labelColor
        editor.setAccessibilityLabel(Chrome.localized("Expanded text value"))
        let changedIdentity = context.coordinator.identity != identity
        if editor.string != text {
            let origin = scroll.contentView.bounds.origin
            let selection = editor.selectedRange()
            editor.string = text
            let count = (text as NSString).length
            editor.setSelectedRange(.init(location: min(selection.location, count), length: 0))
            if !changedIdentity { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        if changedIdentity {
            editor.setSelectedRange(.init(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            context.coordinator.identity = identity
        }
    }
}
