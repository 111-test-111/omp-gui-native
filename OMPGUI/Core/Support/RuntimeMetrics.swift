import Foundation
import os
import Synchronization

/// Opt-in, bounded timings. No prompts, file paths, credentials or timer-driven
/// sampling. A headless checker can read the same counters as a Dev session.
enum RuntimeMetrics {
    enum Operation: String, CaseIterable, Sendable {
        case rpcRequest, rpcReassembly, sessionStartup, processShutdown
        case historyRead, previewOpen, streamFlush, chatSwitch
    }
    struct Summary: Codable, Sendable {
        var count: Int
        var retained: Int
        var p50Milliseconds: Double
        var p95Milliseconds: Double
        var maximumMilliseconds: Double
    }
    struct Span: Sendable {
        fileprivate let operation: Operation
        fileprivate let start: ContinuousClock.Instant
        fileprivate let id: OSSignpostID
    }
    private struct Samples {
        var count = 0
        var values: [Double] = []
        var next = 0
        var maximum = 0.0
    }
    static let enabled = ProcessInfo.processInfo.environment["OMP_GUI_PERFORMANCE"] == "1"
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "dev.ompgui.mac", category: .pointsOfInterest)
    private static let samples = Mutex<[Operation: Samples]>([:])
    static let sampleLimit = 256

    static func begin(_ operation: Operation) -> Span? {
        guard enabled else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "OMP GUI operation", signpostID: id, "%{public}s", operation.rawValue)
        return Span(operation: operation, start: .now, id: id)
    }

    static func end(_ span: Span?) {
        guard let span else { return }
        os_signpost(.end, log: log, name: "OMP GUI operation", signpostID: span.id)
        let duration = span.start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
        samples.withLock { values in
            var sample = values[span.operation] ?? Samples()
            sample.count += 1
            sample.maximum = max(sample.maximum, milliseconds)
            if sample.values.count < sampleLimit { sample.values.append(milliseconds) }
            else { sample.values[sample.next] = milliseconds }
            sample.next = (sample.next + 1) % sampleLimit
            values[span.operation] = sample
        }
    }

    static func snapshot() -> [String: Summary] {
        samples.withLock { values in
            Dictionary(uniqueKeysWithValues: values.map { key, sample in
                let sorted = sample.values.sorted()
                func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
                return (key.rawValue, Summary(count: sample.count, retained: sorted.count,
                    p50Milliseconds: percentile(0.5), p95Milliseconds: percentile(0.95), maximumMilliseconds: sample.maximum))
            })
        }
    }
}
