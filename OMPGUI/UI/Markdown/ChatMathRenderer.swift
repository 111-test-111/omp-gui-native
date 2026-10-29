import AppKit
import WebKit
import Accelerate

/// One transient, offline WebView for all chat formulas. Cached cells own copied
/// pixel masks, never a WebView, DOM node or the shared snapshot atlas.
@MainActor final class ChatMathRenderer: NSObject, WKNavigationDelegate {
    static let shared = ChatMathRenderer()
    static let idleSeconds: Double = 60
    var resourceRoot = Bundle.main.url(forResource: "MarkdownPreview", withExtension: nil)
    private var web: WKWebView?
    private var window: NSWindow?
    private var resources: PreviewMarkdownResources?
    private var idleTask: Task<Void, Never>?
    private var navigationError: Error?
    private var navigationFinished = false
    private var busy = false
    private(set) var creationCount = 0
    private(set) var batchCount = 0
    var isLoaded: Bool { web != nil }
    #if DEBUG
    static var timingObserver: ((String, Double) -> Void)?
    #endif

    struct Failure: Error { let message: String }
    struct Geometry: Decodable, Sendable {
        var x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0, descent: CGFloat = 0, axis: CGFloat = 0
        var error: String?
        enum CodingKeys: CodingKey { case x, y, width, height, descent, axis, error }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
            y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
            width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0
            height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
            descent = try c.decodeIfPresent(CGFloat.self, forKey: .descent) ?? 0
            axis = try c.decodeIfPresent(CGFloat.self, forKey: .axis) ?? 0
            error = try c.decodeIfPresent(String.self, forKey: .error)
        }
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    private struct Batch: Decodable { let rows: [Geometry]; let width: CGFloat, height: CGFloat }

    // Immutable copied CoreGraphics pixels can be prepared and cached away from
    // the main actor; cells only draw them on the native text view's thread.
    final class Image: @unchecked Sendable {
        let mask: CGImage
        let foregroundMask: CGImage
        let explicitColors: CGImage?
        let scale: CGFloat
        let descent: CGFloat
        let axis: CGFloat
        var size: NSSize { NSSize(width: CGFloat(mask.width) / scale, height: CGFloat(mask.height) / scale) }
        var cost: Int { mask.bytesPerRow * mask.height + (foregroundMask === mask ? 0 : foregroundMask.bytesPerRow * foregroundMask.height) + (explicitColors.map { $0.bytesPerRow * $0.height } ?? 0) }

        init(mask: CGImage, foregroundMask: CGImage, explicitColors: CGImage?, scale: CGFloat, descent: CGFloat, axis: CGFloat) {
            self.mask = mask; self.foregroundMask = foregroundMask; self.explicitColors = explicitColors
            self.scale = scale; self.descent = descent; self.axis = axis
        }

