import AppKit

extension NSAttributedString.Key {
    static let mathSource = Self("omp.math.source")
    static let mathLatex = Self("omp.math.latex")
}

/// Native prose and selection stay in TextKit. Only complete, bounded formulas
/// enter the shared MathJax worker; theme/selection never invalidate its images.
@MainActor enum MathRendering {
    typealias Layout = ChatMathRenderer.Image
    enum Result { case ready(Layout), failure(String), pending }
    @MainActor final class Entry: NSObject {
        let formula: MarkdownFormula
        let pointSize: CGFloat, scale: CGFloat
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let key: NSString
        var result: Result = .pending
        let cells = NSHashTable<MathAttachmentCell>.weakObjects()
        init(_ formula: MarkdownFormula, size: CGFloat, scale: CGFloat, key: NSString) {
            self.formula = formula; pointSize = size; self.scale = scale; self.key = key
        }
        func finish(_ result: Result) {
            self.result = result
            for cell in cells.allObjects { cell.update() }
        }
    }
    private final class WeakEntry {
        weak var value: Entry?
        init(_ value: Entry) { self.value = value }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 2048; cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static var queue: [WeakEntry] = []
    // Pending work must survive NSCache pressure, and repeated row construction
    // must join an existing request instead of starting the same formula twice.
    private static var inFlight: [NSString: Entry] = [:]
    private static let diskCache: ChatMathCache = {
        let root = CaptureRun.outputDirectory?.appendingPathComponent("math-cache", isDirectory: true)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.ompgui.mac", isDirectory: true)
                .appendingPathComponent("ChatMath", isDirectory: true)
        return ChatMathCache(root: root)
    }()
    private static var diskWrites: Task<Void, Never>?
    private static var pendingWrites: [(String, Layout)] = []
    private static var worker: Task<Void, Never>?
    private(set) static var typesetCount = 0
    private(set) static var diskHitCount = 0
    static var isRendering: Bool { worker != nil }
    #if DEBUG
    static var paintObserver: ((String, Double, Double) -> Void)?
    private(set) static var lastFailure: String?
    static func flushDiskCache() async { await diskWrites?.value }
    static func discardMemoryCache() {
        precondition(!isRendering)
        cache.removeAllObjects()
    }
    #endif

