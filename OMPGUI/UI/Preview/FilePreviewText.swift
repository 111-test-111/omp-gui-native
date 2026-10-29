import AppKit
import SwiftUI

/// Coordinate conversion stays independent of TextKit layout, allowing a long
/// source file to jump directly to a logical line without laying out its prefix.
enum PreviewSourcePositions {
    static func lineStarts(in source: String) -> [Int] {
        // The ruler needs UTF-16 offsets, but iterating the String.UTF16View
        // scalar by scalar is expensive for a large source in Debug builds.
        // Valid UTF-8 exposes CR/LF directly. Count only scalar-leading bytes;
        // supplementary scalars contribute two UTF-16 units, every other
        // scalar one. A temporary native buffer also handles NSString bridges.
        var source = source
        return source.withUTF8 { bytes in
            var starts = [0]
            var offset = 0
            var previousCR = false
            for byte in bytes {
                if byte == 10 {
                    if previousCR { starts[starts.count - 1] = offset + 1 }
                    else { starts.append(offset + 1) }
                } else if byte == 13 { starts.append(offset + 1) }
                if byte & 0xC0 != 0x80 { offset += byte >= 0xF0 ? 2 : 1 }
                previousCR = byte == 13
            }
            return starts
        }
    }

    static func offset(in source: String, lineStarts: [Int], location: FilePreviewLocation) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        let line = min(max(1, location.line) - 1, lineStarts.count - 1)
        let ns = source as NSString
        let start = min(lineStarts[line], ns.length)
        let next = min(line + 1 < lineStarts.count ? lineStarts[line + 1] : ns.length, ns.length)
        let text = ns.substring(with: NSRange(location: start, length: max(0, next - start))).trimmingCharacters(in: .newlines)
        let column = max(1, location.column ?? 1) - 1
        let index = text.index(text.startIndex, offsetBy: column, limitedBy: text.endIndex) ?? text.endIndex
        return start + text.utf16.distance(from: text.utf16.startIndex, to: index)
    }
}

struct PreviewTextRenderer: NSViewRepresentable {
    let url: URL
    let source: String
    let revision: String
    let location: FilePreviewLocation?
    let state: PreviewReaderState
    let wraps: Bool
    let findRequest: Int
    let navigationRequest: Int
    let onOpen: (FilePreviewReference, URL) -> Void

    func makeNSView(context: Context) -> PreviewTextHost { PreviewTextHost() }
    func updateNSView(_ view: PreviewTextHost, context: Context) {
        let openURL = context.environment.openURL
        view.onOpenURL = { openURL($0) }
        _ = CodeHighlighting.shared.theme
        view.updateFonts(revision: AppFont.revision)
        view.update(url: url, source: source, revision: revision, location: location,
                    state: state, wraps: wraps,
                    findRequest: findRequest, navigationRequest: navigationRequest, onOpen: onOpen)
    }
    static func dismantleNSView(_ view: PreviewTextHost, coordinator: ()) { view.tearDown() }
}

/// AppKit can propose a clip frame underneath the ruler while tiling. Reserve
/// the gutter before applying that frame: correcting it afterward publishes two
/// different viewport widths to TextKit during glyph drawing and can prevent
/// layout from ever settling, even for a short memory preview.
@MainActor
private final class PreviewTextClipView: NSClipView {
    override var frame: NSRect {
        get { super.frame }
        set {
            var viewport = newValue
            if let scroll = enclosingScrollView, scroll.rulersVisible, scroll.hasVerticalRuler,
               let ruler = scroll.verticalRulerView {
                let edge = scroll.convert(ruler.bounds, from: ruler).maxX
                if viewport.minX < edge {
                    viewport = NSRect(x: edge, y: viewport.minY,
                                      width: max(0, viewport.maxX - edge), height: viewport.height)
                }
            }
            if super.frame != viewport { super.frame = viewport }
        }
    }
}