        init(snapshot: CGImage, geometry: Geometry, scale: CGFloat) throws {
            let crop = CGRect(x: geometry.x * scale, y: geometry.y * scale,
                              width: geometry.width * scale, height: geometry.height * scale).integral
            guard let tile = snapshot.cropping(to: crop),
                  let context = CGContext(data: nil, width: tile.width, height: tile.height,
                    bitsPerComponent: 8, bytesPerRow: tile.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  let data = context.data else { throw Failure(message: "Unable to render formula") }
            context.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
            let pixels = data.bindMemory(to: UInt8.self, capacity: tile.width * tile.height * 4)
            // An opaque WebKit page must never silently become a rectangular tile.
            guard pixels[3] == 0, pixels[(tile.width * tile.height - 1) * 4 + 3] == 0 else {
                throw Failure(message: "Unable to render formula")
            }
            let rowBytes = tile.width * 4
            var top = 0, bottom = tile.height - 1
            // A premultiplied transparent row is all zero. Compare whole rows
            // in libc instead of inspecting every pixel in Swift Debug builds.
            Data(count: rowBytes).withUnsafeBytes { zero in
                while top < tile.height && memcmp(pixels.advanced(by: top * rowBytes), zero.baseAddress!, rowBytes) == 0 { top += 1 }
                while bottom >= top && memcmp(pixels.advanced(by: bottom * rowBytes), zero.baseAddress!, rowBytes) == 0 { bottom -= 1 }
            }
            guard bottom >= top else { throw Failure(message: "Empty formula") }
            let padding = Int(ceil(2 * scale))
            // Crop empty vertical pixels, retaining the TeX baseline/axis. The
            // full ink centre moves with punctuation and scripts; the axis does not.
            let width = tile.width, height = bottom - top + 1 + padding * 2
            var alpha = [UInt8](repeating: 0, count: width * height)
            var input = vImage_Buffer(data: pixels.advanced(by: top * rowBytes), height: vImagePixelCount(bottom - top + 1),
                                      width: vImagePixelCount(width), rowBytes: rowBytes)
            let extracted = alpha.withUnsafeMutableBytes { bytes -> vImage_Error in
                var output = vImage_Buffer(data: bytes.baseAddress!.advanced(by: padding * width), height: input.height, width: input.width, rowBytes: width)
                // Our bytes are RGBA: channel 3 is alpha, regardless of the API's ARGB name.
                return vImageExtractChannel_ARGB8888(&input, &output, 3, vImage_Flags(kvImageNoFlags))
            }
            var histogram = [vImagePixelCount](repeating: 0, count: 4 * 256)
            let counted = histogram.withUnsafeMutableBufferPointer { bins in
                var channels = (0..<4).map { Optional(bins.baseAddress!.advanced(by: $0 * 256)) }
                return channels.withUnsafeMutableBufferPointer {
                    vImageHistogramCalculation_ARGB8888(&input, $0.baseAddress!, vImage_Flags(kvImageNoFlags))
                }
            }
            guard extracted == kvImageNoError, counted == kvImageNoError else { throw Failure(message: "Unable to render formula") }
            let total = input.width * input.height
            let hasColors = histogram[0] != total || histogram[256] != total || histogram[512] != total
            var foreground: [UInt8] = [], colors: [UInt8] = []
            if hasColors {
                foreground = [UInt8](repeating: 0, count: width * height)
                colors = [UInt8](repeating: 0, count: width * height * 4)
                for y in top...bottom {
                    for x in 0..<tile.width {
                        let source = (y * tile.width + x) * 4
                        let target = (y - top + padding) * width + x
                        if pixels[source] > 0 || pixels[source + 1] > 0 || pixels[source + 2] > 0 {
                            for c in 0..<4 { colors[target * 4 + c] = pixels[source + c] }
                        } else { foreground[target] = pixels[source + 3] }
                    }
                }
            }
            func makeMask(_ bytes: [UInt8]) throws -> CGImage {
                guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                      let image = CGImage(maskWidth: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                        bytesPerRow: width, provider: provider, decode: [1, 0], shouldInterpolate: true) else {
                    throw Failure(message: "Unable to render formula")
                }
                return image
            }
            mask = try makeMask(alpha)
            foregroundMask = hasColors ? try makeMask(foreground) : mask
            if hasColors, let provider = CGDataProvider(data: Data(colors) as CFData) {
                explicitColors = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            } else { explicitColors = nil }
            self.scale = scale
            descent = CGFloat(bottom + 1 + padding) / scale - (geometry.y + geometry.height - geometry.descent - crop.minY / scale)
            axis = geometry.axis
        }

        func draw(at origin: NSPoint, context: CGContext, flipped: Bool, color: NSColor, selected: Bool) {
            context.saveGState(); defer { context.restoreGState() }
            context.translateBy(x: origin.x, y: origin.y + (flipped ? size.height : 0))
            if flipped { context.scaleBy(x: 1, y: -1) }
            let rect = CGRect(origin: .zero, size: size)
            context.interpolationQuality = .high
            context.saveGState()
            context.clip(to: rect, mask: selected ? mask : foregroundMask)
            context.setFillColor(color.cgColor)
            context.fill(rect)
            context.restoreGState()
            if !selected, let explicitColors {
                context.setAlpha(color.alphaComponent)
                context.draw(explicitColors, in: rect)
            }
        }
    }

