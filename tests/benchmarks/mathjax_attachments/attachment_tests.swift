import AppKit
import Foundation

struct Fixture: Decodable {
    let id: String, group: String, latex: String, mode: String
    let valid: Bool
    var formula: MarkdownFormula {
        .init(source:mode == "display" ? "$$\(latex)$$" : "$\(latex)$",latex:latex,
              mode:mode == "display" ? .display : .inline,complete:true)
    }
}
@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PrototypeError(message) }
}
func emit(_ value: [String:Any]) throws {
    print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self))
    fflush(stdout)
}
func stats(_ samples: [Double]) -> [String:Any] {
    let values = samples.sorted()
    return ["samples_ms":samples,"median_ms":values[values.count/2],"p95_ms":values[min(values.count-1,Int(Double(values.count)*0.95))]]
}

@MainActor final class NativePage {
    let storage = NSTextStorage(), manager = NSLayoutManager()
    let container = NSTextContainer(size:NSSize(width:696,height:1_000_000))
    let view: NSTextView
    init() {
        container.lineFragmentPadding = 0; container.widthTracksTextView = false
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        view = NSTextView(frame:.zero,textContainer:container)
        view.textContainerInset = .zero; view.drawsBackground = false; view.isEditable = false
        container.widthTracksTextView = false; container.heightTracksTextView = false
    }
    @discardableResult func update(_ text: NSAttributedString, width: CGFloat = 696) -> NSSize {
        storage.setAttributedString(text); container.containerSize.width = width
        manager.ensureLayout(for:container)
        let measured = NSSize(width:MathRendering.overflowWidth(storage:storage,layout:manager,container:container,minimum:width),
                              height:ceil(manager.usedRect(for:container).height))
        view.frame = NSRect(origin:.zero,size:measured)
        return measured
    }
    func draw(width: CGFloat = 720, height: CGFloat = 900, scale: CGFloat = 2, dark: Bool = false, url: URL? = nil) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(width*scale),pixelsHigh:Int(height*scale),
                                  bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        rep.size = NSSize(width:width,height:height)
        let cg = NSGraphicsContext(bitmapImageRep:rep)!.cgContext
        cg.translateBy(x:0,y:height); cg.scaleBy(x:1,y:-1)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext:cg,flipped:true)
        (dark ? NSColor(calibratedWhite:0.10,alpha:1) : .white).setFill()
        NSRect(x:0,y:0,width:width,height:height).fill()
        let visible = manager.glyphRange(forBoundingRect:NSRect(x:0,y:0,width:width-24,height:height-24),in:container)
        manager.drawGlyphs(forGlyphRange:visible,at:NSPoint(x:12,y:12))
        if let url { try rep.representation(using:.png,properties:[:])!.write(to:url) }
    }
}