@MainActor
final class PreviewTextHost: NSScrollView, NSTextViewDelegate {
    private static let textLayoutLimit = CGFloat(Float.greatestFiniteMagnitude)
    let reader: PreviewSelectableTextView
    /// Text containers/layout managers refer back to their owner weakly. The
    /// assembled TextKit stack needs its storage to survive this initializer.
    private let retainedStorage: NSTextStorage
    private var ruler: PreviewLineRuler?
    private var state: PreviewReaderState?
    private var revisionKey = ""
    private var generation = 0
    private var renderTask: Task<Void, Never>?
    private var restoring = false
    private var baseURL: URL?
    private var documentURL: URL?
    private var onOpen: ((FilePreviewReference, URL) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    private var layoutOptions: (wrapping: Bool, lineNumbers: Bool)?
    private var fontRevision: Int?
    private var sourceFont = AppFont.monospaced(size: CGFloat(TypeScale.shared.code))
    private var syntaxTheme = CodeHighlightTheme.github
    private var syntaxSpans: [PreviewSyntaxHighlighter.Span] = []

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        // AppKit's default “background” layout runs on the main thread during
        // idle time. Filling the entire wrapped file then doing it again after
        // unwrapping defeats the viewport-only source reader and delays input.
        // The text view, ruler and find/navigation still request the ranges
        // they need; noncontiguous layout allows those requests to stay local.
        layout.backgroundLayoutEnabled = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: Self.textLayoutLimit))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        reader = PreviewSelectableTextView(frame: .zero, textContainer: container)
        retainedStorage = storage
        super.init(frame: .zero)
        contentView = PreviewTextClipView()
        borderType = .noBorder
        clipsToBounds = true
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        backgroundColor = .clear
        contentView.drawsBackground = false
        contentView.automaticallyAdjustsContentInsets = false
        contentView.contentInsets = NSEdgeInsets()
        // The gutter is transparent. Clip the scrolled document at its own
        // viewport so horizontal motion cannot paint underneath line numbers.
        contentView.clipsToBounds = true
        reader.isEditable = false
        reader.isSelectable = true
        reader.isRichText = true
        reader.isVerticallyResizable = true
        reader.drawsBackground = false
        reader.minSize = .zero
        reader.maxSize = NSSize(width: Self.textLayoutLimit, height: Self.textLayoutLimit)
        reader.textContainerInset = NSSize(width: 16, height: 16)
        reader.usesFindBar = true
        reader.isIncrementalSearchingEnabled = true
        reader.isAutomaticLinkDetectionEnabled = false
        reader.isAutomaticDataDetectionEnabled = false
        reader.delegate = self
        reader.linkTextAttributes = [.foregroundColor: Chrome.accentNSColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        documentView = reader
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { nil }

    func update(url: URL, source: String, revision: String, location: FilePreviewLocation?,
                state: PreviewReaderState, wraps: Bool,
                findRequest: Int, navigationRequest: Int,
                onOpen: @escaping (FilePreviewReference, URL) -> Void) {
        updateFonts(revision: AppFont.revision)
        let replacing = self.state !== state
        if replacing { saveReadingPosition() }
        self.state = state
        self.onOpen = onOpen
        baseURL = url.deletingLastPathComponent()
        documentURL = url
        let key = url.path + "\n" + revision
        let changed = replacing || key != revisionKey
        let theme = CodeHighlighting.shared.theme
        if changed {
            if !replacing { saveReadingPosition() }
            revisionKey = key
            generation += 1
            renderTask?.cancel()
            syntaxTheme = theme
            syntaxSpans = []
            restoring = true
            configureLayout(wrapping: wraps, lineNumbers: true)
            let saved = state.source
            let currentGeneration = generation
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.defaultTabInterval = 4 * sourceFont.maximumAdvancement.width
            reader.textStorage?.setAttributedString(NSAttributedString(string: source, attributes: [
                .font: sourceFont,
                .foregroundColor: CodeSyntaxStyle.foregroundColor(theme: syntaxTheme), .paragraphStyle: paragraph,
            ]))
            ruler?.setSource(source)
            restore(saved, generation: currentGeneration)
            let highlightSource = String(decoding: source.utf16.prefix(PreviewSyntaxHighlighter.maximumUTF16Length), as: UTF16.self)
            let ext = PreviewSyntaxHighlighter.languageExtension(forFilePath: url.path) ?? ""
            renderTask = Task { [weak self] in
                let highlight = Task.detached(priority: .utility) {
                    PreviewSyntaxHighlighter.spans(in: highlightSource, extension: ext)
                }
                let spans = await withTaskCancellationHandler(operation: { await highlight.value }, onCancel: { highlight.cancel() })
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                self.syntaxSpans = spans
                self.applySyntaxColors(resetForeground: false)
            }
        } else {
            configureLayout(wrapping: wraps, lineNumbers: true)
            if syntaxTheme != theme {
                syntaxTheme = theme
                applySyntaxColors(resetForeground: true)
            }
        }
        if let location, navigationRequest != state.consumedNavigationRequest {
            state.consumedNavigationRequest = navigationRequest
            // The text has already been installed synchronously for source mode.
            restoring = false
            navigate(to: location)
        }
        if findRequest != state.consumedFindRequest {
            state.consumedFindRequest = findRequest
            showFind()
        }
    }

    private func applySyntaxColors(resetForeground: Bool) {
        let storage = retainedStorage
        storage.beginEditing()
        if resetForeground {
            storage.addAttribute(.foregroundColor, value: CodeSyntaxStyle.foregroundColor(theme: syntaxTheme),
                                 range: NSRange(location: 0, length: storage.length))
        }
        for span in syntaxSpans where NSMaxRange(span.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: CodeSyntaxStyle.color(for: span.token, theme: syntaxTheme), range: span.range)
        }
        storage.endEditing()
    }

    func updateFonts(revision: Int) {
        let size = CGFloat(TypeScale.shared.code)
        guard fontRevision != revision || sourceFont.pointSize != size else { return }
        fontRevision = revision
        let font = AppFont.monospaced(size: size)
        let rulerChanged = ruler?.updateFont(font) ?? false
        guard sourceFont != font || rulerChanged else { return }
        let selection = reader.selectedRanges
        let origin = contentView.bounds.origin
        let wasRestoring = restoring
        restoring = true
        if sourceFont != font {
            sourceFont = font
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.defaultTabInterval = 4 * font.maximumAdvancement.width
            retainedStorage.addAttributes([.font: font, .paragraphStyle: paragraph],
                                          range: NSRange(location: 0, length: retainedStorage.length))
        }
        tile()
        resizeReaderToViewport()
        reader.layoutSubtreeIfNeeded()
        reader.selectedRanges = selection
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
        reflectScrolledClipView(contentView)
        restoring = wasRestoring
        ruler?.needsDisplay = true
    }

    private func configureLayout(wrapping: Bool, lineNumbers: Bool) {
        // SwiftUI can update the representable for unrelated toolbar/reading
        // state changes. Repeating AppKit's resize/scroller setup queues more
        // geometry work even when the wrapping policy has not changed.
        if let previous = layoutOptions, previous.wrapping == wrapping, previous.lineNumbers == lineNumbers {
            return
        }
        layoutOptions = (wrapping, lineNumbers)
        hasHorizontalScroller = !wrapping
        reader.isHorizontallyResizable = !wrapping
        // The clip view reserves the gutter before publishing its geometry.
        // Size the reader once from that final viewport, keeping AppKit's
        // intermediate autoresizing work out of the document's wrap width.
        reader.autoresizingMask = []
        reader.textContainer?.widthTracksTextView = wrapping
        reader.textContainer?.heightTracksTextView = false
        if lineNumbers, ruler == nil {
            let newRuler = PreviewLineRuler(scrollView: self, reader: reader, font: sourceFont)
            ruler = newRuler
            verticalRulerView = newRuler
            hasVerticalRuler = true
        }
        rulersVisible = lineNumbers
        tile()
        resizeReaderToViewport()
    }

    override func layout() {
        super.layout()
        resizeReaderToViewport()
    }

    private func resizeReaderToViewport() {
        guard let container = reader.textContainer else { return }
        let insets = contentView.contentInsets
        let viewport = NSSize(width: max(1, contentView.bounds.width - insets.left - insets.right),
                              height: max(1, contentView.bounds.height - insets.top - insets.bottom))
        if reader.minSize != viewport { reader.minSize = viewport }
        let size = NSSize(width: container.widthTracksTextView ? viewport.width : max(viewport.width, reader.frame.width),
                          height: max(viewport.height, reader.frame.height))
        if abs(reader.frame.width - size.width) > 0.5 || abs(reader.frame.height - size.height) > 0.5 {
            reader.setFrameSize(size)
        }
        let containerSize = NSSize(width: container.widthTracksTextView ? max(1, viewport.width - reader.textContainerInset.width * 2) : Self.textLayoutLimit,
                                   height: Self.textLayoutLimit)
        if container.containerSize != containerSize { container.containerSize = containerSize }
    }

    private func restore(_ saved: PreviewReaderState.TextPosition, generation: Int) {
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation, self.restoring else { return }
            self.layoutSubtreeIfNeeded()
            let length = self.reader.textStorage?.length ?? 0
            let location = min(max(0, saved.selectionLocation), length)
            self.reader.setSelectedRange(NSRange(location: location, length: min(max(0, saved.selectionLength), length - location)))
            let origin = NSPoint(x: saved.x.isFinite ? max(0, saved.x) : 0, y: saved.y.isFinite ? max(0, saved.y) : 0)
            self.contentView.scroll(to: self.contentView.constrainBoundsRect(NSRect(origin: origin, size: self.contentView.bounds.size)).origin)
            self.reflectScrolledClipView(self.contentView)
            self.restoring = false
            self.saveReadingPosition()
        }
    }

    private func navigate(to location: FilePreviewLocation) {
        guard let ruler, let storage = reader.textStorage else { return }
        let target = PreviewSourcePositions.offset(in: storage.string, lineStarts: ruler.lineStarts, location: location)
        reader.setSelectedRange(NSRange(location: min(target, storage.length), length: 0))
        reader.scrollRangeToVisible(reader.selectedRange())
        saveReadingPosition()
    }

    private func showFind() {
        window?.makeFirstResponder(reader)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        reader.performTextFinderAction(item)
    }

    @objc private func scrolled() {
        ruler?.needsDisplay = true
        saveReadingPosition()
    }

    func textViewDidChangeSelection(_ notification: Notification) { saveReadingPosition() }

    private func saveReadingPosition() {
        guard !restoring, let state else { return }
        let selection = reader.selectedRange()
        let position = PreviewReaderState.TextPosition(x: contentView.bounds.origin.x, y: contentView.bounds.origin.y,
                                                      selectionLocation: selection.location, selectionLength: selection.length)
        state.source = position
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), let baseURL else { return true }
        if url.scheme == nil, url.path.isEmpty, let fragment = url.fragment {
            if fragment.range(of: "^L[0-9]+(?:C[0-9]+|-L[0-9]+)?$", options: .regularExpression) != nil, let documentURL {
                onOpen?(FilePreviewReference(path: documentURL.absoluteString + "#" + fragment), baseURL)
            }
            return true
        }
        let numericLocation = url.relativeString.range(of: "^.+:[1-9][0-9]*(?::[1-9][0-9]*)?$", options: .regularExpression) != nil
            && !url.relativeString.contains("://")
            && !["http", "https", "mailto", "tel", "javascript", "data"].contains(url.scheme?.lowercased() ?? "")
        if numericLocation, url.scheme != nil {
            onOpen?(FilePreviewReference(path: url.relativeString), baseURL)
        } else if url.isFileURL || url.scheme == nil {
            var path = url.isFileURL ? url.absoluteString : url.path
            if !url.isFileURL, let fragment = url.fragment, fragment.hasPrefix("L") { path += "#" + fragment }
            onOpen?(FilePreviewReference(path: path, line: nil, column: nil), baseURL)
        } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            if url.isHTTPWebLink, let onOpenURL { onOpenURL(url) } else { NSWorkspace.shared.open(url) }
        }
        return true
    }

    func tearDown() {
        saveReadingPosition()
        generation += 1
        renderTask?.cancel()
        renderTask = nil
        syntaxSpans = []
        reader.delegate = nil
        onOpen = nil
        onOpenURL = nil
        state = nil
        NotificationCenter.default.removeObserver(self)
        retainedStorage.setAttributedString(NSAttributedString(string: ""))
        ruler?.setSource("")
    }

}

