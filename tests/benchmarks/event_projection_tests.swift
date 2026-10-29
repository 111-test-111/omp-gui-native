import Foundation
import CryptoKit
@testable import OMPGUI

@main
struct EventProjectionMeasurement {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.contains("/build.noindex/verification/runs/"),
              root.path.hasSuffix("/benchmark/event-projection") else { fatalError("Require isolated benchmark output") }
        let corpus = EventProjectionFixture.corpus(chunks: 64, repetitions: 128)
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        }
        func measure(_ frames: [Data]) -> ([String: Any], [JSONValue]) {
            let decoder = OMPEventDecoder(prefix: "projection", directory: root.path, capturesSnapshots: false)
            var events: [JSONValue] = []
            decoder.onEvent = { events.append(EventProjectionFixture.observed($0)) }
            var parse = 0.0, decode = 0.0
            var digest = SHA256()
            for data in frames { digest.update(data: data) }
            for data in frames {
                autoreleasepool {
                    let start = ContinuousClock.now
                    guard let frame = JSONValue.parse(data) else { fatalError("Invalid fixture") }
                    parse += milliseconds(start)
                    let decoded = ContinuousClock.now
                    decoder.handle(frame)
                    decode += milliseconds(decoded)
                }
            }
            return (["frames": frames.count, "ndjson_bytes": frames.reduce(0) { $0 + $1.count + 1 },
                     "json_parse_ms": parse, "decoder_and_event_collection_ms": decode,
                     "payload_sha256": digest.finalize().map { String(format: "%02x", $0) }.joined()], events)
        }
        let (full, fullEvents) = measure(corpus.full)
        let (delta, deltaEvents) = measure(corpus.delta)
        guard fullEvents == deltaEvents, !fullEvents.isEmpty else { fatalError("Projection changes normalized output") }
        let fullBytes = full["ndjson_bytes"] as! Int, deltaBytes = delta["ndjson_bytes"] as! Int
        guard deltaBytes < fullBytes else { fatalError("Delta fixture did not omit accumulated snapshots") }
        let result: [String: Any] = [
            "scope": "One synthetic full/delta comparison through production JSONValue.parse and OMPEventDecoder; encoded frames are prepared before timings. No native OMP, GUI, stdio, allocations or screen latency is measured.",
            "workload": ["chunks_per_text_and_tool_argument": 64, "text_utf8_bytes": corpus.text.utf8.count,
                         "tool_arguments_utf8_bytes": corpus.arguments["payload"]!.string!.utf8.count,
                         "normalized_event_count": fullEvents.count],
            "full": full, "delta": delta,
            "ndjson_bytes_saved": fullBytes - deltaBytes,
            "ndjson_reduction_percent": 100 * Double(fullBytes - deltaBytes) / Double(fullBytes),
            "timing_note": "Single ordered observations, full then delta; not statistical latency or a machine-independent threshold. Decoder time includes identical event collection. JSON serialization and workload generation are excluded."
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("comparison.json"))
        print("Full/delta comparison: \(fullBytes) / \(deltaBytes) NDJSON bytes; identical \(fullEvents.count) normalized events")
    }
}
