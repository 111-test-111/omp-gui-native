import Foundation

enum OMPInspectionNumber {
    static func count(_ value: JSONValue?) -> Int? {
        let result: Int?
        switch value {
        case .int(let number): result = number
        case .double(let number): result = number.isFinite ? Int(exactly: number) : nil
        default: result = nil
        }
        return result.flatMap { $0 >= 0 ? $0 : nil }
    }

    static func sum(_ values: [Int?]) -> Int? {
        var total = 0
        for value in values {
            guard let value else { return nil }
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }
}

struct OMPContextCategory: Equatable, Sendable, Identifiable {
    struct Item: Equatable, Sendable, Identifiable {
        let name: String
        let tokens: Int
        var id: String { name }
    }
    let kind: String
    let tokens: Int
    var items: [Item] = []
    var omittedItems = 0
    var id: String { kind }

    var title: String {
        switch kind {
        case "system": "System prompt"
        case "projectContext": "System context"
        case "skills": "Skill descriptions"
        case "toolSchemas": "Tool declarations"
        case "messages": "Messages"
        case "userText": "User text"
        case "assistantText": "Assistant text"
        case "thinking": "Visible reasoning"
        case "toolCalls": "Tool-call arguments"
        case "toolResults": "Tool results"
        case "images": "Images"
        case "summaries": "Compaction and branch summaries"
        case "extensions": "Extension content"
        case "shell": "Shell and Python output"
        case "requestOnly": "Added or edited request content"
        default: "Framing and other content"
        }
    }
}

struct OMPContextComposition: Equatable, Sendable {
    let total: Int
    let categories: [OMPContextCategory]
    let limited: Bool

    init?(_ value: JSONValue?) {
        guard let total = OMPInspectionNumber.count(value?["total"]),
              let rows = value?["categories"]?.array, rows.count <= 24,
              let limited = value?["limited"]?.bool else { return nil }
        var categories: [OMPContextCategory] = []
        for row in rows {
            guard let kind = row["kind"]?.string, !kind.isEmpty, kind.utf8.count <= 128,
                  let tokens = OMPInspectionNumber.count(row["tokens"]),
                  let items = row["items"]?.array, items.count <= 8,
                  let omitted = OMPInspectionNumber.count(row["omittedItems"]) else { return nil }
            var names: [OMPContextCategory.Item] = []
            for item in items {
                guard let name = item["name"]?.string, name.count <= 160,
                      let amount = OMPInspectionNumber.count(item["tokens"]) else { return nil }
                names.append(.init(name: name, tokens: amount))
            }
            guard Set(names.map(\.name)).count == names.count,
                  let itemTotal = OMPInspectionNumber.sum(names.map { $0.tokens }), itemTotal <= tokens else { return nil }
            categories.append(.init(kind: kind, tokens: tokens, items: names, omittedItems: omitted))
        }
        guard Set(categories.map(\.kind)).count == categories.count,
              OMPInspectionNumber.sum(categories.map { $0.tokens }) == total else { return nil }
        self.total = total; self.categories = categories; self.limited = limited
    }
}

struct OMPContextLiveInspection: Equatable, Sendable {
    let file: String
    let sessionID: String
    let model: String?
    let provider: String?
    let timestamp: Date
    let usedTokens: Int
    let windowTokens: Int?
    let anchored: Bool
    let categories: [OMPContextCategory]
    let composition: OMPContextComposition?

    init?(_ value: JSONValue) {
        guard value["protocolVersion"]?.int == 1,
              let file = value["sessionFile"]?.string, !file.isEmpty,
              let sessionID = value["sessionID"]?.string, !sessionID.isEmpty,
              let time = value["timestamp"]?.double, time.isFinite, time > 0,
              let used = OMPInspectionNumber.count(value["native"]?["usedTokens"]),
              let anchored = value["native"]?["anchored"]?.bool else { return nil }
        let fields = [("system", "systemPromptTokens"), ("projectContext", "systemContextTokens"),
                      ("skills", "skillsTokens"), ("toolSchemas", "systemToolsTokens"), ("messages", "messagesTokens")]
        var rows: [OMPContextCategory] = []
        for (kind, field) in fields {
            guard let count = OMPInspectionNumber.count(value["native"]?[field]) else { return nil }
            rows.append(.init(kind: kind, tokens: count))
        }
        self.file = file; self.sessionID = sessionID
        model = value["model"]?.string.map { String($0.prefix(512)) }
        provider = value["provider"]?.string.map { String($0.prefix(512)) }
        timestamp = Date(timeIntervalSince1970: time / 1000)
        usedTokens = used
        windowTokens = OMPInspectionNumber.count(value["native"]?["contextWindow"]).flatMap { $0 > 0 ? $0 : nil }
        self.anchored = anchored; categories = rows
        composition = OMPContextComposition(value["composition"])
    }
}

struct OMPContextRequestMetadata: Equatable, Sendable {
    let composition: OMPContextComposition?
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let reasoning: Int?
    let payloadObserved: Bool?

