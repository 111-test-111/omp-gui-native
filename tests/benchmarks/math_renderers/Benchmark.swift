import AppKit
import CoreText
import WebKit
import JavaScriptCore
import SwiftMath

struct Fixture: Codable {
    let id: String
    let group: String
    let latex: String
    let mode: String
    let valid: Bool
    var formula: MarkdownFormula {
        MarkdownFormula(source: mode == "display" ? "$$\(latex)$$" : "$\(latex)$", latex: latex,
                        mode: mode == "display" ? .display : .inline, complete: true)
    }
}

func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}
func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
}
func stats(_ samples: [Double]) -> [String: Any] {
    let sorted = samples.sorted()
    return ["samples_ms": samples, "median_ms": sorted[sorted.count / 2],
            "p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]]
}

@MainActor
final class NativePage {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer
    let view: NSTextView
    init(_ text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: NSSize(width: width, height: 1_000_000))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        view = NSTextView(frame: .zero, textContainer: container)
        view.textContainerInset = .zero
        view.drawsBackground = false
        view.isEditable = false
        container.widthTracksTextView = false
        container.heightTracksTextView = false
    }
    func measure(_ width: CGFloat) -> NSSize {
        container.containerSize.width = width
        manager.ensureLayout(for: container)
        let result = NSSize(width: MathRendering.overflowWidth(storage: storage, layout: manager, container: container, minimum: width),
                            height: ceil(manager.usedRect(for: container).height))
        view.frame = NSRect(origin: .zero, size: result)
        return result
    }
}

@MainActor
func nativeText(_ formulas: [MarkdownFormula], prose: Bool = false) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.systemFont(ofSize: 15)
    for formula in formulas {
        if prose { result.append(NSAttributedString(string: "中文 English 前文 ", attributes: [.font: font])) }
        result.append(MathRendering.attributed(formula, pointSize: 15, color: .black))
        result.append(NSAttributedString(string: prose ? " 后文正常换行。\n" : "\n", attributes: [.font: font]))
    }
    return result
}

@MainActor
func raster(_ page: NativePage, width: CGFloat, height: CGFloat, dark: Bool = false) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width*2), pixelsHigh: Int(height*2),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    (dark ? NSColor(calibratedWhite: 0.10, alpha: 1) : NSColor.white).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    if dark {
        page.storage.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: page.storage.length))
    }
    let visible = page.manager.glyphRange(forBoundingRect: NSRect(x: 0, y: 0, width: width-24, height: height-24), in: page.container)
    page.manager.drawGlyphs(forGlyphRange: visible, at: NSPoint(x: 12, y: 12))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

@MainActor
final class Browser: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let window: NSWindow
    var navigation: CheckedContinuation<Void, Error>?
    init(store: WKWebsiteDataStore? = nil) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store ?? .nonPersistent()
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 900), configuration: config)
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        super.init()
        view.navigationDelegate = self
    }
    func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        _ = try await jsAsync("const probe=document.createElement('span');probe.style.cssText='position:absolute;visibility:hidden';probe.innerHTML=temml.renderToString('x+1');document.body.append(probe);probe.offsetHeight;await document.fonts.ready;probe.remove();return true;")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.navigation?.resume(); self.navigation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.navigation?.resume(throwing: error); self.navigation = nil
    }
    func js(_ source: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(source) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value ?? NSNull()) }
            }
        }
    }
    func jsAsync(_ source: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }
    func snapshot(_ url: URL?, width: CGFloat = 720, height: CGFloat = 900) async throws {
        view.frame.size = NSSize(width: width, height: height)
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: height)
        // snapshotWidth is measured in points. WebKit applies the screen's
        // backing scale itself; multiplying again would produce 4x pixels.
        config.snapshotWidth = NSNumber(value: Double(width * 2 / window.backingScaleFactor))
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: config) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: NSError(domain: "BenchmarkSnapshot", code: 1)) }
            }
        }
        if let url, let data = image.tiffRepresentation {
            try NSBitmapImageRep(data: data)!.representation(using: .png, properties: [:])!.write(to: url)
        }
    }
    func pdf(rect: NSRect) async throws -> Data {
        let config = WKPDFConfiguration(); config.rect = rect
        return try await withCheckedThrowingContinuation { continuation in
            view.createPDF(configuration: config) { result in continuation.resume(with: result) }
        }
    }
}