/// Source mode uses AppKit selection, copy and the native find bar directly.
final class PreviewSelectableTextView: NSTextView {}

@MainActor
private final class PreviewLineRuler: NSRulerView {
    weak var reader: NSTextView?
    private(set) var lineStarts = [0]
    private var font: NSFont

    init(scrollView: NSScrollView, reader: NSTextView, font: NSFont) {
        self.reader = reader
        self.font = font
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clipsToBounds = true
        clientView = reader
        ruleThickness = 46
    }
    required init(coder: NSCoder) { fatalError("Preview rulers are created in code") }
    override var isOpaque: Bool { false }

    // NSRulerView normally paints its own opaque background before the marks.
    // Leave the shared chat/preview surface visible through the gutter as well.
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    func setSource(_ source: String) {
        lineStarts = PreviewSourcePositions.lineStarts(in: source)
        updateThickness()
        needsDisplay = true
    }

    @discardableResult
    func updateFont(_ selected: NSFont) -> Bool {
        guard font != selected else { return false }
        font = selected
        updateThickness()
        needsDisplay = true
        return true
    }

    private func updateThickness() {
        let digits = CGFloat(String(lineStarts.count).count)
        ruleThickness = max(46, ceil(digits * font.maximumAdvancement.width) + 18)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let reader, let scrollView, let layout = reader.layoutManager, let container = reader.textContainer else { return }
        let visible = scrollView.documentVisibleRect.offsetBy(dx: -reader.textContainerInset.width, dy: -reader.textContainerInset.height)
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { [self] fragment, _, _, range, _ in
            let character = layout.characterIndexForGlyph(at: range.location)
            var low = 0, high = lineStarts.count
            while low < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= character { low = middle + 1 } else { high = middle }
            }
            let line = max(0, low - 1)
            guard lineStarts[line] == character else { return }
            let number = String(line + 1) as NSString
            let size = number.size(withAttributes: attrs)
            let point = convert(NSPoint(x: 0, y: fragment.minY + reader.textContainerInset.height), from: reader)
            let y = isFlipped ? point.y : point.y - size.height
            number.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attrs)
        }
        if reader.string.isEmpty {
            ("1" as NSString).draw(at: NSPoint(x: ruleThickness - 15, y: isFlipped ? 16 : bounds.height - 30), withAttributes: attrs)
        } else if lineStarts.last == layout.textStorage?.length, layout.extraLineFragmentTextContainer === container {
            let number = String(lineStarts.count) as NSString
            let size = number.size(withAttributes: attrs)
            let point = convert(NSPoint(x: 0, y: layout.extraLineFragmentRect.minY + reader.textContainerInset.height), from: reader)
            number.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: isFlipped ? point.y : point.y - size.height), withAttributes: attrs)
        }
    }
}
