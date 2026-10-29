import Foundation

/// Subscription reports are separate from tokens recorded by GUI conversations.
/// Only public OMP fields enter this projection; raw responses and credentials are discarded.
struct OMPProviderUsage: Sendable, Equatable {
    struct Balance: Sendable, Equatable, Identifiable {
        let currency: String
        let total: String?
        let granted: String?
        let toppedUp: String?
        var id: String { currency }
    }

    struct Limit: Sendable, Equatable, Identifiable {
        let id: String
        let label: String
        let unit: String
        let used: Double?
        let maximum: Double?
        let remaining: Double?
        let usedFraction: Double?
        let resetsAt: Date?
        let resetLabel: String?
        let model: String?
        let sharedGroup: String?
        let status: String?

        func isConfirmed(at now: Date) -> Bool {
            guard status.map({ ["ok", "warning", "exhausted"].contains($0) }) ?? true,
                  resetsAt.map({ $0 > now }) ?? true else { return false }
            if usedFraction != nil { return true }
            return ["tokens", "requests", "credits", "usd", "minutes", "bytes"].contains(unit)
                && (used != nil || remaining != nil)
        }
    }

    struct Report: Sendable, Equatable, Identifiable {
        let id: String
        let provider: String
        let account: String?
        let plan: String?
        let fetchedAt: Date?
        let source: String?
        let limits: [Limit]
        let balances: [Balance]
    }

    let reports: [Report]
    let unavailableProviders: Set<String>
    let isTruncated: Bool

    func reports(for provider: String) -> [Report] { reports.filter { $0.provider == provider } }

    /// Do not show missing/stale/estimated counters as current, or manufacture empty meters.
    func confirmedReports(for provider: String, now: Date = .now) -> [Report] {
        confirmedReports(now: now).filter { $0.provider == provider }
    }

    func confirmedReports(now: Date = .now) -> [Report] {
        reports.compactMap { report in
            guard let fetchedAt = report.fetchedAt, now.timeIntervalSince(fetchedAt) >= -5,
                  now.timeIntervalSince(fetchedAt) <= 600,
                  report.source != "omp-observed", report.source != "estimated" else { return nil }
            let confirmed = report.limits.filter { $0.isConfirmed(at: now) }
            guard !confirmed.isEmpty || !report.balances.isEmpty else { return nil }
            return Report(id: report.id, provider: report.provider, account: report.account, plan: report.plan,
                          fetchedAt: fetchedAt, source: report.source, limits: confirmed, balances: report.balances)
        }
    }

    static func decode(_ value: JSONValue) throws -> Self {
        guard let rows = value["reports"]?.array else { throw DecodeError.invalid }
        var reports: [Report] = []
        var unavailable: Set<String> = []
        var budget = 1_024
        var truncated = rows.count > 128
        for (index, row) in rows.prefix(128).enumerated() {
            guard let provider = text(row["provider"]) else { continue }
            guard let entries = row["limits"]?.array else { unavailable.insert(provider); continue }
            let metadata = row["metadata"]
            let account = text(metadata?["email"]) ?? text(metadata?["accountId"])
            let plan = text(metadata?["planType"]) ?? text(metadata?["plan"])
            let reportID = "\(provider)|\(index)"
            var limits: [Limit] = []
            if entries.count > min(128, budget) { truncated = true }
            for (position, limit) in entries.prefix(min(128, budget)).enumerated() {
                let amount = limit["amount"]
                let unit = text(amount?["unit"]) ?? "unknown"
                let used = number(amount?["used"])
                let maximum = number(amount?["limit"])
                let remaining = number(amount?["remaining"])
                let fraction: Double?
                // Match OMP resolveUsedFraction, retaining overage rather than inventing zero.
                if let explicit = nonnegative(amount?["usedFraction"]) { fraction = explicit }
                else if let used, used >= 0, let maximum, maximum > 0 { fraction = used / maximum }
                else if unit == "percent", let used, used >= 0 { fraction = used / 100 }
                else if let left = nonnegative(amount?["remainingFraction"]), left <= 1 { fraction = 1 - left }
                else { fraction = nil }
                limits.append(Limit(
                    id: "\(reportID)|\(text(limit["id"]) ?? String(position))|\(position)",
                    label: text(limit["label"]) ?? text(limit["window"]?["label"]) ?? text(limit["id"]) ?? "Usage",
                    unit: unit, used: used, maximum: maximum, remaining: remaining, usedFraction: fraction.flatMap { $0.isFinite ? $0 : nil },
                    resetsAt: date(limit["window"]?["resetsAt"]), resetLabel: text(limit["window"]?["resetLabel"]),
                    model: text(limit["scope"]?["modelId"]), sharedGroup: text(limit["scope"]?["sharedGroup"]),
                    status: text(limit["status"])
                ))
            }
            budget -= limits.count
            reports.append(Report(id: reportID, provider: provider, account: account, plan: plan,
                                  fetchedAt: date(row["fetchedAt"]), source: text(metadata?["source"]), limits: limits,
                                  balances: balances(provider: provider, metadata: metadata)))
        }
        for key in ["accountsWithoutUsage", "disabledCredentials"] {
            for row in (value[key]?.array ?? []).prefix(512) {
                if let provider = text(row["provider"]) { unavailable.insert(provider) }
            }
        }
        return Self(reports: reports, unavailableProviders: unavailable, isTruncated: truncated)
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let string = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return String(string.prefix(256))
    }
    private static func balances(provider: String, metadata: JSONValue?) -> [Balance] {
        guard provider == "deepseek", metadata?["source"]?.string == "omp-gui-deepseek-balance-v1",
              metadata?["ompGuiBalances"]?["version"]?.int == 1,
              let rows = metadata?["ompGuiBalances"]?["items"]?.array, rows.count <= 8 else { return [] }
        return rows.compactMap { row in
            guard let currency = row["currency"]?.string, ["CNY", "USD"].contains(currency),
                  rows.filter({ $0["currency"]?.string == currency }).count == 1 else { return nil }
            let total = decimalText(row["total"]), granted = decimalText(row["granted"]), toppedUp = decimalText(row["toppedUp"])
            guard total != nil || granted != nil || toppedUp != nil else { return nil }
            return Balance(currency: currency, total: total, granted: granted, toppedUp: toppedUp)
        }
    }
    private static func decimalText(_ value: JSONValue?) -> String? {
        guard let raw = value?.string, raw.utf8.count <= 32,
              raw.range(of: "^[+-]?[0-9]{1,18}(?:\\.[0-9]{1,12})?$", options: .regularExpression) == raw.startIndex..<raw.endIndex,
              Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) != nil else { return nil }
        return raw
    }
    private static func number(_ value: JSONValue?) -> Double? {
        guard let result = value?.double, result.isFinite else { return nil }
        return result
    }
    private static func nonnegative(_ value: JSONValue?) -> Double? {
        guard let number = number(value), number >= 0 else { return nil }
        return number
    }
    private static func date(_ value: JSONValue?) -> Date? {
        guard let milliseconds = number(value), milliseconds > 0, milliseconds < 32_503_680_000_000 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
    enum DecodeError: Error { case invalid }
}