@main
@MainActor
struct Benchmark {
    static func main() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let mode = args[1]
        let root = URL(fileURLWithPath: args[2])
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("corpus.json")))
        let commonURL = root.appendingPathComponent("common_ids.json")
        let common = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: commonURL)))
        let core = fixtures.filter { $0.group == "core" && (common?.contains($0.id) ?? true) }
        func batch(_ count: Int, salt: Int) -> [MarkdownFormula] {
            (0..<count).map { i in
                let item = core[i % core.count]
                let tex = item.latex + " + \(salt * 1000 + i)"
                return MarkdownFormula(source: "$$\(tex)$$", latex: tex, mode: .display, complete: true)
            }
        }
        if mode == "native-compat" {
            var rows: [[String: Any]] = []
            for item in fixtures {
                let start = now()
                var row: [String: Any] = ["id": item.id, "group": item.group, "valid": item.valid]
                switch MathRendering.result(for: item.formula, pointSize: 15) {
                case .ready(let layout):
                    row.merge(["ok": true, "width": layout.width, "ascent": layout.ascent, "descent": layout.descent]) { _,new in new }
                case .failure(let error): row["ok"] = false; row["error"] = error
                case .pending: row["ok"] = false; row["error"] = "pending"
                }
                row["ms"] = now() - start
                rows.append(row)
            }
            try emit(["engine": "SwiftMath 1.7.3 baseline fd7776e", "rows": rows])
        } else if mode == "native-perf" || mode == "native-cold" {
            let start = now()
            let cold = nativeText([core[1].formula])
            let coldPage = NativePage(cold, width: 696)
            _ = coldPage.measure(696)
            let firstLayout = now() - start
            _ = raster(coldPage, width: 720, height: 240)
            let firstRaster = now() - start
            var output: [String: Any] = ["cold_first_layout_ms": firstLayout, "cold_first_raster_ms": firstRaster]
            if mode == "native-cold" { try emit(output); return }
            var salt = 1
            for count in [1, 20, 100, 500] {
                var typeset: [Double] = [], layout: [Double] = [], drawing: [Double] = []
                for _ in 0..<21 {
                    let formulas = batch(count, salt: salt); salt += 1
                    let t = now()
                    let text = nativeText(formulas)
                    let u = now()
                    let page = NativePage(text, width: 696)
                    _ = page.measure(696)
                    let v = now()
                    _ = raster(page, width: 720, height: 900)
                    let end = now()
                    typeset.append(u-t); layout.append(v-t); drawing.append(end-t)
                }
                output["batch_\(count)"] = ["typeset": stats(typeset), "textkit_layout": stats(layout), "raster_720x900_2x": stats(drawing)]
            }
            let formulas = batch(100, salt: salt)
            _ = nativeText(formulas)
            let before = MathRendering.typesetCount
            var cached: [Double] = []
            for _ in 0..<101 {
                let t = now(); _ = nativeText(formulas); cached.append(now()-t)
            }
            output["cached_100_attachments"] = stats(cached)
            output["cached_additional_typesets"] = MathRendering.typesetCount-before
            var cachedLayout: [Double] = [], cachedRaster: [Double] = []
            for _ in 0..<41 {
                let start = now()
                let cachedPage = NativePage(nativeText(formulas), width: 696)
                _ = cachedPage.measure(696)
                cachedLayout.append(now()-start)
                _ = raster(cachedPage, width: 720, height: 900)
                cachedRaster.append(now()-start)
            }
            output["cached_100_textkit_layout"] = stats(cachedLayout)
            output["cached_100_raster"] = stats(cachedRaster)
            let page = NativePage(nativeText(formulas), width: 696)
            _ = page.measure(696)
            var resize: [Double] = [], theme: [Double] = []
            for i in 0..<41 {
                let t = now(); _ = page.measure(i % 2 == 0 ? 280 : 696); resize.append(now()-t)
                let u = now()
                page.storage.addAttribute(.foregroundColor, value: i % 2 == 0 ? NSColor.white : NSColor.black,
                                          range: NSRange(location: 0, length: page.storage.length))
                _ = raster(page, width: 720, height: 900)
                theme.append(now()-u)
            }
            output["resize_100"] = stats(resize); output["theme_and_raster_100"] = stats(theme)
            output["typeset_count"] = MathRendering.typesetCount
            try emit(output)
        } else if mode == "jsc" {
            let t = now()
            let context = JSContext()!
            var exception = ""
            context.exceptionHandler = { _, value in exception = value?.toString() ?? "error" }
            context.evaluateScript(try String(contentsOf: root.appendingPathComponent("vendor/package/dist/temml.min.js"), encoding: .utf8))
            let load = now()-t
            var output: [String: Any] = ["load_js_ms": load]
            var samples: [Double] = []
            for _ in 0..<41 {
                let start = now()
                let code = "JSON.stringify(" + (try json(core.map { ["latex": $0.latex, "displayMode": $0.mode == "display"] })) + ".map(x=>temml.renderToString(x.latex,{displayMode:x.displayMode,throwOnError:true})))"
                _ = context.evaluateScript(code)?.toString()
                samples.append(now()-start)
            }
            output["convert_common_core_including_bridge"] = stats(samples)
            output["common_core_count"] = core.count
            let markup = context.evaluateScript("temml.renderToString('\\\\frac{a+b}{c+d}',{displayMode:false,throwOnError:true})")!.toString()!
            let data = Data("<!doctype html><html><body><span>prefix </span>\(markup)<span> suffix</span></body></html>".utf8)
            let imported = try NSAttributedString(data: data, options: [.documentType:NSAttributedString.DocumentType.html], documentAttributes: nil)
            var attachments = 0
            imported.enumerateAttribute(.attachment, in: NSRange(location: 0, length: imported.length)) { value,_,_ in if value != nil { attachments += 1 } }
            output["appkit_mathml_import"] = ["text": imported.string, "attachments": attachments, "markup": markup]
            output["exception"] = exception
            try emit(output)
        } else if mode.hasPrefix("web-") {
            let font = args.count > 3 ? args[3] : "local"
            let t = now()
            let browser = Browser()
            try await browser.load(root.appendingPathComponent("vendor/package/dist/bench-\(font).html"))
            let loaded = now()-t
            if mode == "web-compat" {
                let rows = try await browser.js("compat(" + (try json(fixtures.map { ["id": $0.id, "latex": $0.latex, "mode": $0.mode, "group": $0.group, "valid": $0.valid] })) + ")")
                let meta = try await browser.js("JSON.stringify({version:temml.version,userAgent:navigator.userAgent,font:getComputedStyle(document.querySelector('math')).fontFamily,fonts:document.fonts.status})")
                try emit(["load_ms": loaded, "rows_json": rows, "meta_json": meta])
            } else if mode == "web-perf" || mode == "web-cold" {
                let cold = try json([["latex": core[1].latex, "mode": "display"]])
                _ = try await browser.js("renderBatch(\(cold))")
                let firstLayout = now()-t
                try await browser.snapshot(nil, height: 240)
                var output: [String: Any] = ["cold_load_ms": loaded, "cold_first_layout_ms": firstLayout, "cold_first_snapshot_ms": now()-t]
                if mode == "web-cold" { try emit(output); return }
                var salt = 1
                for count in [1, 20, 100, 500] {
                    var convert: [Double] = [], dom: [Double] = [], bridge: [Double] = [], snapshot: [Double] = []
                    for _ in 0..<21 {
                        let formulas = batch(count, salt: salt); salt += 1
                        let payload = try json(formulas.map { ["latex": $0.latex, "mode": $0.mode.rawValue] })
                        let start = now()
                        let result = try await browser.js("renderBatch(\(payload))") as! String
                        let values = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Double]
                        let laidOut = now()
                        try await browser.snapshot(nil)
                        convert.append(values["convert_ms"]!); dom.append(values["total_js_layout_ms"]!)
                        bridge.append(laidOut-start); snapshot.append(now()-start)
                    }
                    output["batch_\(count)"] = ["convert": stats(convert), "dom_layout": stats(dom), "bridge_to_layout": stats(bridge), "snapshot_720x900_2x": stats(snapshot)]
                }
                let payload = try json(batch(100, salt: salt).map { ["latex": $0.latex, "mode": $0.mode.rawValue] })
                _ = try await browser.js("renderBatch(\(payload))")
                var cached: [Double] = [], cachedSnapshot: [Double] = [], resize: [Double] = [], theme: [Double] = []
                for _ in 0..<41 {
                    let start = now(); _ = try await browser.js("renderCached()"); cached.append(now()-start)
                    try await browser.snapshot(nil); cachedSnapshot.append(now()-start)
                }
                for i in 0..<41 {
                    let t = now()
                    _ = try await browser.js("document.getElementById('content').style.width='\(i % 2 == 0 ? 280 : 696)px'; JSON.stringify({height:document.body.offsetHeight,width:document.body.scrollWidth})")
                    resize.append(now()-t)
                    let u = now()
                    _ = try await browser.js("document.body.classList.toggle('dark',\(i % 2 == 0 ? "true" : "false")); document.body.offsetHeight")
                    try await browser.snapshot(nil)
                    theme.append(now()-u)
                }
                output["cached_100_markup_bridge_to_layout"] = stats(cached)
                output["cached_100_snapshot"] = stats(cachedSnapshot)
                output["resize_100"] = stats(resize); output["theme_and_snapshot_100"] = stats(theme)
                try emit(output)
            } else if mode == "web-visual" {
                let chosen = fixtures.filter { ["quadratic", "nested_fraction", "indexed_root", "short_delimiters", "wide_accents", "integral", "matrix", "cases", "aligned", "xrightarrow", "text_chinese", "long_inline"].contains($0.id) }
                _ = try await browser.js("visual(" + (try json(chosen.map { ["id": $0.id, "latex": $0.latex, "mode": $0.mode] })) + ")")
                _ = try await browser.jsAsync("await document.fonts.ready;return true;")
                let geometries = try await browser.js("visualGeometry()")
                try await browser.snapshot(root.appendingPathComponent("temml-\(font)-light.png"), width: 720, height: 1100)
                _ = try await browser.js("document.body.classList.add('dark');document.body.offsetHeight")
                try await browser.snapshot(root.appendingPathComponent("temml-\(font)-dark.png"), width: 720, height: 1100)
                let linebreaks = try await browser.js("linebreakProbe()")
                try emit(["geometry_json": geometries, "linebreaks_json": linebreaks])
            } else if mode == "web-inline" {
                let chosen = fixtures.filter { ["polynomial", "quadratic", "text_chinese", "long_inline"].contains($0.id) }
                _ = try await browser.js("inlineVisual(" + (try json(chosen.map { ["id": $0.id, "latex": $0.latex] })) + ")")
                _ = try await browser.jsAsync("await document.fonts.ready;return true;")
                let geometry = try await browser.js("inlineGeometry()")
                try await browser.snapshot(root.appendingPathComponent("temml-\(font)-inline.png"), width: 1040, height: 640)
                try emit(["geometry_json": geometry])
            } else if mode == "web-attachment-perf" {
                var samples: [Double] = [], first: [String: Any] = [:]
                for round in 0..<11 {
                    let start = now()
                    for i in 0..<100 {
                        let item = core[i % core.count]
                        let payload = try json(["latex":item.latex+" + \(round*1000+i)", "mode":item.mode])
                        let value = try await browser.js("workerRender(\(payload))") as! String
                        let geometry = try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
                        if round == 0 && i == 0 { first = geometry }
                        let width = (geometry["width"] as! Double).rounded(.up)+24
                        let height = (geometry["height"] as! Double).rounded(.up)+24
                        try await browser.snapshot(nil, width: max(48,width), height: max(48,height))
                    }
                    samples.append(now()-start)
                }
                try emit(["shared_worker_100_sequential_images":stats(samples), "first_formula_geometry":first, "startup_ms":loaded])
            } else if mode == "web-copy" {
                let result = try await browser.js("copyProbe()")
                try emit(["copy_json":result])
            } else if mode == "web-pdf-perf" {
                var samples: [Double] = [], sizes: [Int] = []
                var vectorRepresentation = ""
                for round in 0..<11 {
                    let start = now()
                    for i in 0..<100 {
                        let item = core[i % core.count]
                        let payload = try json(["latex":item.latex+" + \(round*1000+i)", "mode":item.mode])
                        let result = try await browser.js("workerRender(\(payload))") as! String
                        let geometry = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Double]
                        let rect = NSRect(x:geometry["x"]!-2,y:geometry["y"]!-2,width:geometry["width"]!+4,height:geometry["height"]!+4)
                        let data = try await browser.pdf(rect: rect)
                        let image = NSImage(data: data)!
                        if round == 0 {
                            sizes.append(data.count)
                            vectorRepresentation = String(describing: type(of: image.representations[0]))
                            if i == 1 { try data.write(to: root.appendingPathComponent("temml-\(font)-sample.pdf")) }
                        }
                    }
                    samples.append(now()-start)
                }
                try emit(["shared_100_sequential_pdf_attachments":stats(samples), "first_100_pdf_bytes":sizes,
                          "total_first_100_pdf_bytes":sizes.reduce(0,+), "native_image_representation":vectorRepresentation])
            } else if mode == "web-atlas-perf" {
                var layouts: [Double] = [], exports: [Double] = [], draws: [Double] = [], totals: [Double] = []
                var pdfSizes: [Int] = []
                for round in 0..<11 {
                    let payload = try json(batch(100, salt: round+1).map { ["latex":$0.latex,"mode":$0.mode.rawValue] })
                    let start = now()
                    let value = try await browser.js("atlasRender(\(payload))") as! String
                    let geometry = try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String:Any]
                    let height = geometry["height"] as! Double
                    let rects = (geometry["rows"] as! [[String:Double]]).map { NSRect(x:$0["x"]!,y:$0["y"]!,width:$0["width"]!,height:$0["height"]!) }
                    layouts.append(now()-start)
                    let data = try await browser.pdf(rect:NSRect(x:0,y:0,width:720,height:height))
                    let document = CGPDFDocument(CGDataProvider(data:data as CFData)!)!
                    let page = document.page(at:1)!
                    exports.append(now()-start);pdfSizes.append(data.count)
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1440,pixelsHigh:1800,bitsPerSample:8,
                        samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                    bitmap.size=NSSize(width:720,height:900)
                    let context=NSGraphicsContext(bitmapImageRep:bitmap)!.cgContext
                    context.setFillColor(NSColor.white.cgColor);context.fill(NSRect(x:0,y:0,width:720,height:900))
                    let drawStart=now()
                    for rect in rects.filter({$0.minY<900}) {
                        // Each attachment clips the same immutable PDF page to
                        // its formula region; Quartz still interprets that page.
                        context.saveGState();context.clip(to:NSRect(x:rect.minX,y:900-rect.maxY,width:rect.width,height:rect.height))
                        context.translateBy(x:0,y:900-page.getBoxRect(.mediaBox).height)
                        context.drawPDFPage(page);context.restoreGState()
                    }
                    draws.append(now()-drawStart);totals.append(now()-start)
                    if round==0 {
                        try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("temml-\(font)-atlas.png"))
                        try await browser.snapshot(root.appendingPathComponent("temml-\(font)-atlas-screen.png"))
                    }
                }
                try emit(["atlas_100_layout":stats(layouts),"atlas_100_pdf_ready":stats(exports),
                          "atlas_100_visible_attachment_draw":stats(draws),"atlas_100_total":stats(totals),"pdf_bytes":pdfSizes])
            }
            browser.view.stopLoading()
        } else if mode == "native-visual" {
            let chosen = fixtures.filter { ["quadratic", "nested_fraction", "indexed_root", "short_delimiters", "wide_accents", "integral", "matrix", "cases", "aligned", "xrightarrow", "text_chinese", "long_inline"].contains($0.id) }
            for dark in [false, true] {
                let width: CGFloat = 720, height: CGFloat = 1100
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 2200, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bitmap.size = NSSize(width: width, height: height)
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
                context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                (dark ? NSColor(calibratedWhite: 0.10, alpha: 1) : NSColor.white).setFill()
                NSRect(x: 0, y: 0, width: width, height: height).fill()
                let color = dark ? NSColor.white : NSColor.black
                for (index, item) in chosen.enumerated() {
                    let y = CGFloat(index)*90 + 12
                    (item.id as NSString).draw(at: NSPoint(x: 12, y: y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.gray])
                    switch MathRendering.result(for: item.formula, pointSize: 15) {
                    case .ready(let layout):
                        let x = max(12, (width-layout.size.width)/2)
                        let rect = NSRect(x: x, y: y+22+(68-layout.size.height)/2, width: layout.size.width, height: layout.size.height)
                        layout.draw(in: rect, context: context, flipped: true, color: color)
                    default:
                        (item.latex as NSString).draw(in: NSRect(x: 12, y: y+44, width: 696, height: 46), withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor:color])
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
                try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("swiftmath-\(dark ? "dark" : "light").png"))
            }
            try emit(["copy_tex": MathRendering.exported(nativeText([core[1].formula], prose: true)).string])
        } else if mode == "native-inline" {
            let chosen = fixtures.filter { ["polynomial", "quadratic", "text_chinese", "long_inline"].contains($0.id) }
            let width: CGFloat = 1040, height: CGFloat = 640
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2080, pixelsHigh: 1280, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = NSSize(width: width, height: height)
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
            var rows: [[String: Any]] = []
            for (x, available) in [(CGFloat(12), CGFloat(696)), (CGFloat(748), CGFloat(280))] {
                ("\(Int(available)) pt" as NSString).draw(at: NSPoint(x: x, y: 12), withAttributes: [.font:NSFont.systemFont(ofSize: 14), .foregroundColor:NSColor.black])
                for (index, item) in chosen.enumerated() {
                    let y = CGFloat(index)*140+45
                    (item.id as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor:NSColor.gray])
                    let formula = MarkdownFormula(source: "$\(item.latex)$", latex: item.latex, mode: .inline, complete: true)
                    let text = nativeText([formula], prose: true)
                    let page = NativePage(text, width: available)
                    let measured = page.measure(available)
                    var fragments: [[String: Double]] = []
                    page.manager.enumerateLineFragments(forGlyphRange: page.manager.glyphRange(for: page.container)) { rect,_,_,_,_ in
                        fragments.append(["y": rect.minY, "height": rect.height])
                    }
                    rows.append(["id":item.id, "width":available, "scrollWidth":measured.width, "height":measured.height, "fragments":fragments])
                    context.saveGState()
                    context.clip(to: NSRect(x: x, y: y+22, width: available, height: 118))
                    page.manager.drawGlyphs(forGlyphRange: page.manager.glyphRange(for: page.container), at: NSPoint(x: x, y: y+22))
                    context.restoreGState()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("swiftmath-inline.png"))
            try emit(["rows": rows])
        } else if mode == "memory" {
            let engine = args[3], count = Int(args[4])!, views = Int(args[5])!
            var pages: [NativePage] = [], browsers: [Browser] = []
            if engine == "native" {
                if count > 0 {
                    let perView = max(1, count / views)
                    for i in 0..<views {
                        let page = NativePage(nativeText(batch(perView, salt: i)), width: 696)
                        _ = page.measure(696); _ = raster(page, width: 720, height: 900)
                        pages.append(page)
                    }
                }
            } else if engine == "webkit" {
                let store = WKWebsiteDataStore.nonPersistent()
                for i in 0..<views {
                    let browser = Browser(store: store)
                    try await browser.load(root.appendingPathComponent("vendor/package/dist/bench-local.html"))
                    let payload = try json(batch(count / views, salt: i).map { ["latex": $0.latex, "mode": $0.mode.rawValue] })
                    _ = try await browser.js("renderBatch(\(payload))")
                    try await browser.snapshot(nil)
                    browsers.append(browser)
                }
            }
            try emit(["phase": "ready", "pid": ProcessInfo.processInfo.processIdentifier, "engine": engine, "count": count, "views": views])
            // Keep layouts and WebKit processes alive for the external RSS sampler.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { _ = readLine(); continuation.resume() }
            }
            withExtendedLifetime(pages) {}; withExtendedLifetime(browsers) {}
        }
    }
}
