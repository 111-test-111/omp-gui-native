import CoreGraphics
import Foundation
import ImageIO

/// Production-helper and offscreen native text checks. No application window is
/// created or displayed, the GUI is not launched, and no media is played.
@main struct PreviewRendererChecks {
    @MainActor static func main() async throws {
        checkSourceLocations()
        checkSyntaxBounds()
        checkMarkdownFallbacks()
        try checkReadingState()
        await checkPDFCallbackBudget()
        try await checkImageRefresh()
        try await PreviewTextLayoutChecks.run()
        try await PreviewAnimationChecks.run()
        try await PreviewOpeningChecks.run()
        try await PreviewFloatingControlsChecks.run()
        print("Preview renderer checks passed: Unicode locations, syntax bounds, Markdown size fallback, state persistence, PDF callback budget, image refresh, native source pixels, chrome clipping and viewport resizing")
    }

    private static func checkSourceLocations() {
        let source = "a\r\n😺e\u{301}\rb\n"
        let starts = PreviewSourcePositions.lineStarts(in: source)
        precondition(starts == [0, 3, 8, 10], "CRLF must count as one logical newline")
        func offset(_ line: Int, _ column: Int) -> Int {
            PreviewSourcePositions.offset(in: source, lineStarts: starts, location: FilePreviewLocation(line: line, column: column))
        }
        precondition(offset(2, 1) == 3)
        precondition(offset(2, 2) == 5, "A Unicode column must not split an emoji's surrogate pair")
        precondition(offset(2, 3) == 7, "A Unicode column must not split a composed character")
        precondition(offset(2, 99) == 7, "A column past the line must clamp before its newline")
        precondition(offset(99, 1) == 10)
        precondition(offset(Int.min, Int.min) == 0)
        precondition(PreviewSourcePositions.lineStarts(in: "\r\n\n\r") == [0, 2, 3, 4])
        precondition(PreviewSourcePositions.lineStarts(in: "") == [0])
        // Compare the optimized native UTF-8 scan with the prior UTF-16
        // definition, including bridged Foundation strings and every newline
        // adjacency around BMP/supplementary/combining characters.
        func referenceStarts(_ source: String) -> [Int] {
            var starts = [0]
            var previousCR = false
            for (offset, unit) in source.utf16.enumerated() {
                if unit == 10 {
                    if previousCR { starts[starts.count - 1] = offset + 1 }
                    else { starts.append(offset + 1) }
                } else if unit == 13 { starts.append(offset + 1) }
                previousCR = unit == 13
            }
            return starts
        }
        let pieces = ["", "a", "é", "你", "😺", "e\u{301}", "👩🏽‍💻", "\r", "\n", "\r\n", "\n\r"]
        for first in pieces {
            for second in pieces {
                for third in pieces {
                    let value = first + second + third
                    let bridged = (NSString(string: value) as String)
                    let expected = referenceStarts(value)
                    precondition(PreviewSourcePositions.lineStarts(in: value) == expected)
                    precondition(PreviewSourcePositions.lineStarts(in: bridged) == expected)
                }
            }
        }
    }

    private static func checkSyntaxBounds() {
        let source = "// let ignored = 7\nlet value = \"return 3\"\nclass Thing {}\n"
        let ns = source as NSString
        let spans = PreviewSyntaxHighlighter.spans(in: source, extension: "swift")
        precondition(spans.contains { ns.substring(with: $0.range) == "let" })
        precondition(!spans.contains { if case .keyword = $0.token { return $0.range.location < ns.range(of: "\n").location }; return false })
        precondition(spans.contains { if case .string = $0.token { return ns.substring(with: $0.range) == "\"return 3\"" }; return false })
        let large = String(repeating: "let value = 123\n", count: 80_000)
        let bounded = PreviewSyntaxHighlighter.spans(in: large, extension: "swift")
        precondition(bounded.count <= PreviewSyntaxHighlighter.maximumSpans)
        precondition(bounded.allSatisfy { NSMaxRange($0.range) <= PreviewSyntaxHighlighter.maximumUTF16Length })
        precondition(PreviewSyntaxHighlighter.spans(in: large, extension: "unknown").isEmpty)
    }

    private static func checkMarkdownFallbacks() {
        let markdown = "# Heading\n\nSee [guide][g] and $x^2$.\n\n[g]: ./guide.md\n\n```text\n[not-a-reference]: literal\n```\n"
        precondition(!PreviewMarkdownDocument.requiresSource(markdown))
        precondition(!PreviewMarkdownDocument.requiresSource(String(repeating: "|x", count: 100)))
        precondition(!PreviewMarkdownDocument.requiresSource(String(repeating: "x\n", count: 4_100)))
        precondition(PreviewMarkdownDocument.requiresSource(String(repeating: "x\n", count: 20_001)))
        precondition(PreviewMarkdownDocument.requiresSource(String(repeating: "x", count: 2_100_000)))
    }

    @MainActor private static func checkReadingState() throws {
        var snapshot = PreviewReaderState.Snapshot()
        snapshot.source.y = 920
        snapshot.document.selectionLocation = 7
        snapshot.pdfPage = 3
        snapshot.pdfX = 42
        snapshot.pdfY = 200
        snapshot.imageScale = 1.25
        snapshot.mediaTime = 12
        let decoded = try JSONDecoder().decode(PreviewReaderState.Snapshot.self, from: JSONEncoder().encode(snapshot))
        precondition(PreviewReaderState(snapshot: decoded).snapshot == snapshot)
        let state = PreviewReaderState()
        state.imageCurrentScale = 0.2
        state.stepImageZoom(1)
        precondition(abs(state.imageScale - 0.25) < 0.00001, "Zoom after fit uses the actual displayed scale")
        state.imageCurrentScale = 16
        state.stepImageZoom(1)
        precondition(state.imageScale == 16)
        state.resetImageZoom()
        precondition(state.imageScale == 0)
    }

    private static func checkPDFCallbackBudget() async {
        let budget = PreviewPDFFindBudget()
        let accepted = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var accepted = 0
                    for _ in 0..<1_000 { if budget.take() != nil { accepted += 1 } }
                    return accepted
                }
            }
            var accepted = 0
            for await count in group { accepted += count }
            return accepted
        }
        precondition(accepted == PreviewPDFFindBudget.limit, "PDF callbacks must be bounded before queueing main-actor work")
        precondition(budget.take() == nil)
    }

    private static func checkImageRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("same-name.png")
        func write(red: CGFloat, blue: CGFloat) {
            let context = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        write(red: 1, blue: 0)
        let first = await PreviewImageDecoder.load(url: url, maximumDimension: 128)!
        precondition(first.image.width <= 128 && first.image.height <= 128)
        precondition(first.originalSize == CGSize(width: 640, height: 320))
        write(red: 0, blue: 1)
        let second = await PreviewImageDecoder.load(url: url, maximumDimension: 128)!
        precondition(first.image.dataProvider!.data! as Data != second.image.dataProvider!.data! as Data,
                     "Replacing an image at the same path must replace the decoded pixels")
    }
}
