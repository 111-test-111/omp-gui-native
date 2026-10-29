import Foundation
import CryptoKit

/// Read-only display recovery for an explicitly selected OMP worker. No runtime is
/// launched, and only this edition's native journal directory is readable.
enum OMPAgentJournal {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumEntries = 50_000

    static func prefix(for file: String) -> String {
        stableID("session:" + URL(fileURLWithPath: file).standardizedFileURL.path).uuidString
    }

    static func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func toolID(_ id: String) -> String {
        guard id.count > 37, UUID(uuidString: String(id.prefix(36))) != nil,
              id.dropFirst(36).first == "-" else { return id }
        return String(id.dropFirst(37))
    }

    static func date(_ entry: JSONValue) -> Date? {
        if let text = entry["timestamp"]?.string {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
        }
        if let number = entry["message"]?["timestamp"]?.double, number.isFinite, number > 0 {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        return nil
    }

    static func read(_ file: String) throws -> [JSONValue] {
        try readIfChanged(file, since: nil)!.entries
    }

    struct Snapshot: Sendable {
        let entries: [JSONValue]
        let fingerprint: String
        let hasCompleteLines: Bool
    }

    /// A reported response size, not a tokenizer or a cumulative spending total.
    /// OMP's live progress exposes the same per-response `contextTokens` value.
    struct ContextReport: Sendable {
        var usage: ContextUsage?
        var model: String?
        var windowTokens: Int?

        static func progressUsage(_ progress: JSONValue) -> ContextUsage? {
            guard let tokens = count(progress["contextTokens"]) else { return nil }
            let window = count(progress["contextWindow"]).flatMap { $0 > 0 ? $0 : nil }
            return ContextUsage(usedTokens: tokens, windowTokens: window)
        }

        mutating func observe(_ entry: JSONValue) {
            switch entry["type"]?.string {
            case "model_change" where entry["role"]?.string == nil || entry["role"]?.string == "default":
                if let next = entry["model"]?.string, next != model {
                    model = next
                    usage = nil
                    windowTokens = nil
                }
            case "compaction":
                // Pre-compaction response counts no longer describe this context.
                usage = nil
            case "message":
                guard let message = entry["message"], message["role"]?.string == "assistant",
                      let count = Self.tokens(message["usage"]), count > 0 else { return }
                let identity = [message["provider"]?.string, message["model"]?.string].compactMap { $0 }.joined(separator: "/").nilIfEmpty
                let window = identity == nil || identity == model ? windowTokens : nil
                model = identity ?? model
                windowTokens = window
                usage = ContextUsage(usedTokens: count, windowTokens: window)
            default: break
            }
        }

        private static func tokens(_ value: JSONValue?) -> Int? {
            if let total = value?["totalTokens"] { return count(total) }
            var total = 0
            for key in ["input", "output", "cacheRead", "cacheWrite"] {
                guard let amount = count(value?[key]) else { return nil }
                let sum = total.addingReportingOverflow(amount)
                guard !sum.overflow else { return nil }
                total = sum.partialValue
            }
            return total
        }

        private static func count(_ value: JSONValue?) -> Int? {
            let number: Int?
            switch value {
            case .int(let value): number = value
            case .double(let value): number = value.isFinite ? Int(exactly: value) : nil
            default: number = nil
            }
            return number.flatMap { $0 >= 0 ? $0 : nil }
        }
    }

    static func contextReport(_ entries: [JSONValue]) throws -> ContextReport {
        let rows = entries.filter { $0["parentId"] != nil }
        let index = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row["id"]?.string.map { ($0, row) } })
        // Late background entries can explicitly preserve a different active leaf.
        let last = rows.last
        var next = (last?["activeLeafId"] ?? last?["id"])?.string
        var seen = Set<String>()
        var path: [JSONValue] = []
        while let id = next {
            try Task.checkCancellation()
            guard seen.insert(id).inserted, let entry = index[id] else { throw ReadError.invalidJournal }
            path.append(entry)
            next = entry["parentId"]?.string
        }
        var report = ContextReport()
        for entry in path.reversed() { report.observe(entry) }
        return report
    }

    /// Hash only complete lines. An unchanged journal needs no decode or display
    /// replay; a partially appended last line is still left for the next read.
    static func readIfChanged(_ file: String, since fingerprint: String?) throws -> Snapshot? {
        let root = StoragePaths.directory("omp/sessions").resolvingSymlinksInPath().path + "/"
        let url = URL(fileURLWithPath: file).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root), url.pathExtension == "jsonl" else { throw ReadError.outsideStore }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(maximumBytes) else { throw ReadError.tooLarge }
        try handle.seek(toOffset: 0)
        // Bound the read even if a live journal grows after the size check.
        let data = try handle.read(upToCount: Int(size)) ?? Data()
        // A writer can have an incomplete final line. Leave it for the next read.
        let complete = data.lastIndex(of: 0x0A).map { data[...$0] } ?? data.prefix(0)
        let digest = SHA256.hash(data: complete).map { String(format: "%02x", $0) }.joined()
        guard digest != fingerprint else { return nil }
        var entries: [JSONValue] = []
        var seen = Set<String>()
        for line in complete.split(separator: 0x0A) {
            try Task.checkCancellation()
            guard let value = JSONValue.parse(Data(line)) else { throw ReadError.invalidJournal }
            guard let id = value["id"]?.string else { continue } // title/header preamble
            guard seen.insert(id).inserted else { throw ReadError.invalidJournal }
            entries.append(value)
            guard entries.count <= maximumEntries else { throw ReadError.tooLarge }
        }
        return Snapshot(entries: entries, fingerprint: digest, hasCompleteLines: !complete.isEmpty)
    }

    enum ReadError: LocalizedError {
        case outsideStore, tooLarge, invalidJournal
        var errorDescription: String? {
            switch self {
            case .outsideStore: AppText.localized("This worker journal is outside this OMP GUI library.")
            case .tooLarge: AppText.localized("This worker journal exceeds the history display limit.")
            case .invalidJournal: AppText.localized("OMP GUI could not read this worker journal. Its original contents are preserved.")
            }
        }
    }
}