    func render(_ formulas: [MarkdownFormula], pointSize: CGFloat, scale: CGFloat) async throws -> [Image?] {
        #if DEBUG
        var stageStart = ProcessInfo.processInfo.systemUptime
        func stage(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            Self.timingObserver?(name, (now - stageStart) * 1000); stageStart = now
        }
        #endif
        precondition(!busy)
        idleTask?.cancel(); idleTask = nil
        busy = true
        defer { busy = false; recycleAfterIdle() }
        try await start()
        #if DEBUG
        stage("navigation")
        #endif
        guard let web, let window else { throw Failure(message: "Unable to render formula") }
        let items = formulas.map { ["latex": $0.latex, "mode": $0.mode.rawValue] }
        let json = try await evaluate("return await chatMath.render(items, size)", arguments: ["items": items, "size": pointSize])
        #if DEBUG
        stage("mathjax_fonts_layout")
        #endif
        let batch = try JSONDecoder().decode(Batch.self, from: Data(json.utf8))
        guard batch.rows.count == formulas.count, batch.width.isFinite, batch.height.isFinite,
              batch.width > 0, batch.height > 0, batch.width * batch.height * scale * scale <= 16_000_000,
              max(batch.width, batch.height) * scale <= 16_384 else { throw Failure(message: "Formula is too complex") }
        // WKSnapshotConfiguration cannot expose pixels outside the native view's
        // backing surface. Grow that surface before exporting a wide/tall atlas.
        window.setContentSize(NSSize(width: max(720, batch.width), height: max(900, batch.height)))
        web.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: batch.width, height: batch.height)
        config.snapshotWidth = NSNumber(value: Double(ceil(batch.width * scale / window.backingScaleFactor)))
        config.afterScreenUpdates = true
        var images: [Image?] = []
        for attempt in 0..<2 {
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: config) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? Failure(message: "Unable to render formula")) }
                }
            }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  resources?.failedPaths.isEmpty == true else { throw Failure(message: "Unable to render formula") }
            let actualScale = CGFloat(cg.width) / batch.width
            #if DEBUG
            stage("snapshot")
            #endif
            do {
                images = try await Task.detached(priority: .userInitiated) {
                    try batch.rows.map { row in row.error == nil ? try Image(snapshot: cg, geometry: row, scale: actualScale) : nil }
                }.value
                #if DEBUG
                stage("pixel_masks")
                #endif
                break
            } catch {
                // A freshly recreated, unshown WebView can acknowledge layout
                // before its first compositor surface contains the new glyphs.
                // Retry the snapshot once, without rerunning TeX or changing text.
                guard attempt == 0, (error as? Failure)?.message == "Empty formula" else { throw error }
                web.needsDisplay = true
                web.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(32))
            }
        }
        _ = try await evaluate("chatMath.clear(); return 'ok'")
        #if DEBUG
        stage("clear")
        #endif
        batchCount += 1
        return images
    }

    private func start() async throws {
        if web != nil { return }
        guard let resourceRoot else { throw Failure(message: "Unable to render formula") }
        let resources = PreviewMarkdownResources(root: resourceRoot)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(resources, forURLScheme: "omp-preview")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 900), configuration: config)
        web.navigationDelegate = self
        web.underPageBackgroundColor = .clear
        if web.responds(to: NSSelectorFromString("_setDrawsBackground:")) { web.setValue(false, forKey: "drawsBackground") }
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        self.web = web; self.window = window; self.resources = resources
        creationCount += 1; navigationError = nil; navigationFinished = false
        web.load(URLRequest(url: URL(string: "omp-preview://bundle/chat-math.html")!))
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !navigationFinished && navigationError == nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else { release(); throw Failure(message: "Unable to render formula") }
            try await Task.sleep(for: .milliseconds(5))
        }
        if let navigationError { release(); throw navigationError }
    }

    private func evaluate(_ body: String, arguments: [String: Any] = [:]) async throws -> String {
        guard let web else { throw Failure(message: "Unable to render formula") }
        // A bounded bridge also handles a hung or terminated WebContent process.
        final class Reply {
            var continuation: CheckedContinuation<String, Error>?
            var timeout: Task<Void, Never>?
            func finish(_ result: Swift.Result<String, Error>) {
                let continuation = continuation; self.continuation = nil
                timeout?.cancel(); timeout = nil
                continuation?.resume(with: result)
            }
        }
        let reply = Reply()
        return try await withCheckedThrowingContinuation { continuation in
            reply.continuation = continuation
            reply.timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                reply.finish(.failure(Failure(message: "Unable to render formula")))
                self.release()
            }
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    reply.finish((value as? String).map { .success($0) } ?? .failure(Failure(message: "Unable to render formula")))
                case .failure(let error): reply.finish(.failure(error))
                }
            }
        }
    }

    func recycleAfterIdle(seconds: Double = idleSeconds) {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !self.busy else { return }
            self.release()
        }
    }
    func release() {
        idleTask?.cancel(); idleTask = nil
        web?.navigationDelegate = nil; web?.stopLoading()
        resources?.cancel()
        window?.contentView = nil; window?.close()
        web = nil; window = nil; resources = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if self.web === webView { navigationFinished = true }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if self.web === webView { navigationError = error }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if self.web === webView { navigationError = error }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if self.web === webView { navigationError = Failure(message: "Unable to render formula"); release() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.scheme == "omp-preview" && action.request.url?.host == "bundle" ? .allow : .cancel
    }
}