    static func imageScale(for backingScale: CGFloat) -> CGFloat {
        backingScale.isFinite ? min(4, max(2, backingScale)) : 2
    }
    /// One bounded real formula starts the shared worker while the timeline's
    /// delayed history page and native paragraphs are still being constructed.
    /// A persistent hit does not start WebKit; repeated appearances join the job.
    static func prewarm(_ source: String, pointSize: CGFloat) {
        if let sample = MarkdownMath.spans(in: String(source.prefix(8192))).first(where: { $0.formula.complete }) {
            _ = entry(for: sample.formula, pointSize: pointSize, scale: 2)
        }
    }
    private static func validation(_ formula: MarkdownFormula, size: CGFloat) -> String? {
        guard size.isFinite, size > 0, size <= 96, formula.latex.utf8.count <= 16_384 else { return "Formula is too complex" }
        guard !formula.latex.isEmpty else { return "Empty formula" }
        var depth = 0, slash = false
        for scalar in formula.latex.unicodeScalars {
            if !slash {
                if scalar == "{" { depth += 1 }
                if scalar == "}" { depth -= 1 }
                if depth > 64 { return "Formula is too complex" }
            }
            slash = scalar == "\\" && !slash
        }
        return nil
    }
    private static func entry(for formula: MarkdownFormula, pointSize: CGFloat, scale: CGFloat) -> Entry {
        let scale = imageScale(for: scale)
        let key = "\(formula.mode.rawValue):\(pointSize):\(scale):\(formula.latex)" as NSString
        if let hit = inFlight[key] ?? cache.object(forKey: key) { return hit }
        let entry = Entry(formula, size: pointSize, scale: scale, key: key)
        if let error = validation(formula, size: pointSize) { entry.result = .failure(error) }
        cache.setObject(entry, forKey: key, cost: formula.latex.utf8.count + 256)
        if case .pending = entry.result {
            inFlight[key] = entry
            queue.append(WeakEntry(entry))
            if worker == nil {
                worker = Task { @MainActor in
                    await Task.yield()
                    await drain()
                }
            }
        }
        return entry
    }
    private static func drain() async {
        var firstBatch = true
        while !queue.isEmpty {
            // A newly streamed/visible formula must not wait behind a long
            // offscreen history. Evaluate visibility once per scheduling pass.
            let candidates: [(entry: Entry, visible: Bool, order: Int)] = queue.compactMap(\.value).enumerated().map { index, entry in
                (entry, entry.cells.allObjects.contains(where: \.isVisible), index)
            }
            let pending = candidates.sorted(by: {
                if $0.visible != $1.visible { return $0.visible }
                return $0.order < $1.order
            }).map(\.entry)
            queue.removeAll(keepingCapacity: true)
            guard let first = pending.first else { continue }
            // Publish the first small batch promptly; amortize WebKit bridge,
            // compositor and snapshot work over larger history batches after it.
            let batch = Array(pending.filter { $0.pointSize == first.pointSize && $0.scale == first.scale }.prefix(firstBatch ? 8 : 64))
            firstBatch = false
            let ids = Set(batch.map(ObjectIdentifier.init))
            queue.append(contentsOf: pending.filter { !ids.contains(ObjectIdentifier($0)) }.map(WeakEntry.init))
            let hits = await diskCache.load(batch.map { $0.key as String })
            var missing: [Entry] = []
            for entry in batch {
                if let image = hits[entry.key as String] {
                    diskHitCount += 1
                    finish(entry, image: image)
                } else { missing.append(entry) }
            }
            typesetCount += missing.count
            await render(missing)
            if pendingWrites.count >= 128 || pendingWrites.reduce(0, { $0 + $1.1.cost }) >= 8 * 1024 * 1024 { savePendingImages() }
        }
        worker = nil
        savePendingImages()
    }
    private static func savePendingImages() {
        let writes = pendingWrites; pendingWrites.removeAll(keepingCapacity: true)
        if !writes.isEmpty {
            let previous = diskWrites
            diskWrites = Task { await previous?.value; await diskCache.store(writes) }
        }
    }
    private static func finish(_ entry: Entry, image: Layout?) {
        entry.finish(image.map(Result.ready) ?? .failure("Unsupported or invalid LaTeX"))
        cache.setObject(entry, forKey: entry.key, cost: (image?.cost ?? 256) + entry.formula.latex.utf8.count)
        inFlight.removeValue(forKey: entry.key)
    }
    private static func render(_ batch: [Entry]) async {
        guard let first = batch.first else { return }
        do {
            let images = try await ChatMathRenderer.shared.render(batch.map(\.formula), pointSize: first.pointSize, scale: first.scale)
            for (entry, image) in zip(batch, images) {
                finish(entry, image: image)
                if let image { pendingWrites.append((entry.key as String, image)) }
            }
        } catch {
            #if DEBUG
            lastFailure = String(describing: error)
            #endif
            // A mixed atlas with one very wide/tall formula can exceed the
            // pixel budget. Split it, keeping batching for its smaller siblings.
            // At most log2(64) levels; a failed singleton always settles.
            if batch.count > 1, (error as? ChatMathRenderer.Failure)?.message == "Formula is too complex" {
                let middle = batch.count / 2
                await render(Array(batch[..<middle]))
                await render(Array(batch[middle...]))
            } else {
                for entry in batch {
                    entry.finish(.failure("Unable to render formula"))
                    inFlight.removeValue(forKey: entry.key)
                }
            }
        }
    }
    static func result(for formula: MarkdownFormula, pointSize: CGFloat, scale: CGFloat = 2) -> Result {
        guard formula.complete else { return .pending }
        return entry(for: formula, pointSize: pointSize, scale: scale).result
    }
    static func attributed(_ formula: MarkdownFormula, pointSize: CGFloat, color: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: pointSize)
        guard formula.complete else { return NSAttributedString(string: formula.source, attributes: [.font: font, .foregroundColor: color]) }
        let entry = entry(for: formula, pointSize: pointSize, scale: 2)
        if case .failure(let error) = entry.result {
            return NSAttributedString(string: formula.source, attributes: [
                .font: font, .foregroundColor: color,
                .toolTip: Bundle.main.localizedString(forKey: error, value: error, table: "Localizable")])
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(entry: entry, source: formula.source, color: color, attachment: attachment)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes([.mathSource: formula.source, .mathLatex: formula.latex, .foregroundColor: color, .font: font],
                           range: NSRange(location: 0, length: text.length))
        return text
    }