    init(_ value: JSONValue) {
        composition = OMPContextComposition(value["composition"])
        let usage = value["reportedUsage"]
        input = OMPInspectionNumber.count(usage?["input"])
        output = OMPInspectionNumber.count(usage?["output"])
        cacheRead = OMPInspectionNumber.count(usage?["cacheRead"])
        cacheWrite = OMPInspectionNumber.count(usage?["cacheWrite"])
        reasoning = OMPInspectionNumber.count(usage?["reasoningTokens"])
        payloadObserved = value["payloadObserved"]?.bool
    }
    var reportedInput: Int? { OMPInspectionNumber.sum([input, cacheRead, cacheWrite]) }
    var difference: Int? { composition.flatMap { composition in reportedInput.map { $0 - composition.total } } }
}

/// All retained journal branches, including native auxiliary calls. Reasoning
/// is a reported subset of output; task usage is counted only at its outer report.
struct OMPContextAccounting: Equatable, Sendable {
    private(set) var reports = 0
    private(set) var missingReports = 0
    private(set) var reasoningReports = 0
    private(set) var input: Int? = 0
    private(set) var output: Int? = 0
    private(set) var cacheRead: Int? = 0
    private(set) var cacheWrite: Int? = 0
    private(set) var total: Int? = 0
    private(set) var reasoning: Int? = nil
    private(set) var cost: Double? = 0
    private(set) var users = 0
    private(set) var assistants = 0
    private(set) var toolCalls = 0
    private(set) var toolResults = 0
    private(set) var auxiliaryCalls = 0

    var cacheHitRate: Double? {
        guard let read = cacheRead, let denominator = OMPInspectionNumber.sum([input, cacheRead, cacheWrite]),
              denominator > 0, read <= denominator else { return nil }
        return Double(read) / Double(denominator)
    }

    init(entries: [JSONValue]) {
        for entry in entries {
            if entry["type"]?.string == "message", let message = entry["message"] {
                switch message["role"]?.string {
                case "user": users += 1
                case "assistant":
                    assistants += 1
                    toolCalls += (message["content"]?.array ?? []).filter { $0["type"]?.string == "toolCall" }.count
                    add(message["usage"])
                case "toolResult":
                    toolResults += 1
                    if let usage = message["usage"] ?? (message["toolName"]?.string == "task" ? message["details"]?["usage"] : nil) { add(usage) }
                default: break
                }
            } else if ["model_usage", "usage", "compaction", "branch_summary"].contains(entry["type"]?.string ?? ""),
                      let usage = entry["usage"] {
                auxiliaryCalls += 1
                add(usage)
            }
        }
        if reports == 0 { input = nil; output = nil; cacheRead = nil; cacheWrite = nil; total = nil; cost = nil }
    }

    private mutating func add(_ usage: JSONValue?) {
        guard let usage, usage.object != nil else { missingReports += 1; return }
        reports += 1
        let fresh = OMPInspectionNumber.count(usage["input"]), out = OMPInspectionNumber.count(usage["output"])
        let read = OMPInspectionNumber.count(usage["cacheRead"]), write = OMPInspectionNumber.count(usage["cacheWrite"])
        input = OMPInspectionNumber.sum([input, fresh]); output = OMPInspectionNumber.sum([output, out])
        cacheRead = OMPInspectionNumber.sum([cacheRead, read]); cacheWrite = OMPInspectionNumber.sum([cacheWrite, write])
        total = OMPInspectionNumber.sum([total, OMPInspectionNumber.count(usage["totalTokens"]) ?? OMPInspectionNumber.sum([fresh, out, read, write])])
        if let amount = OMPInspectionNumber.count(usage["reasoningTokens"] ?? usage["reasoning"]) {
            reasoning = OMPInspectionNumber.sum([reasoning ?? 0, amount]); reasoningReports += 1
        }
        if let amount = usage["cost"]?["total"]?.double, amount.isFinite, amount >= 0, let previous = cost,
           (previous + amount).isFinite { cost = previous + amount }
        else { cost = nil }
    }
}