@MainActor final class AttachmentDriver {
    struct Entry { let asset: SharedMathJaxRenderer.Asset? }
    let route: String, worker: SharedMathJaxRenderer
    var entries: [String:Entry] = [:], order: [String] = []
    var dark = false, scale: CGFloat = 2
    private(set) var peakCacheCost = 0, evictions = 0
    var native: Bool { route == "native" }
    init(_ route: String, root: URL, output: URL) { self.route = route; worker = .init(root:root,output:output) }
    func key(_ formula: MarkdownFormula) -> String { "\(formula.mode.rawValue):\(dark):\(scale):\(formula.latex)" }
    var cacheCost: Int {
        var pdfs = Set<ObjectIdentifier>(), pixels = Set<ObjectIdentifier>(), result = 0
        for (key,entry) in entries {
            result += key.utf8.count + 256
            if let pdf = entry.asset?.pdf, pdfs.insert(ObjectIdentifier(pdf)).inserted { result += pdf.data.count }
            if let image = entry.asset?.image, pixels.insert(ObjectIdentifier(image)).inserted { result += image.bytesPerRow * image.height }
        }
        return result
    }
    func trim() {
        while order.count > 256 || cacheCost > 16*1024*1024 {
            entries.removeValue(forKey:order.removeFirst()); evictions += 1
        }
        peakCacheCost = max(peakCacheCost,cacheCost)
    }
    func clear() { entries.removeAll(); order.removeAll() }
    func fill(_ formulas: [MarkdownFormula], save: String? = nil) async throws {
        if native {
            for formula in formulas where formula.complete { _ = MathRendering.result(for:formula,pointSize:15) }
            return
        }
        var seen = Set<String>()
        let missing = formulas.filter { $0.complete && entries[key($0)] == nil && seen.insert(key($0)).inserted }
        for offset in stride(from:0,to:missing.count,by:8) {
            let batch = Array(missing[offset..<min(offset+8,missing.count)])
            let assets = try await worker.render(batch,format:route == "pdf" ? .pdf : .png,scale:scale,dark:dark,
                                                  save:save.map { "\($0)-\(offset/8)" })
            for (formula,asset) in zip(batch,assets) {
                let item = key(formula); entries[item] = Entry(asset:asset)
                order.removeAll { $0 == item }; order.append(item)
            }
            trim()
        }
    }
    func ready(_ formula: MarkdownFormula) -> Bool { native || entries[key(formula)] != nil }
    func attributed(_ formula: MarkdownFormula) -> NSAttributedString {
        let color: NSColor = dark ? .white : .black
        if native { return MathRendering.attributed(formula,pointSize:15,color:color) }
        let item = key(formula)
        if let entry = entries[item] {
            order.removeAll { $0 == item }; order.append(item)
            if let asset = entry.asset { return asset.attributed(formula,color:color) }
        }
        return NSAttributedString(string:formula.source,attributes:[.font:NSFont.systemFont(ofSize:15),.foregroundColor:color])
    }
    func body(_ source: String, streaming: Bool = false) -> NSAttributedString {
        let parsed = MarkdownInline.parse(source,streaming:streaming)
        let text = NSMutableAttributedString()
        for run in parsed.runs {
            if let formula = run[MarkdownFormulaAttribute.self] { text.append(attributed(formula)) }
            else {
                var attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:15),.foregroundColor:dark ? NSColor.white : .black]
                if let link = run.link { attrs[.link] = link }
                text.append(NSAttributedString(string:String(parsed[run.range].characters),attributes:attrs))
            }
        }
        return text
    }
    func list(_ formulas: [MarkdownFormula], prose: Bool = false) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:15),.foregroundColor:dark ? NSColor.white : .black]
        for formula in formulas {
            if prose { text.append(NSAttributedString(string:"中文 English 前文 ",attributes:attrs)) }
            text.append(attributed(formula))
            text.append(NSAttributedString(string:prose ? " 后文继续。\n" : "\n",attributes:attrs))
        }
        return text
    }
}

/// Native prose is published immediately. Ready attachments are applied against
/// the latest text; a new message generation rejects late work from its predecessor.
@MainActor final class StreamingPage {
    let driver: AttachmentDriver, page = NativePage()
    var source = "", generation = 0, running = false
    var pending: Task<Void,Never>?, failure: Error?
    var mainSamples: [Double] = [], drawingSamples: [Double] = [], latencies: [Double] = []
    var closedAt: [String:Double] = [:], delivered = Set<String>()
    var updates = 0, staleResults = 0, publishedAttachments = 0
    init(_ driver: AttachmentDriver) { self.driver = driver }
    func accept(_ value: String) throws {
        source = value; updates += 1
        let start = milliseconds()
        let completed = MarkdownMath.spans(in:source).map(\.formula).filter(\.complete)
        for formula in completed {
            let key = driver.key(formula)
            if closedAt[key] == nil { closedAt[key] = start }
        }
        page.update(driver.body(source,streaming:true))
        mainSamples.append(milliseconds()-start)
        let paint = milliseconds(); try page.draw(); drawingSamples.append(milliseconds()-paint)
        recordDelivery()
        if !driver.native && !running && completed.contains(where:{ !driver.ready($0) }) { drain() }
    }
    func recordDelivery() {
        for formula in MarkdownMath.spans(in:source).map(\.formula) where formula.complete && driver.ready(formula) {
            let key = driver.key(formula)
            if delivered.insert(key).inserted, let closed = closedAt[key] {
                latencies.append(milliseconds()-closed); publishedAttachments += 1
            }
        }
    }
    func drain() {
        running = true
        let expected = generation
        pending = Task { @MainActor in
            defer { running = false }
            do {
                while expected == generation {
                    let formulas = MarkdownMath.spans(in:source).map(\.formula).filter(\.complete)
                    let missing = formulas.filter { !driver.ready($0) }
                    if !missing.isEmpty { try await driver.fill(missing) }
                    guard expected == generation else { staleResults += 1; return }
                    let start = milliseconds()
                    page.update(driver.body(source,streaming:true))
                    mainSamples.append(milliseconds()-start)
                    let paint = milliseconds(); try page.draw(); drawingSamples.append(milliseconds()-paint)
                    recordDelivery()
                    if MarkdownMath.spans(in:source).filter({ $0.formula.complete && !driver.ready($0.formula) }).isEmpty { return }
                }
            } catch { failure = error }
        }
    }
    func finish() async throws {
        await pending?.value
        if let failure { throw failure }
        try require(!running,"Stream failed to settle")
    }
}

