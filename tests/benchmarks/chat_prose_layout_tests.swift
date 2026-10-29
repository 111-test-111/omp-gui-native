import AppKit
import Foundation
@testable import OMPGUI

/// An offscreen TextKit comparison, not an application scrolling/frame-rate test.
@main private enum ChatProseLayoutBenchmark {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let source = (0..<96).map { index in
            "## Section \(index)\n\nThis is a long native reply containing **formatted text**, 中文段落和 Unicode 👩🏽‍💻. Repeated width proposals must preserve `inline code` and native selection.\n\n- First item keeps its text and indentation.\n- Second item contains enough words to wrap at narrow widths."
        }.joined(separator: "\n\n")
        let text = ProseRunRepresentable.attributed(blocks: MarkdownParser.parse(source), pointSize: 15, dimmed: false, mentions: [])
        let baseline = LinkTextView(), candidate = LinkTextView()
        baseline.render(text); candidate.render(text)
        let widths: [CGFloat] = [400, 760, 520, 760]
        var expected: [CGFloat: CGFloat] = [:]
        for width in widths {
            expected[width] = baseline.height(forWidth: width)
            guard candidate.measuredHeight(forWidth: width) == expected[width] else {
                fatalError("Candidate lost text at width \(width)")
            }
        }
        let cycles = 12
        func elapsed(_ measure: (CGFloat) -> CGFloat) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<cycles {
                for width in widths {
                    precondition(measure(width) == expected[width])
                }
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        var baselineMS: [Double] = [], candidateMS: [Double] = []
        for _ in 0..<3 {
            baselineMS.append(elapsed { baseline.height(forWidth: $0) })
            candidateMS.append(elapsed { candidate.measuredHeight(forWidth: $0) })
        }
        let result: [String: Any] = [
            "scope": "offscreen warmed TextKit width proposals; excludes parsing, attributed construction, drawing and GUI scrolling",
            "baseline": "previous single-width cache on displayed text container",
            "candidate": "isolated measurement with bounded width cache",
            "source_utf8_bytes": source.utf8.count, "native_utf16_length": text.length,
            "widths": widths, "proposals_per_sample": cycles * widths.count,
            "baseline_ms": baselineMS, "candidate_ms": candidateMS,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        let output = CaptureRun.outputDirectory!
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("prose-layout.json"))
        print("Long prose, \(source.utf8.count) UTF-8 bytes, \(cycles * widths.count) proposals/sample")
        print("Previous displayed-container layout (ms): \(baselineMS)")
        print("Isolated cached measurement (ms): \(candidateMS)")
    }
}
