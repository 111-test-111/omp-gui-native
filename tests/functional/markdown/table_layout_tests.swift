import AppKit
import SwiftUI
@testable import OMPGUI

private struct TableLayoutFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum MarkdownTableLayoutChecks {
    @MainActor private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TableLayoutFailure(description: message) }
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func checkNativeMeasurement() throws {
        let cell = LinkTextView()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        cell.render(InlineCodeStyle.attributed("write", font: font))
        _ = cell.height(forWidth: 160)
        let container = cell.textContainer!
        let displayedWidth = container.containerSize.width
        let short = cell.naturalSize()
        try expect(short.width > 20 && short.width < 100, "A short code cell inherited the natural-width probe")
        try expect(container.containerSize.width == displayedWidth, "Natural measurement changed the displayed text container")
        try expect(cell.naturalSize() == short, "Repeated intrinsic measurement changed the cell width")
        cell.render(InlineCodeStyle.attributed(String(repeating: "long_code_", count: 10), font: font))
        try expect(cell.naturalSize().width > 500, "A content change reused the short cell's intrinsic size")
        cell.render(InlineCodeStyle.attributed("write", font: font))
        try expect(cell.naturalSize() == short, "A short cell retained a previous long content width")
        _ = cell.height(forWidth: 160)
        container.containerSize.width = 80
        _ = cell.height(forWidth: 160)
        try expect(container.containerSize.width == 160, "A cached height failed to restore the requested layout width")
    }

    @MainActor private static func checkTable(_ source: String, name: String, maximumContentWidth: CGFloat,
                                             genuinelyWide: Bool = false, singleRow: Bool = false, output: URL) async throws {
        guard case .table(let header, let rows, let alignments) = MarkdownParser.parse(source).first else {
            throw TableLayoutFailure(description: "The \(name) fixture did not parse as a table")
        }
        let content = TableBlock(header: header, rows: rows, alignments: alignments)
            .font(.chat(.body))
            .environment(\.colorScheme, .dark)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.12, green: 0.12, blue: 0.12))
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.backgroundColor = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        window.contentView = host
        defer { window.close() }
        var widths: [CGFloat: CGFloat] = [:]
        for width: CGFloat in [960, 320, 640, 320, 960] {
            window.setContentSize(NSSize(width: width, height: 500))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
                  let document = scroll.documentView else {
                throw TableLayoutFailure(description: "The \(name) table did not mount its horizontal scroll view")
            }
            let viewport = scroll.contentView.bounds.width
            let documentWidth = document.frame.width
            FileHandle.standardOutput.write(Data("\(name): viewport=\(viewport), document=\(documentWidth)\n".utf8))
            try expect(documentWidth <= max(viewport, maximumContentWidth) + 1,
                       "The \(name) table has phantom horizontal overflow: \(documentWidth) at viewport \(viewport)")
            if viewport >= maximumContentWidth {
                try expect(documentWidth <= viewport + 1, "The \(name) table scrolls despite fitting in its viewport")
            }
            if let previous = widths[width] {
                try expect(abs(previous - documentWidth) <= 1, "A sidebar width round trip changed the \(name) table's natural width")
            }
            widths[width] = documentWidth
            if singleRow {
                try expect(document.frame.height < 100, "The \(name) table wrapped its long cell into many lines")
            }
            let cells = descendants(host).compactMap { $0 as? LinkTextView }
            try expect(!cells.isEmpty, "The \(name) fixture did not exercise native code/link cells")
            try expect(cells.allSatisfy { $0.frame.width <= maximumContentWidth }, "A \(name) cell inherited the measurement probe width")
            for cell in cells {
                guard let layout = cell.layoutManager, let container = cell.textContainer else { continue }
                layout.ensureLayout(for: container)
                var lines = 0
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
                try expect(lines <= 1, "The \(name) table compressed \(cell.string.debugDescription) into \(lines) lines at viewport \(viewport)")
            }
            if genuinelyWide && width == 320 {
                try expect(documentWidth > viewport + 100, "A genuine wide table lost horizontal scrolling")
                let clip = scroll.contentView
                let end = clip.constrainBoundsRect(NSRect(x: documentWidth, y: clip.bounds.minY,
                                                         width: clip.bounds.width, height: clip.bounds.height))
                clip.scroll(to: end.origin)
                scroll.reflectScrolledClipView(clip)
                try expect(clip.bounds.minX > 100 && clip.bounds.maxX <= documentWidth + 1,
                           "The \(name) scroll range cannot reach its real right edge")
                let last = cells.first { $0.string == "end-column" }!
                let lastFrame = document.convert(last.bounds, from: last)
                try expect(lastFrame.intersects(clip.bounds), "The wide table's final column is unreachable")
            }
            if width == 960 || (genuinelyWide && width == 320),
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(name)-\(Int(width))-dark.png"))
            }
        }
    }

    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try checkNativeMeasurement()
        let source = """
        | 调用 | 目标 | 结果 |
        |---|---|---|
        | `write` | 工作区内 `sample-write.txt` | 成功 |
        | `edit` | 工作区内 `sample-check.md` | 成功 |
        | `edit` | 同上，第二次 | **被拒** |
        | `write` | 工作区外 `/tmp/...` | 被拒 |
        | `bash` | `touch`（越界但无害） | 被拒 |
        | `bash` | `rm -f`（破坏性） | 被拒 |
        | `eval` | `Bun.$` 执行 shell | 被拒 |
        | `task` | 子代理内跑 shell | 被拒 |
        | `read` | 工作区目录/文件 | 放行（无弹窗） |
        """
        guard case .table(let header, let rows, _) = MarkdownParser.parse(source).first else {
            throw TableLayoutFailure(description: "The source fixture did not parse as a table")
        }
        try expect(header.count == 3 && rows.count == 9, "The regression fixture lost its other columns")
        try await checkTable(source, name: "three-columns", maximumContentWidth: 900, output: output)
        try await checkTable("| 调用 |\n|---|\n| `write` |\n| `edit` |\n| `bash` |", name: "one-column", maximumContentWidth: 160, output: output)
        let longCode = String(repeating: "long_code_", count: 8)
        try await checkTable("| 路径 | 结果 |\n|:---|---:|\n| `\(longCode)` | `end-column` |", name: "wide-code", maximumContentWidth: 900, genuinelyWide: true, singleRow: true, output: output)
        let longProse = String(repeating: "Long ordinary table text ", count: 10)
        try await checkTable("| 说明 | 结果 |\n|---|---|\n| \(longProse) | `end-column` |", name: "wide-prose", maximumContentWidth: 2600, genuinelyWide: true, singleRow: true, output: output)
        try await checkTable("| 链接 | 调用 |\n|:---:|---:|\n| [local file](/tmp/sample.txt) | `read` |", name: "local-link", maximumContentWidth: 260, output: output)
        try await checkTable("| 数值 | 调用 |\n|---|---|\n| 值 $x+1$ | `read` |", name: "inline-math", maximumContentWidth: 260, output: output)
        print("Markdown table width checks passed: six real table fixtures, 30 width changes, uncompressed text/code cells, native measurement/cache isolation and reachable wide-table columns. Offscreen previews: \(output.path)")
    }
}