@main @MainActor struct AttachmentBenchmarks {
    static func main() async {
        do { try await run() } catch { fputs("PROTOTYPE FAILED: \(error)\n",stderr); exit(1) }
    }
    static func run() async throws {
        _ = NSApplication.shared; NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let phase = args[1], route = args[2], root = URL(fileURLWithPath:args[3]), output = URL(fileURLWithPath:args[4])
        let fixtures = try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:output.appendingPathComponent("corpus.json")))
        let core = (phase == "compat" ? fixtures : []).filter { $0.valid && $0.group == "core" }.filter {
            if case .ready = MathRendering.result(for:$0.formula,pointSize:15) { return true }; return false
        }
        // Compatibility selection above happens only in the compatibility phase;
        // cold/performance use the fixed IDs written by that phase in new processes.
        let ids = (try? JSONDecoder().decode([String].self,from:Data(contentsOf:output.appendingPathComponent("common_ids.json"))))
        let common = ids.map { ids in fixtures.filter { ids.contains($0.id) } } ?? core
        func batch(_ count: Int, _ salt: Int) -> [MarkdownFormula] {
            (0..<count).map { i in
                let latex = common[i % common.count].latex + " + \(salt*1000+i)"
                return .init(source:"$$\(latex)$$",latex:latex,mode:.display,complete:true)
            }
        }
        let driver = AttachmentDriver(route,root:root,output:output)
        if phase == "compat" {
            var rows: [[String:Any]] = []
            if route == "native" {
                for fixture in fixtures {
                    var row: [String:Any] = ["id":fixture.id,"valid":fixture.valid,"group":fixture.group]
                    switch MathRendering.result(for:fixture.formula,pointSize:15) {
                    case .ready: row["ok"] = true
                    case .failure(let message): row["ok"] = false; row["error"] = message
                    case .pending: row["ok"] = false
                    }
                    rows.append(row)
                }
            } else {
                for fixture in fixtures {
                    try await driver.fill([fixture.formula])
                    let asset = driver.entries[driver.key(fixture.formula)]?.asset
                    rows.append(["id":fixture.id,"valid":fixture.valid,"group":fixture.group,"ok":asset != nil,
                                 "ascent":asset?.geometry.ascent ?? 0,"descent":asset?.geometry.descent ?? 0])
                }
                let source = "中文 😀 $x_i^2$ 和 $\\text{中文条件}$ 结束  \n[link](https://example.com)"
                try await driver.fill(MarkdownMath.spans(in:source).map(\.formula))
                let text = driver.body(source), copied = MathRendering.exported(text).string
                try require(copied.contains("$x_i^2$") && copied.contains("$\\text{中文条件}$") && copied.contains("中文 😀") && copied.contains("\n"),"TeX/Unicode/hard-break copy lost")
                var hasLink = false
                text.enumerateAttribute(.link,in:NSRange(location:0,length:text.length)) { value,_,_ in if value != nil { hasLink = true } }
                try require(hasLink,"Native link attributes lost")
                let jobs = driver.worker.jobCount
                try await driver.fill([.init(source:"$\\frac{x}{",latex:"\\frac{x}{",mode:.inline,complete:false)])
                try require(driver.worker.jobCount == jobs,"Unfinished formula reached MathJax")
                // A fresh job must not inherit a previous job's macro definition.
                let isolated = MarkdownFormula(source:"",latex:#"\prototypeMacro"#,mode:.inline,complete:true)
                try await driver.fill([.init(source:"",latex:#"\def\prototypeMacro{X}\prototypeMacro"#,mode:.inline,complete:true)])
                try await driver.fill([isolated])
                try require(driver.entries[driver.key(isolated)]?.asset == nil,"TeX macro leaked across jobs")
            }
            try emit(["phase":phase,"route":route,"rows":rows,"common_core_ids":core.map(\.id),"core_count":core.count])
        } else if phase == "cold" {
            let formula = fixtures.first { $0.id == "quadratic" }!.formula
            let start = milliseconds(); try await driver.fill([formula])
            let page = NativePage(); page.update(driver.list([formula])); let layout = milliseconds()-start
            try page.draw(height:240)
            try emit(["phase":phase,"route":route,"layout_ms":layout,"paint_ms":milliseconds()-start])
        } else if phase == "performance" {
            try await driver.fill(batch(1,1))
            var result: [String:Any] = ["phase":phase,"route":route]
            for count in [1,20,100] {
                var layout: [Double] = [], paint: [Double] = [], main: [Double] = []
                for round in 0..<7 {
                    let formulas = batch(count,100+count*10+round)
                    let start = milliseconds(); try await driver.fill(formulas)
                    let nativeStart = milliseconds(), page = NativePage()
                    page.update(driver.list(formulas)); main.append(milliseconds()-nativeStart)
                    layout.append(milliseconds()-start); try page.draw(); paint.append(milliseconds()-start)
                }
                result["batch_\(count)"] = ["layout":stats(layout),"paint":stats(paint),"native_assembly_layout":stats(main)]
            }
            let formulas = batch(100,999); try await driver.fill(formulas)
            var cached: [Double] = [], drawing: [Double] = []
            for _ in 0..<11 {
                let start = milliseconds(); let page = NativePage(); page.update(driver.list(formulas)); cached.append(milliseconds()-start)
                try page.draw(); drawing.append(milliseconds()-start)
            }
            result["cached_layout"] = stats(cached); result["cached_paint"] = stats(drawing)
            result["cache_estimated_bytes"] = driver.cacheCost; result["cache_count"] = driver.entries.count
            result["worker_jobs"] = driver.worker.jobCount; result["worker_layout_ms"] = driver.worker.layoutMilliseconds
            result["worker_export_ms"] = driver.worker.exportMilliseconds
            try emit(result)
        } else if phase == "stream" {
            try await driver.fill(batch(1,1))
            let rate = Int(args[5])!, stream = StreamingPage(driver)
            let formulas = batch(30,765)
            let source = formulas.enumerated().map { "第\($0.offset+1)步 中文 English $\($0.element.latex)$ 后文。\n" }.joined()
            let characters = Array(source); var partial = ""
            let start = milliseconds()
            for offset in stride(from:0,to:characters.count,by:12) {
                partial += String(characters[offset..<min(offset+12,characters.count)])
                try stream.accept(partial)
                try await Task.sleep(for:.milliseconds(rate))
            }
            try await stream.finish()
            try require(stream.publishedAttachments == 30,"Stream lost completed formulas: \(stream.publishedAttachments)")
            let end = milliseconds()
            try require(MathRendering.exported(stream.page.storage).string.contains("第30步"),"Final native prose was not published")
            // Supersede an actual asynchronous in-flight export with a new message.
            var rejectedResults = 0
            if !driver.native {
                let cancelled = StreamingPage(driver)
                try cancelled.accept("old $\\frac{99999}{77777}$")
                let deadline = milliseconds()+1000
                while !driver.worker.isRendering && milliseconds() < deadline { try await Task.sleep(for:.milliseconds(1)) }
                try require(driver.worker.isRendering,"Cancellation probe never started an export")
                cancelled.generation += 1; cancelled.source = "new message"
                cancelled.page.update(NSAttributedString(string:"new message"))
                try await cancelled.finish()
                try require(cancelled.staleResults == 1,"Cancellation probe did not reject the in-flight result")
                rejectedResults = cancelled.staleResults
                try require(cancelled.page.storage.string == "new message","A late export changed the replacement message")
            }
            try emit(["phase":phase,"route":route,"interval_ms":rate,"updates":stream.updates,"wall_ms":end-start,
                      "closure_to_paint":stats(stream.latencies),"main_update":stats(stream.mainSamples),
                      "native_draw":stats(stream.drawingSamples),"published_formulas":stream.publishedAttachments,
                      "worker_formulas":driver.worker.formulaCount,"worker_jobs":driver.worker.jobCount,
                      "generation_rejected_results":rejectedResults])
        } else if phase == "visual" {
            let names = ["quadratic","nested_fraction","indexed_root","wide_accents","integral","matrix","cases","aligned","xrightarrow","text_chinese","long_inline"]
            let chosen = names.compactMap { name in fixtures.first { $0.id == name } }
            var rows: [[String:Any]] = []
            for dark in [false,true] {
                driver.dark = dark
                let formulas = chosen.map { MarkdownFormula(source:"$\($0.latex)$",latex:$0.latex,mode:.inline,complete:true) }
                try await driver.fill(formulas,save:"\(route)-atlas-\(dark ? "dark" : "light")")
                if !driver.native, let fraction = formulas.first(where:{ $0.latex == chosen.first(where:{ $0.id == "nested_fraction" })?.latex }),
                   let geometry = driver.entries[driver.key(fraction)]?.asset?.geometry {
                    try require(geometry.height > 25 && geometry.width > 20,
                                "Dynamic CHTML CSS missing: nested fraction collapsed to a text line")
                }
                for width: CGFloat in [696,280] {
                    let page = NativePage()
                    let text = NSMutableAttributedString()
                    for (fixture,formula) in zip(chosen,formulas) {
                        text.append(NSAttributedString(string:fixture.id+"\n",attributes:[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:dark ? NSColor.lightGray : .gray]))
                        text.append(driver.list([formula],prose:true)); text.append(NSAttributedString(string:"\n"))
                    }
                    let size = page.update(text,width:width)
                    try page.draw(width:width+24,height:max(900,min(1400,size.height+24)),dark:dark,
                                  url:output.appendingPathComponent("\(route)-\(Int(width))-\(dark ? "dark" : "light").png"))
                    rows.append(["dark":dark,"width":width,"content_width":size.width,"height":size.height])
                    if width == 696 && !dark {
                        try page.draw(width:720,height:350,scale:4,url:output.appendingPathComponent("\(route)-zoom-4x.png"))
                    }
                }
            }
            try emit(["phase":phase,"route":route,"geometry":rows])
        } else if phase == "memory" {
            try emit(["phase":"baseline","route":route]); await acknowledge()
            if !driver.native { try await driver.worker.start() }
            try emit(["phase":"worker_ready","route":route]); await acknowledge()
            var page: NativePage? = NativePage()
            try await driver.fill(batch(100,1)); page!.update(driver.list(batch(100,1))); try page!.draw()
            try emit(["phase":"visible_100","route":route,"cache_count":driver.entries.count,"cache_bytes":driver.cacheCost]); await acknowledge()
            for i in 0..<10 {
                let formulas = batch(100,i+10)
                try await driver.fill(formulas); page!.update(driver.list(formulas)); try page!.draw()
            }
            try require(driver.entries.count <= 256 && driver.cacheCost <= 16*1024*1024,"Attachment cache exceeded its budget")
            try emit(["phase":"churn_1000","route":route,"cache_count":driver.entries.count,"cache_bytes":driver.cacheCost,"evictions":driver.evictions]); await acknowledge()
            page = nil; driver.clear()
            try emit(["phase":"cache_released","route":route]); await acknowledge()
            driver.worker.close()
            try emit(["phase":"worker_released","route":route]); await acknowledge()
        } else { throw PrototypeError("Unknown phase \(phase)") }
        driver.worker.close()
    }
    static func acknowledge() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            DispatchQueue.global().async { _ = readLine(); continuation.resume() }
        }
    }
}
