import AppKit
@testable import OMPGUI

/// Production cache/queue/renderer, without launching the GUI or OMP. Each round
/// recreates the WebView and uses distinct expressions; no warm cache hits.
@main private enum ChatMathColdChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let output = CaptureRun.outputDirectory!
        let fixture = CommandLine.arguments.firstIndex(of: "--fixture")!
        ChatMathRenderer.shared.resourceRoot = URL(fileURLWithPath: CommandLine.arguments[fixture + 1])
        var samples: [[String: Any]] = []
        for round in 0..<3 {
            ChatMathRenderer.shared.release()
            let formulas = (0..<96).map { i in
                let latex = #"\frac{a_{"# + "\(round),\(i)" + #"}+b^2}{\sqrt{1+x^2}}=y"#
                return MarkdownFormula(source: "$\(latex)$", latex: latex, mode: .inline, complete: true)
            }
            let batches = ChatMathRenderer.shared.batchCount
            let start = ProcessInfo.processInfo.systemUptime
            for formula in formulas { _ = MathRendering.result(for: formula, pointSize: 15) }
            var ready = [Double?](repeating: nil, count: formulas.count)
            while MathRendering.isRendering {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - start < 30 else { fatalError("Cold formula queue timed out") }
                for i in formulas.indices where ready[i] == nil {
                    switch MathRendering.result(for: formulas[i], pointSize: 15) {
                    case .ready: ready[i] = (now - start) * 1000
                    case .failure(let reason): fatalError("Formula failed: \(reason)")
                    case .pending: break
                    }
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            let total = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let times = ready.map { $0 ?? total }.sorted()
            samples.append(["round": round, "first_ready_ms": times.first!,
                            "all_96_ready_ms": total, "p95_ready_ms": times[90],
                            "snapshots": ChatMathRenderer.shared.batchCount - batches])
        }
        // A main-actor stream paced by 16 ms sleeps into a cold renderer. This
        // is readiness, not an independent input clock or live GUI acceptance.
        ChatMathRenderer.shared.release()
        let start = ProcessInfo.processInfo.systemUptime
        let tail = (0..<24).map { i -> MarkdownFormula in
            let latex = #"\sum_{j=0}^{"# + "\(i)" + #"}j^2"#
            return MarkdownFormula(source: "$\(latex)$", latex: latex, mode: .inline, complete: true)
        }
        for formula in tail {
            _ = MathRendering.result(for: formula, pointSize: 15)
            try await Task.sleep(for: .milliseconds(16))
        }
        while MathRendering.isRendering { try await Task.sleep(for: .milliseconds(2)) }
        let data: [String: Any] = ["samples": samples, "stream_24_total_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
            "method": "3 recreated WebViews, 96 distinct formulas each, production queue, 15 pt / 2x; offscreen readiness, no GUI/OMP"]
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("cold.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), encoding: .utf8)!)
        ChatMathRenderer.shared.release()
    }
}