    /// Bind only live cells. Completion preserves the string and selection indices.
    static func bind(in view: NSTextView, geometryChanged: @escaping @MainActor () -> Void) {
        guard let storage = view.textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? MathAttachmentCell else { return }
            cell.bind(to: view, at: range.location, geometryChanged: geometryChanged)
        }
    }
    static func detach(from view: NSTextView) {
        guard let storage = view.textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            ((value as? NSTextAttachment)?.attachmentCell as? MathAttachmentCell)?.detach(from: view)
        }
    }
    static func rebind(_ cell: MathAttachmentCell, scale: CGFloat) -> Entry {
        entry(for: cell.entry.formula, pointSize: cell.entry.pointSize, scale: scale)
    }

    /// Display math is a single native attachment. Measure its geometry directly:
    /// a centred paragraph in an unbounded probe includes artificial leading space.
    static func formulaWidth(in text: NSAttributedString) -> CGFloat {
        var width: CGFloat = 0
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment { width += attachment.bounds.width * CGFloat(range.length) }
            else {
                let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 15)
                width += (text.attributedSubstring(from: range).string as NSString).size(withAttributes: [.font: font]).width
            }
        }
        return ceil(width)
    }

    private static func overflowing(in view: NSTextView) -> [(MathAttachmentCell, NSRange, NSRect)] {
        guard let storage = view.textStorage, let layout = view.layoutManager, let container = view.textContainer else { return [] }
        if let native = layout as? MathTextLayoutManager {
            let origin = view.textContainerOrigin
            return native.mathOverflow(in: container).map { ($0.cell, $0.range, $0.rect.offsetBy(dx: origin.x, dy: origin.y)) }
        }
        var cells: [(MathAttachmentCell, NSRange, NSRect)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let cell = attachment.attachmentCell as? MathAttachmentCell,
                  attachment.bounds.width > container.containerSize.width else { return }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = layout.location(forGlyphAt: glyph), origin = view.textContainerOrigin
            let rect = NSRect(x: origin.x + fragment.minX + position.x + attachment.bounds.minX,
                              y: origin.y + fragment.minY + position.y - attachment.bounds.maxY,
                              width: attachment.bounds.width, height: attachment.bounds.height)
            cells.append((cell, range, rect))
        }
        return cells
    }
    static func drawOverflow(in view: NSTextView, dirtyRect: NSRect) {
        for (cell, range, rect) in overflowing(in: view) where rect.intersects(dirtyRect) {
            cell.draw(withFrame: rect, in: view, characterIndex: range.location)
        }
    }
    static func overflowHit(at point: NSPoint, in view: NSTextView) -> NSRange? {
        overflowing(in: view).first { $0.2.contains(point) }?.1
    }
    /// Export selected attachments as the original delimited TeX, preserving all
    /// neighbouring Unicode, links and line endings in both plain and rich copy.
    static func exported(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        var replacements: [(NSRange, String, [NSAttributedString.Key: Any])] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { original, range, _ in
            guard original[.attachment] is NSTextAttachment, let source = original[.mathSource] as? String else { return }
            var attributes = original
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .mathSource)
            attributes.removeValue(forKey: .mathLatex)
            replacements.append((range, String(repeating: source, count: range.length), attributes))
        }
        for (range, source, attributes) in replacements.reversed() {
            out.replaceCharacters(in: range, with: NSAttributedString(string: source, attributes: attributes))
        }
        return out
    }

    static func overflowWidth(storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer, minimum: CGFloat) -> CGFloat {
        var width = minimum
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            width = max(width, fragment.minX + layout.location(forGlyphAt: glyph).x + attachment.bounds.maxX)
        }
        return ceil(width)
    }
}

