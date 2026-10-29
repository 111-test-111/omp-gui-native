import Foundation

/// GUI opt-in and native Mnemopi options. Memory contents remain owned by OMP.
struct OMPMemoryConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var autoRecall = true
    var autoRetain = true
    var multilingual = true
    var tokenBudget = 3000

    var json: JSONValue {
        ["enabled": .bool(enabled), "autoRecall": .bool(autoRecall), "autoRetain": .bool(autoRetain),
         "multilingual": .bool(multilingual), "tokenBudget": .int(tokenBudget)]
    }
}

struct OMPMemoryInspection: Sendable {
    var scope: String
    var files: [OMPMemoryFile]

    init(_ value: JSONValue) {
        scope = value["scope"]?.string ?? ""
        var seen = Set<String>()
        files = (value["files"]?.array ?? []).prefix(16).compactMap(OMPMemoryFile.init)
            .filter { seen.insert($0.id).inserted }
    }
}

struct OMPMemoryFile: Identifiable, Equatable, Sendable {
    var bank: String
    var path: String
    var isGlobal: Bool
    var id: String { bank + "\n" + path }
    var title: String { isGlobal ? "Global shared memory" : "Project memory" }

    init?(_ value: JSONValue) {
        guard let bank = value["bank"]?.string, !bank.isEmpty,
              let path = value["path"]?.string, path.hasPrefix("/"),
              let scope = value["scope"]?.string, ["project", "global"].contains(scope) else { return nil }
        self.bank = bank
        self.path = path
        isGlobal = scope == "global"
    }
}

struct OMPMemoryPreview: Sendable {
    var text: String
    var isEmpty: Bool
    var limited: Bool

    init(_ value: JSONValue) {
        let items = Array((value["items"]?.array ?? []).prefix(50))
        isEmpty = items.isEmpty
        limited = value["limited"]?.bool == true
        text = items.enumerated().map { index, item in
            let metadata = [item["timestamp"]?.string, item["source"]?.string]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let content = item["content"]?.string ?? ""
            return "[\(index + 1)] \(metadata)\n\n\(content)" + (item["truncated"]?.bool == true ? "\n…" : "")
        }.joined(separator: "\n\n────────────────────────\n\n")
    }
}
