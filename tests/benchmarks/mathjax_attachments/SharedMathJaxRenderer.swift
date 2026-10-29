import AppKit
import WebKit

/// An isolated research implementation, deliberately outside the application.
/// One production preview host owns one WebView, regardless of formula count.
@MainActor final class SharedMathJaxRenderer {
    enum Format: String { case pdf, png }
    struct Geometry: Decodable {
        var x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0
        var ascent: CGFloat = 0, descent: CGFloat = 0
        var error: String?
        enum CodingKeys: String, CodingKey { case x, y, width, height, ascent, descent, error }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            x = try values.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
            y = try values.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
            width = try values.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0
            height = try values.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
            ascent = try values.decodeIfPresent(CGFloat.self, forKey: .ascent) ?? 0
            descent = try values.decodeIfPresent(CGFloat.self, forKey: .descent) ?? 0
            error = try values.decodeIfPresent(String.self, forKey: .error)
        }
        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }
    struct Batch: Decodable {
        let rows: [Geometry]
        let width: CGFloat, height: CGFloat
        let version: String
        let stylesheets: Int, fonts: Int
    }
    final class PDFAtlas {
        let data: Data, document: CGPDFDocument, page: CGPDFPage
        let height: CGFloat
        init(data: Data) throws {
            self.data = data
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
                throw PrototypeError("Invalid exported PDF")
            }
            self.document = document; self.page = page
            height = page.getBoxRect(.mediaBox).height
        }
    }
    @MainActor final class Asset {
        let geometry: Geometry
        let pdf: PDFAtlas?
        let image: CGImage?
        let imageScale: CGFloat
        init(_ geometry: Geometry, pdf: PDFAtlas? = nil, image: CGImage? = nil, scale: CGFloat = 2) {
            self.geometry = geometry; self.pdf = pdf; self.image = image; imageScale = scale
        }
        var size: NSSize { geometry.rect.size }
        func draw(_ rect: NSRect, in context: CGContext, flipped: Bool) {
            context.saveGState(); defer { context.restoreGState() }
            if flipped {
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
            } else { context.translateBy(x: rect.minX, y: rect.minY) }
            context.clip(to: CGRect(origin: .zero, size: rect.size))
            if let pdf {
                context.translateBy(x: -geometry.x, y: -(pdf.height - geometry.y - geometry.height))
                context.drawPDFPage(pdf.page)
            } else if let image {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            }
        }
        func attributed(_ formula: MarkdownFormula, color: NSColor = .black) -> NSAttributedString {
            let attachment = NSTextAttachment()
            attachment.bounds = NSRect(x: 0, y: -geometry.descent, width: geometry.width, height: geometry.height)
            attachment.attachmentCell = AssetCell(self, source: formula.source)
            let text = NSMutableAttributedString(attachment: attachment)
            text.addAttributes([.mathSource:formula.source, .mathLatex:formula.latex,
                                .font:NSFont.systemFont(ofSize:15), .foregroundColor:color],
                               range:NSRange(location:0, length:text.length))
            return text
        }
    }
    let root: URL, output: URL
    private var host: PreviewMarkdownHost?
    private var window: NSWindow?
    private var busy = false
    var isRendering: Bool { busy }
    private(set) var jobCount = 0, formulaCount = 0, exportedBytes = 0, resourceCount = 0
    private(set) var layoutMilliseconds: Double = 0, exportMilliseconds: Double = 0
    private(set) var lastBatch: Batch?
    var web: WKWebView { host!.web }
    init(root: URL, output: URL) { self.root = root; self.output = output }

    func start() async throws {
        guard host == nil else { return }
        let host = PreviewMarkdownHost(resourceRoot: root.appendingPathComponent("OMPGUI/Resources/MarkdownPreview"))
        self.host = host
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:900), styleMask:[.borderless], backing:.buffered, defer:false)
        self.window = window; window.contentView = host
        host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded()
        host.appearance = NSAppearance(named:.aqua)
        host.update(url:output.appendingPathComponent("fixture.md"), source:#"\(x\)"#,
                    revision:"bootstrap", state:PreviewReaderState(), findRequest:0) { _,_ in }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while host.renderedToken.isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PrototypeError("Production MathJax bootstrap timed out") }
            try await Task.sleep(for:.milliseconds(2))
        }
        _ = try await js(try String(contentsOf:root.appendingPathComponent("tests/benchmarks/mathjax_attachments/browser.js"), encoding:.utf8))
        resourceCount = host.resources.servedPaths.count
    }
    func js(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            // The installed worker object contains functions and cannot cross
            // WebKit's result bridge. This command only needs a completion signal.
            web.evaluateJavaScript(script + "\n;true") { _,error in
                if let error { continuation.resume(throwing:error) }
                else { continuation.resume() }
            }
        }
    }
    func asyncJS(_ body: String, arguments: [String:Any] = [:]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments:arguments, in:nil, in:.page) { result in
                switch result {
                case .success(let value):
                    if let text = value as? String { continuation.resume(returning:text) }
                    else { continuation.resume(throwing:PrototypeError("Expected worker JSON")) }
                case .failure(let error): continuation.resume(throwing:error)
                }
            }
        }
    }
    func render(_ formulas: [MarkdownFormula], format: Format, scale: CGFloat = 2,
                dark: Bool = false, save: String? = nil) async throws -> [Asset?] {
        guard !busy else { throw PrototypeError("Concurrent shared-worker export") }
        guard formulas.allSatisfy({ $0.complete && $0.latex.utf8.count <= 16384 }) else {
            throw PrototypeError("Only complete, bounded formulas may enter the worker")
        }
        busy = true; defer { busy = false }
        try await start()
        let start = milliseconds()
        let items = formulas.map { ["latex":$0.latex,"mode":$0.mode.rawValue] }
        let json = try await asyncJS("return await attachmentPrototype.render(items,15,dark)", arguments:["items":items,"dark":dark])
        let batch = try JSONDecoder().decode(Batch.self, from:Data(json.utf8)); lastBatch = batch
        guard batch.rows.count == formulas.count, batch.width.isFinite, batch.height.isFinite,
              batch.width > 0, batch.height > 0 else { throw PrototypeError("Invalid worker geometry") }
        // Keep temporary atlases bounded. The caller groups larger jobs in eights.
        guard batch.width * batch.height * scale * scale <= 16_000_000,
              max(batch.width,batch.height) * scale <= 16384 else { throw PrototypeError("Atlas pixel budget exceeded") }
        layoutMilliseconds += milliseconds()-start
        let exported = milliseconds()
        var assets: [Asset?]
        if format == .pdf {
            let config = WKPDFConfiguration(); config.rect = NSRect(x:0,y:0,width:batch.width,height:batch.height)
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                web.createPDF(configuration:config) { continuation.resume(with:$0) }
            }
            let atlas = try PDFAtlas(data:data); exportedBytes += data.count
            if let save { try data.write(to:output.appendingPathComponent(save + ".pdf")) }
            assets = batch.rows.map { $0.error == nil ? Asset($0,pdf:atlas) : nil }
        } else {
            let image = try await snapshot(rect:NSRect(x:0,y:0,width:batch.width,height:batch.height), scale:scale)
            guard let cg = image.cgImage(forProposedRect:nil, context:nil, hints:nil) else { throw PrototypeError("No snapshot pixels") }
            if let save {
                let rep = NSBitmapImageRep(cgImage:cg)
                try rep.representation(using:.png, properties:[:])!.write(to:output.appendingPathComponent(save + ".png"))
            }
            let actualScale = CGFloat(cg.width) / batch.width
            assets = try batch.rows.map { geometry in
                guard geometry.error == nil else { return nil }
                let crop = CGRect(x:geometry.x * actualScale,y:geometry.y * actualScale,
                                  width:geometry.width * actualScale,height:geometry.height * actualScale).integral
                guard let tile = cg.cropping(to:crop), let context = CGContext(data:nil,width:tile.width,height:tile.height,
                    bitsPerComponent:8,bytesPerRow:tile.width*4,space:CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PrototypeError("Cannot crop snapshot") }
                // Copy each tile so a cached attachment cannot retain the full atlas.
                context.draw(tile,in:CGRect(x:0,y:0,width:tile.width,height:tile.height))
                let copied = context.makeImage()!; exportedBytes += copied.bytesPerRow * copied.height
                return Asset(geometry,image:copied,scale:actualScale)
            }
        }
        exportMilliseconds += milliseconds()-exported
        jobCount += 1; formulaCount += formulas.count
        _ = try await js("attachmentPrototype.clear()")
        resourceCount = host!.resources.servedPaths.count
        guard host!.resources.failedPaths.isEmpty else { throw PrototypeError("Offline resource failure") }
        return assets
    }
    func snapshot(rect: NSRect, scale: CGFloat) async throws -> NSImage {
        let config = WKSnapshotConfiguration(); config.rect = rect
        config.snapshotWidth = NSNumber(value:Double(rect.width * scale / window!.backingScaleFactor))
        return try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with:config) { image,error in
                if let image { continuation.resume(returning:image) }
                else { continuation.resume(throwing:error ?? PrototypeError("Snapshot failed")) }
            }
        }
    }
    func close() {
        host?.tearDown(); window?.contentView = nil; host = nil; window = nil
    }
}

struct PrototypeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func milliseconds() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

@MainActor private final class AssetCell: NSTextAttachmentCell {
    let asset: SharedMathJaxRenderer.Asset
    nonisolated let dimensions: NSSize, baseline: NSPoint
    init(_ asset: SharedMathJaxRenderer.Asset, source: String) {
        self.asset = asset; dimensions = asset.size
        baseline = NSPoint(x:0,y:-asset.geometry.descent)
        super.init(textCell:""); setAccessibilityLabel(source)
    }
    required init(coder: NSCoder) { fatalError("Research cells are not decoded") }
    nonisolated override func cellSize() -> NSSize { dimensions }
    nonisolated override func cellBaselineOffset() -> NSPoint { baseline }
    override func draw(withFrame frame: NSRect, in view: NSView?) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // TextKit may clamp an oversized cell's drawing frame to the text
        // container. Keep the intrinsic image size, as production vector math
        // does, rather than squeezing a long formula into that frame.
        asset.draw(NSRect(origin:frame.origin,size:dimensions),in:context,flipped:view?.isFlipped ?? true)
    }
    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex: Int) { draw(withFrame:frame,in:view) }
    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex: Int, layoutManager: NSLayoutManager) { draw(withFrame:frame,in:view) }
}