/// TextKit clamps an atomic attachment's glyph box to the wrapping width. Keep
/// that width for prose, but include the full image when the viewport pans past
/// the clamped glyph box, otherwise its far end is culled before the cell draws.
final class MathTextLayoutManager: NSLayoutManager {
    typealias Overflow = (cell: MathAttachmentCell, range: NSRange, rect: NSRect)
    private var overflowCache: (container: ObjectIdentifier, width: CGFloat, items: [Overflow])?
    private var resolvingOverflow = false

    override func invalidateLayout(forCharacterRange charRange: NSRange, actualCharacterRange actualCharRange: NSRangePointer?) {
        overflowCache = nil
        super.invalidateLayout(forCharacterRange: charRange, actualCharacterRange: actualCharRange)
    }

    /// Geometry changes invalidate this list; scrolling/selection do not. Most
    /// paragraphs have no overflow, and must not rescan all attachments per draw.
    func mathOverflow(in container: NSTextContainer) -> [Overflow] {
        if let cached = overflowCache, cached.container == ObjectIdentifier(container), cached.width == container.containerSize.width { return cached.items }
        guard let storage = textStorage, !resolvingOverflow else { return [] }
        resolvingOverflow = true
        defer { resolvingOverflow = false }
        var items: [Overflow] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let cell = attachment.attachmentCell as? MathAttachmentCell,
                  attachment.bounds.width > container.containerSize.width else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = location(forGlyphAt: glyph)
            let rect = NSRect(x: fragment.minX + position.x + attachment.bounds.minX,
                              y: fragment.minY + position.y - attachment.bounds.maxY,
                              width: attachment.bounds.width, height: attachment.bounds.height)
            items.append((cell, range, rect))
        }
        overflowCache = (ObjectIdentifier(container), container.containerSize.width, items)
        return items
    }

    override func glyphRange(forBoundingRect bounds: NSRect, in container: NSTextContainer) -> NSRange {
        var result = super.glyphRange(forBoundingRect: bounds, in: container)
        for item in mathOverflow(in: container) {
            if item.rect.intersects(bounds) {
                let glyph = glyphIndexForCharacter(at: item.range.location)
                let extra = NSRange(location: glyph, length: 1)
                result = result.length == 0 ? extra : NSUnionRange(result, extra)
            }
        }
        return result
    }
}

@MainActor final class MathAttachmentCell: NSTextAttachmentCell {
    var preparation: ChatMathPreparation? { (textView as? LinkTextView)?.mathPreparation }
    fileprivate var entry: MathRendering.Entry
    private let color: NSColor
    private let source: String
    private weak var textView: NSTextView?
    private weak var mathAttachment: NSTextAttachment?
    private var characterIndex = 0
    private var geometryChanged: (@MainActor () -> Void)?
    private var raster: MathRendering.Layout?
    nonisolated(unsafe) private var dimensions: NSSize = .zero
    nonisolated(unsafe) private var baseline: NSPoint = .zero

