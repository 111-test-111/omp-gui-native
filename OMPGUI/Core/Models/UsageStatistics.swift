import Foundation

enum UsageRange: String, CaseIterable, Sendable {
    case week, month, quarter, all

    var title: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .all: "All time"
        }
    }

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }
}

enum UsageCalendar {
    static var calendar: Calendar { Calendar(identifier: .gregorian) }

    static func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Decode only accounting fields: reading usage never constructs message or tool views.
struct UsageTurn: Decodable, Sendable {
    let id: UUID
    let startedAt: Date
    let nativeUserEntryID: String?
    let nativeSessionFile: String?
    let tokenSpends: [TokenSpend]?

    init(_ turn: TurnRecord) {
        id = turn.id
        startedAt = turn.startedAt
        nativeUserEntryID = turn.nativeUserEntryID
        nativeSessionFile = turn.nativeSessionFile
        tokenSpends = turn.tokenSpends
    }

    var nativeIdentity: String? {
        guard let file = nativeSessionFile, !file.isEmpty,
              let entry = nativeUserEntryID, !entry.isEmpty else { return nil }
        return URL(fileURLWithPath: file).standardizedFileURL.path + "\n" + entry
    }
}

struct UsageThreadSnapshot: Sendable {
    let thread: ChatThread
    let turns: [UsageTurn]
}

enum UsageLane: String, CaseIterable, Identifiable, Sendable {
    case input, cached, output, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .input: "Other input"
        case .cached: "Cache reads"
        case .output: "Output"
        case .unknown: "Unclassified"
        }
    }
}

struct UsageAmounts: Sendable {
    var total = 0
    var input = 0
    var cached = 0
    var output = 0
    var unknown = 0
    var cacheEligibleInput = 0
    var outputReports = 0

    init() {}

    init(_ spend: TokenSpend) {
        total = max(0, spend.totalTokens)
        let reportedInput = spend.inputTokens.flatMap { (0...total).contains($0) ? $0 : nil }
        let reportedOutput = spend.outputTokens.flatMap { (0...(total - (reportedInput ?? 0))).contains($0) ? $0 : nil }
        input = reportedInput ?? 0
        output = reportedOutput ?? 0
        outputReports = reportedOutput == nil ? 0 : 1
        if let cache = PromptCacheUsage(inputTokens: reportedInput, cachedInputTokens: spend.cachedInputTokens) {
            cached = cache.cachedInputTokens
            cacheEligibleInput = cache.inputTokens
            input -= cached
        }
        unknown = total - input - cached - output
    }

    mutating func add(_ other: Self) {
        total += other.total
        input += other.input
        cached += other.cached
        output += other.output
        unknown += other.unknown
        cacheEligibleInput += other.cacheEligibleInput
        outputReports += other.outputReports
    }

    subscript(_ lane: UsageLane) -> Int {
        switch lane {
        case .input: input
        case .cached: cached
        case .output: output
        case .unknown: unknown
        }
    }

    var cacheHitRate: Double? {
        cacheEligibleInput > 0 ? Double(cached) / Double(cacheEligibleInput) : nil
    }
}

struct UsageDay: Identifiable, Sendable {
    let date: Date
    var amounts = UsageAmounts()
    var id: Date { date }
}

struct UsageRank: Identifiable, Sendable {
    let id: String
    let name: String
    var localized = false
    var tokens = 0
}

/// A value snapshot built off the main actor, shared by all charts on the page.
struct UsageStatistics: Sendable {
    var amounts = UsageAmounts()
    var days: [UsageDay] = []
    var yearDaily: [String: Int] = [:]
    var yearTotal = 0
    var activeDays = 0
    var sessionCount = 0
    var turnCount = 0
    var missingTurns = 0
    var invalidReports = 0
    var subagentTokens = 0
    var modelCount = 0
    var dailyAverage = 0
    var previousTotal: Int?
    var models: [UsageRank] = []
    var providers: [UsageRank] = []
    var projects: [UsageRank] = []

