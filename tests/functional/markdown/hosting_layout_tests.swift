import AppKit
import SwiftUI
@testable import OMPGUI

private struct HostingFailure: Error { let message: String }

@MainActor private final class CountingHost: NSHostingView<AnyView> {
    var passes = 0
    override func layout() {
        passes += 1
        if passes > 100 { fatalError("Markdown host did not settle after 100 layout passes") }
        super.layout()
    }
}

@main private enum HostingLayoutChecks {
    @MainActor private static func checkListSpacing() async throws {
        let unordered = [
            "- 最终读取后：累计用量已更新为 `30`，请求仍为 `running`。\n- writer 完成落盘后：磁盘为 `completed`，面板和报告仍为 `running`，`reportedInput=null`；没有错误，也没有后续刷新。",
            "- 历史占用与导出共用[来源选择逻辑](OMPGUI/App/Preview/ContextWorkspaceStore.swift:163)，压缩失效后保留未知值，活跃 worker 保留实时进度值。\n- [采集证据](OMPGUI/Core/Models/OMPContextInspection.swift:135)保留三态：缺失为 `- / null`，显式 `false/true` 不变。",
            "- 第一项是普通中文正文，包含 English 和足够长的内容来触发窄列自动换行，保持完整文字。\n- 第二项同样是普通中文正文，保持统一的条目间距。",
            "- **第一项加粗正文**，包含足够长的内容来触发窄列自动换行，保持完整文字。\n- 第二项混合 `inline code` 与普通正文，保持统一间距。",
        ]
        let fixtures = unordered + unordered.map { source in
            source.split(separator: "\n").enumerated().map { index, line in
                "\(index + 1). " + line.dropFirst(2)
            }.joined(separator: "\n")
        }
        func textViews(_ view: NSView) -> [LinkTextView] {
            (view as? LinkTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        func baseline(_ view: LinkTextView, at character: Int) -> CGFloat {
            let layout = view.layoutManager!
            let glyph = layout.glyphIndexForCharacter(at: character)
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + layout.location(forGlyphAt: glyph).y
        }
        var comparisons = 0
        for (index, source) in fixtures.enumerated() {
            let text = ProseRunRepresentable.attributed(blocks: MarkdownParser.parse(source), pointSize: 15, dimmed: false, mentions: [])
            let continuous = LinkTextView()
            continuous.render(text)
            let marker = index < unordered.count ? "•\t" : "2.\t"
            let separator = (text.string as NSString).range(of: "\n" + marker).location
            guard separator != NSNotFound else { throw HostingFailure(message: "Missing list boundary in \(source)") }
            let host = NSHostingView(rootView: MarkdownView(text: source)
                .environment(\.markdownProseRuns, false)
                .environment(\.markdownPointSize, 15)
                .environment(\.colorScheme, .light)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.white))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for width: CGFloat in [800, 400] {
                _ = continuous.height(forWidth: width)
                let nativeGap = baseline(continuous, at: separator + 1) - baseline(continuous, at: separator - 1)
                window.setContentSize(NSSize(width: width, height: 600))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
                let views = textViews(host).sorted {
                    let left = $0.convert(.zero, to: host).y, right = $1.convert(.zero, to: host).y
                    return host.isFlipped ? left < right : left > right
                }
                guard views.count == 2 else { throw HostingFailure(message: "Expected two selectable native list bodies for fixture \(index), found \(views.count)") }
                let previous = views[0].convert(NSPoint(x: 0, y: baseline(views[0], at: views[0].textStorage!.length - 1)), to: host).y
                let next = views[1].convert(NSPoint(x: 0, y: baseline(views[1], at: 0)), to: host).y
                let hostedGap = abs(next - previous)
                guard abs(nativeGap - 26) < 0.25, abs(hostedGap - nativeGap) < 0.25 else {
                    throw HostingFailure(message: "List item gaps differ at fixture \(index), width \(width): continuous=\(nativeGap), separate=\(hostedGap)")
                }
                if width == 400, index == 0 || index == 2 {
                    let rect = NSRect(x: 0, y: host.isFlipped ? 0 : 440, width: width, height: 160)
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) {
                        host.cacheDisplay(in: rect, to: bitmap)
                        let png = bitmap.representation(using: .png, properties: [:])
                        try png?.write(to: CaptureRun.outputDirectory!.appendingPathComponent("list-\(index)-narrow.png"))
                    }
                }
                comparisons += 1
            }
        }
        let fullSource = "复核 `80409a2a8`：**第 2、3 项已修复；第 1 项仍有一个已复现的落盘竞态。**\n\n使用生产 `RequestCaptureWriter`、`RequestCapture` 和本次构建模块，控制终态摘要晚于最终读取落盘，结果为：\n\n" + unordered[0] + "\n\n新增回归测试先写完终态摘要，再发送空闲通知，因此没有覆盖这个顺序。\n\n**已确认修好的两项：**\n" + unordered[1] + "\n\n验证：`make build`、`make verify AREAS=\"context-inspection\"` 均通过。"
        let fullText = ProseRunRepresentable.attributed(blocks: MarkdownParser.parse(fullSource), pointSize: 15, dimmed: false, mentions: [])
        let fullNative = LinkTextView()
        fullNative.render(fullText)
        let fullHost = NSHostingView(rootView: MarkdownView(text: fullSource)
            .environment(\.markdownProseRuns, false).environment(\.markdownPointSize, 15)
            .environment(\.colorScheme, .light)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(.white))
        fullHost.sizingOptions = []
        fullHost.appearance = NSAppearance(named: .aqua)
        let fullWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000), styleMask: .borderless, backing: .buffered, defer: false)
        fullWindow.isReleasedWhenClosed = false
        fullWindow.contentView = fullHost
        defer { fullWindow.close() }
        for width: CGFloat in [800, 400] {
            _ = fullNative.height(forWidth: width)
            fullWindow.setContentSize(NSSize(width: width, height: 1000))
            fullHost.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            fullHost.layoutSubtreeIfNeeded()
            let needles = ["最终读取后：", "writer 完成落盘后：", "历史占用与导出共用", "保留三态"]
            let items = try needles.map { needle -> LinkTextView in
                guard let view = textViews(fullHost).first(where: { $0.string.contains(needle) }) else {
                    throw HostingFailure(message: "Full reply lost list text: \(needle)")
                }
                return view
            }
            for (pair, needle) in [(0, "•\twriter 完成落盘后："), (2, "•\t采集证据")] {
                let second = (fullText.string as NSString).range(of: needle).location
                guard second != NSNotFound else { throw HostingFailure(message: "Full native reply lost list marker: \(needle)") }
                let nativeGap = baseline(fullNative, at: second) - baseline(fullNative, at: second - 2)
                let previous = items[pair].convert(NSPoint(x: 0, y: baseline(items[pair], at: items[pair].textStorage!.length - 1)), to: fullHost).y
                let next = items[pair + 1].convert(NSPoint(x: 0, y: baseline(items[pair + 1], at: 0)), to: fullHost).y
                guard abs(nativeGap - 26) < 0.25, abs(abs(next - previous) - nativeGap) < 0.25 else {
                    throw HostingFailure(message: "Full reply list gaps differ at width \(width): native=\(nativeGap), separate=\(abs(next - previous))")
                }
            }
            if let bitmap = fullHost.bitmapImageRepForCachingDisplay(in: fullHost.bounds) {
                fullHost.cacheDisplay(in: fullHost.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: CaptureRun.outputDirectory!.appendingPathComponent("full-lists-\(Int(width)).png"))
            }
        }
        // A final parent item must not receive the outer paragraph gap before its child.
        for source in ["- 父条目\n  - 子条目", "1. 父条目\n   1. 子条目"] {
            let text = ProseRunRepresentable.attributed(blocks: MarkdownParser.parse(source), pointSize: 15, dimmed: false, mentions: [])
            let view = LinkTextView()
            view.render(text)
            _ = view.height(forWidth: 400)
            let separator = (text.string as NSString).range(of: "\n").location
            let gap = baseline(view, at: separator + 1) - baseline(view, at: separator - 1)
            guard abs(gap - 26) < 0.25 else { throw HostingFailure(message: "Final parent/child list gap became an outer block gap: \(gap)") }
        }
        print("List spacing: \(comparisons) plain/bold/code/link ordered/unordered width comparisons and final parent/child gaps")
    }

    @MainActor private static func checkPlainProposals() throws {
        let source = (0..<48).map { index in
            "## Section \(index)\n\n长正文保留中文、Unicode 👩🏽‍💻 和 **emphasis**。Use `make build` to verify a long native paragraph.\n\n- First item with `inline code`.\n- Second item keeps its indentation and wraps across lines."
        }.joined(separator: "\n\n")
        let blocks = MarkdownParser.parse(source)
        let text = ProseRunRepresentable.attributed(blocks: blocks, pointSize: 15, dimmed: false, mentions: [])
        let view = LinkTextView()
        view.render(text)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: view.height(forWidth: 600))
        view.layoutSubtreeIfNeeded()
        view.setSelectedRange(NSRange(location: 8, length: 24))
        let frame = view.frame
        let container = view.textContainer!.containerSize
        let selected = view.selectedRanges
        let pending = view.needsLayout
        let revision = view.layoutRevision
        // TextKit fixes paragraph attributes during initial layout. Compare
        // proposals with the displayed storage, not the pre-layout input.
        let displayedText = NSAttributedString(attributedString: view.textStorage!)
        guard displayedText.string == text.string else {
            throw HostingFailure(message: "Initial native layout lost plain prose content")
        }
        let reference = LinkTextView()
        reference.render(text)
        for width: CGFloat in [260, 760, 400, 600, 260, 760, 400] {
            let height = view.measuredHeight(forWidth: width)
            guard height == reference.height(forWidth: width), height > 0 else {
                throw HostingFailure(message: "Plain prose proposals lost wrapped text at width \(width)")
            }
        }
        guard view.frame == frame, view.textContainer!.containerSize == container,
              view.selectedRanges == selected, view.needsLayout == pending,
              view.layoutRevision == revision, view.textStorage!.isEqual(to: displayedText) else {
            throw HostingFailure(message: "Plain prose proposals changed display: frame=\(view.frame != frame), container=\(view.textContainer!.containerSize != container), selection=\(view.selectedRanges != selected), layout=\(view.needsLayout != pending), revision=\(view.layoutRevision != revision), text=\(!view.textStorage!.isEqual(to: displayedText))")
        }
        for size: CGFloat in [19, 13] {
            let changed = ProseRunRepresentable.attributed(blocks: blocks, pointSize: size, dimmed: false, mentions: [])
            view.render(changed)
            reference.render(changed)
            guard view.measuredHeight(forWidth: 400) == reference.height(forWidth: 400) else {
                throw HostingFailure(message: "Plain prose reused a height after its font changed")
            }
        }
        let replacement = LinkParagraphView.attributed(source: "Short replacement with `code`.", pointSize: 15, dimmed: false)
        view.render(replacement)
        reference.render(replacement)
        guard view.measuredHeight(forWidth: 400) == reference.height(forWidth: 400),
              view.measuredHeight(forWidth: 0) == 0, view.measuredHeight(forWidth: .infinity) == 0 else {
            throw HostingFailure(message: "Plain prose measurement failed content invalidation or unbounded proposals")
        }
        let literal = "**用户原样标记** `make build`\n[保留链接文本](https://example.invalid)\n\n中文与 Emoji 👩🏽‍💻 保留。"
        let plain = LinkParagraphView.attributed(source: literal, pointSize: 15, literal: true, dimmed: false)
        guard plain.string == literal,
              MathRendering.exported(plain).string == literal else {
            throw HostingFailure(message: "Native literal user text changed Markdown markers or explicit newlines")
        }
        var semanticAttributes = false
        plain.enumerateAttributes(in: NSRange(location: 0, length: plain.length)) { attributes, _, _ in
            if attributes[.link] != nil || attributes[.attachment] != nil { semanticAttributes = true }
        }
        guard !semanticAttributes else { throw HostingFailure(message: "Literal user text became Markdown or clickable links") }
        view.render(plain)
        let natural = view.naturalSize()
        for width: CGFloat in [160, 400, 760, 160] {
            guard view.measuredHeight(forWidth: width) == view.height(forWidth: width),
                  view.naturalSize() == natural else {
                throw HostingFailure(message: "Literal user text lost wrapping or stable bubble sizing")
            }
        }
        print("Plain long prose: speculative widths preserve display, selection and content/font invalidation")
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        try await checkListSpacing()
        try checkPlainProposals()
        let output = CaptureRun.outputDirectory!
        let fixture = CommandLine.arguments.firstIndex(of: "--fixture")!
        ChatMathRenderer.shared.resourceRoot = URL(fileURLWithPath: CommandLine.arguments[fixture + 1])
        let probe = MathParagraphHost()
        probe.paragraph.render(LinkParagraphView.attributed(source: "Native text $x_i$ and a second $y_j$ formula.", pointSize: 15, dimmed: false))
        probe.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        _ = probe.measure(width: 400)
        probe.layoutSubtreeIfNeeded()
        let documentFrame = probe.paragraph.frame
        let containerSize = probe.paragraph.textContainer!.containerSize
        let wrappingWidth = probe.paragraph.wrappingWidth
        let scroller = probe.hasHorizontalScroller
        let pendingLayout = probe.needsLayout
        for width: CGFloat in [80, 1400, 260, 760] { _ = probe.measure(width: width) }
        guard probe.paragraph.frame == documentFrame, probe.paragraph.textContainer!.containerSize == containerSize,
              probe.paragraph.wrappingWidth == wrappingWidth, probe.hasHorizontalScroller == scroller,
              probe.needsLayout == pendingLayout else {
            throw HostingFailure(message: "SwiftUI width proposals mutated the displayed math text view")
        }
        let sources = [#"""
            ## Native math hosting

            - A native list paragraph with \(x_i\), \(y_j\), **中文：**正文。
            - A longer paragraph with \(\frac{1+x^2}{1+y^2}\) and repeated native text that wraps as the window changes width.
            - 列表手动换行保留缩进与原生选择。\
              第二行有 `inline code`，并在较窄的会话列里继续自动换行，保留完整文字。
              - [x] 嵌套任务列表同样保留换行、缩进和完整内容。

            > 引用中的第一行。\
            > 第二行包含 `inline code`，与普通正文使用相同的行间增量。

            > [!NOTE]
            > 提示块正文会在较窄的会话列里自然换行，并保留完整内容。

            ```swift
            let first = "代码首行"
            let second = "代码第二行"
            ```

            | Variable | Definition |
            | --- | --- |
            | \(x_i\) | A short native formula |
            | \(a_{ij}\) | A second native formula |

            \[
            \begin{aligned}x&=y+1\\z&=2x\end{aligned}
            \]
            """#]
        let content = VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in MarkdownView(text: source) }
            MarkdownView(text: "首段 $x_1$ 保持可选。\n\n第二段 $y_2$ 也属于连续正文。\n\n- 条目 $z_3$ 保留缩进。")
        }.frame(maxWidth: .infinity, alignment: .topLeading)
        let host = CountingHost(rootView: AnyView(content))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close(); ChatMathRenderer.shared.release() }
        for width: CGFloat in [760, 400, 760] {
            print("Hosting width \(width), sources \(sources.map(\.count)), before passes \(host.passes)")
            fflush(stdout)
            window.setContentSize(NSSize(width: width, height: 900))
            host.layoutSubtreeIfNeeded()
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
            print("Settled width \(width), passes \(host.passes), math pending \(MathRendering.isRendering)")
            fflush(stdout)
        }
        func textViews(_ view: NSView) -> [LinkTextView] {
            (view as? LinkTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        guard textViews(host).contains(where: { view in
            guard let storage = view.textStorage else { return false }
            let text = MathRendering.exported(storage).string
            return text.contains("首段 $x_1$") && text.contains("第二段 $y_2$") && text.contains("条目 $z_3$")
        }) else { throw HostingFailure(message: "Inline math broke continuous native selection across paragraphs and lists") }
        let denseSource = (0..<24).map { "可选正文 \($0)：$s_{\($0)}$ 保持行内排版。" }.joined(separator: "\n\n")
        let comparison = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        comparison.isReleasedWhenClosed = false
        defer { comparison.close() }
        var counts: [Int] = []
        for continuous in [false, true] {
            let column = NSHostingView(rootView: MarkdownView(text: denseSource).environment(\.markdownProseRuns, continuous))
            column.sizingOptions = []
            comparison.contentView = column
            column.layoutSubtreeIfNeeded()
            counts.append(textViews(column).count)
        }
        guard counts[1] > 0 && counts[1] * 4 <= counts[0] else {
            throw HostingFailure(message: "Dense inline math did not reduce its native view budget: \(counts)")
        }
        print("Dense inline math native text views: separate=\(counts[0]), continuous=\(counts[1])")
        try Data("passes=\(host.passes)\n".utf8).write(to: output.appendingPathComponent("layout.txt"))
    }
}