    init(entry: MathRendering.Entry, source: String, color: NSColor, attachment: NSTextAttachment) {
        self.entry = entry; self.source = source; self.color = color; mathAttachment = attachment
        super.init(textCell: "")
        entry.cells.add(self)
        setAccessibilityLabel(source)
        update()
    }
    required init(coder: NSCoder) { fatalError("Math cells are created from Markdown source") }
    nonisolated override func cellSize() -> NSSize { dimensions }
    nonisolated override func cellBaselineOffset() -> NSPoint { baseline }
    var isVisible: Bool {
        guard let view = textView, view.window?.isVisible == true, !view.visibleRect.isEmpty,
              characterIndex < (view.textStorage?.length ?? 0),
              let layout = view.layoutManager, let container = view.textContainer else { return false }
        let glyph = layout.glyphIndexForCharacter(at: characterIndex)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return view.visibleRect.intersects(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y))
    }
    func bind(to view: NSTextView, at index: Int, geometryChanged: @escaping @MainActor () -> Void) {
        textView = view; characterIndex = index; self.geometryChanged = geometryChanged
        let scale = MathRendering.imageScale(for: view.window?.backingScaleFactor ?? 2)
        if scale != entry.scale {
            entry.cells.remove(self)
            entry = MathRendering.rebind(self, scale: scale)
            entry.cells.add(self)
            update()
        }
        preparation?.observe(entry)
    }
    func detach(from view: NSTextView) {
        guard textView === view else { return }
        textView = nil; geometryChanged = nil
    }
    fileprivate func update() {
        let font = NSFont.systemFont(ofSize: entry.pointSize)
        if case .ready(let ready) = entry.result { raster = ready }
        if let image = raster {
            dimensions = image.size
            // Align the stable math axis with the native text centre. Including
            // a comma/descender/superscript must never move the other variables.
            baseline = NSPoint(x: 0, y: -image.descent + (entry.formula.mode == .inline ? font.capHeight / 2 - image.axis : 0))
        } else {
            let measured = (source as NSString).size(withAttributes: [.font: font])
            dimensions = NSSize(width: ceil(measured.width), height: ceil(measured.height))
            baseline = NSPoint(x: 0, y: font.descender)
        }
        mathAttachment?.bounds = NSRect(origin: baseline, size: dimensions)
        geometryChanged?()
    }
    override func draw(withFrame frame: NSRect, in view: NSView?) { draw(withFrame: frame, in: view, characterIndex: NSNotFound) }
    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex: Int) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let text = (view as? NSTextView) ?? textView
        if let native = text as? LinkTextView, native.paintingNativeText,
           dimensions.width > (native.textContainer?.containerSize.width ?? .greatestFiniteMagnitude) { return }
        let storage = text?.textStorage
        var index = characterIndex
        if index < 0 || index >= (storage?.length ?? 0), let storage {
            // TextKit also uses the cell callback without a character index,
            // including non-contiguous drawing of horizontally panned math.
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if (value as? NSTextAttachment)?.attachmentCell === self { index = range.location; stop.pointee = true }
            }
        }
        let attributes = index >= 0 && index < (storage?.length ?? 0)
            ? storage?.attributes(at: index, effectiveRange: nil) ?? [:] : [:]
        var foreground = attributes[.foregroundColor] as? NSColor ?? color
        if let manager = text?.layoutManager, index >= 0, index < (storage?.length ?? 0),
           let temporary = manager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor {
            foreground = temporary
        }
        let selected = text?.selectedRanges.contains { NSLocationInRange(index, $0.rangeValue) } == true
        if selected { foreground = text?.selectedTextAttributes[.foregroundColor] as? NSColor ?? .selectedTextColor }
        let appearance = view?.effectiveAppearance ?? (text?.window != nil ? text!.effectiveAppearance : NSAppearance.currentDrawing())
        appearance.performAsCurrentDrawingAppearance {
            let resolved = foreground.usingColorSpace(.sRGB) ?? foreground
            if let image = raster {
                if selected, image.size.width > (text?.textContainer?.containerSize.width ?? .greatestFiniteMagnitude) {
                    let background = text?.selectedTextAttributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor
                    context.setFillColor((background.usingColorSpace(.sRGB) ?? background).cgColor)
                    context.fill(NSRect(origin: frame.origin, size: image.size))
                }
                image.draw(at: frame.origin, context: context, flipped: view?.isFlipped ?? true, color: resolved, selected: selected)
                #if DEBUG
                if view?.window?.isVisible == true, view?.visibleRect.intersects(frame) == true {
                    MathRendering.paintObserver?(entry.key as String, (ProcessInfo.processInfo.systemUptime - entry.requestedAt) * 1000, entry.requestedAt)
                }
                #endif
            } else {
                let rect = NSRect(origin: frame.origin, size: dimensions)
                (source as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: entry.pointSize), .foregroundColor: resolved])
            }
        }
    }
    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: frame, in: view, characterIndex: characterIndex)
    }
}