    static func build(_ snapshots: [UsageThreadSnapshot], projects: [Project], range: UsageRange,
                      now: Date = .now) -> Self {
        let calendar = UsageCalendar.calendar
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let start = range.days.map { calendar.date(byAdding: .day, value: 1 - $0, to: today)! }
        let previousStart = range.days.map { calendar.date(byAdding: .day, value: -$0, to: start!)! }
        let chartStart = start ?? calendar.date(byAdding: .day, value: -89, to: today)!
        let year = calendar.component(.year, from: today)
        let projectNames = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var result = Self()
        if range.days != nil { result.previousTotal = 0 }
        var daily: [Date: UsageAmounts] = [:]
        var active: Set<Date> = []
        var sessions: Set<UUID> = []
        var modelNames: Set<String> = []
        var models: [String: UsageRank] = [:]
        var providers: [String: UsageRank] = [:]
        var projectRanks: [String: UsageRank] = [:]
        var turnIDs: Set<UUID> = []
        var nativeIDs: Set<String> = []
        var earliest = today
        var accountedTokens = 0

        // Forked/imported GUI histories can contain the same turn. The original chat
        // owns it; child-agent threads keep their own distinct native turns.
        let ordered = canonicalSnapshots(snapshots).sorted {
            if $0.thread.createdAt != $1.thread.createdAt { return $0.thread.createdAt < $1.thread.createdAt }
            return $0.thread.id.uuidString < $1.thread.id.uuidString
        }
        for snapshot in ordered where snapshot.thread.provider == .omp {
            for turn in snapshot.turns {
                guard turn.startedAt < tomorrow, turn.startedAt.timeIntervalSince1970.isFinite,
                      turnIDs.insert(turn.id).inserted else { continue }
                if let identity = turn.nativeIdentity, !nativeIDs.insert(identity).inserted { continue }
                let date = calendar.startOfDay(for: turn.startedAt)
                let spends = (turn.tokenSpends ?? []).filter { $0.provider == .omp && $0.agentID == nil && $0.totalTokens > 0 }
                let inRange = start == nil || date >= start!
                if spends.isEmpty {
                    if inRange { result.missingTurns += 1 }
                    continue
                }
                var turnAmounts = UsageAmounts()
                let accepted = spends.filter { spend in
                    // A damaged imported count must not overflow and crash settings.
                    let next = accountedTokens.addingReportingOverflow(spend.totalTokens)
                    guard !next.overflow else { result.invalidReports += 1; return false }
                    accountedTokens = next.partialValue
                    turnAmounts.add(UsageAmounts(spend))
                    return true
                }
                guard !accepted.isEmpty else { continue }
                earliest = min(earliest, date)
                if calendar.component(.year, from: date) == year {
                    result.yearDaily[UsageCalendar.dayKey(date), default: 0] += turnAmounts.total
                    result.yearTotal += turnAmounts.total
                }
                if let previousStart, let start, date >= previousStart, date < start {
                    result.previousTotal! += turnAmounts.total
                }
                guard inRange else { continue }
                result.amounts.add(turnAmounts)
                result.turnCount += 1
                active.insert(date)
                sessions.insert(snapshot.thread.id)
                if snapshot.thread.isHydraHead { result.subagentTokens += turnAmounts.total }
                daily[date, default: UsageAmounts()].add(turnAmounts)
                let projectKey = snapshot.thread.projectID?.uuidString ?? "standalone"
                let projectName = snapshot.thread.projectID.flatMap { projectNames[$0] }
                addRank(&projectRanks, id: projectKey, name: projectName ?? (snapshot.thread.projectID == nil ? "Standalone tasks" : "Unavailable project"),
                        localized: projectName == nil, tokens: turnAmounts.total)
                for spend in accepted {
                    let model = spend.model?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let knownModel = model.flatMap { $0.isEmpty ? nil : $0 }
                    if let knownModel { modelNames.insert(knownModel) }
                    addRank(&models, id: knownModel ?? "unknown", name: knownModel ?? "Unknown model",
                            localized: knownModel == nil, tokens: spend.totalTokens)
                    let parts = knownModel?.split(separator: "/", maxSplits: 1).map(String.init) ?? []
                    let provider = parts.count == 2 ? parts[0] : nil
                    addRank(&providers, id: provider ?? "unknown", name: provider ?? "Unknown provider",
                            localized: provider == nil, tokens: spend.totalTokens)
                }
            }
        }
        result.activeDays = active.count
        result.sessionCount = sessions.count
        result.modelCount = modelNames.count
        let dayCount = range.days ?? ((calendar.dateComponents([.day], from: earliest, to: today).day ?? 0) + 1)
        result.dailyAverage = result.amounts.total / max(1, dayCount)
        var date = chartStart
        while date < tomorrow {
            result.days.append(UsageDay(date: date, amounts: daily[date] ?? UsageAmounts()))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        result.models = ranked(models)
        result.providers = ranked(providers)
        result.projects = ranked(projectRanks)
        return result
    }

    private static func addRank(_ ranks: inout [String: UsageRank], id: String, name: String, localized: Bool, tokens: Int) {
        ranks[id, default: UsageRank(id: id, name: name, localized: localized)].tokens += tokens
    }

    private static func canonicalSnapshots(_ snapshots: [UsageThreadSnapshot]) -> [UsageThreadSnapshot] {
        // Older GUI versions created aliases for successive observations of one
        // native worker. Their synthetic GUI turn IDs differ even though each
        // snapshot repeats the same cumulative transcript. Use the most complete
        // preserved snapshot, attributed to its stable page.
        let groups = Dictionary(grouping: snapshots) { $0.thread.hydra?.nativeCanonicalID ?? $0.thread.id }
        return groups.map { id, group in
            let owner = group.first { $0.thread.id == id }?.thread ?? group[0].thread
            let best = group.max {
                let lhs = tokenWeight($0), rhs = tokenWeight($1)
                return lhs == rhs ? $0.thread.updatedAt < $1.thread.updatedAt : lhs < rhs
            }!
            return UsageThreadSnapshot(thread: owner, turns: best.turns)
        }
    }

    private static func tokenWeight(_ snapshot: UsageThreadSnapshot) -> Double {
        snapshot.turns.reduce(0) { total, turn in
            total + (turn.tokenSpends ?? []).filter { $0.provider == .omp && $0.agentID == nil }
                .reduce(0) { $0 + Double(max(0, $1.totalTokens)) }
        }
    }

    private static func ranked(_ ranks: [String: UsageRank]) -> [UsageRank] {
        let sorted = ranks.values.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
        guard sorted.count > 8 else { return sorted }
        return Array(sorted.prefix(8)) + [UsageRank(id: "remainder", name: "Other", localized: true,
                                                   tokens: sorted.dropFirst(8).reduce(0) { $0 + $1.tokens })]
    }
}
