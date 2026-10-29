import SwiftUI

/// Compact account limits and available money only. No duplicate headings, meters or timestamps.
struct NativeProviderUsageSummary: View {
    let reports: [OMPProviderUsage.Report]

    static func hasKeyValues(_ report: OMPProviderUsage.Report) -> Bool {
        !report.limits.isEmpty || report.balances.contains { $0.total != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let visible = reports.filter(Self.hasKeyValues)
            ForEach(visible) { report in
                VStack(alignment: .leading, spacing: 6) {
                    // Preserve account attribution when OMP returns multiple accounts.
                    if visible.count > 1, let account = report.account {
                        Text(verbatim: account).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                    }
                    ForEach(report.limits) { limit in NativeUsageLimitView(limit: limit) }
                    ForEach(report.balances) { balance in
                        if let value = balance.total { NativeBalanceRow(currency: balance.currency, value: value) }
                    }
                }
            }
        }
    }
}

struct NativeUsageLimitView: View {
    let limit: OMPProviderUsage.Limit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: limit.label).lineLimit(2)
            Spacer(minLength: 4)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    amount
                    reset
                }
                VStack(alignment: .trailing, spacing: 2) { amount; reset }
            }
        }
        .font(.ui(.callout)).foregroundStyle(Chrome.secondaryText)
        .accessibilityElement(children: .combine)
    }

    private var amount: some View {
        Text(verbatim: amountText).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(limit.usedFraction.map { $0 >= 1 } == true || limit.status == "exhausted" ? Chrome.warning : Chrome.primaryText)
    }

    @ViewBuilder private var reset: some View {
        if let reset = limit.resetsAt, let text = resetText(reset) {
            Text(verbatim: text).font(.ui(.caption)).lineLimit(1)
        }
    }

    var amountText: String {
        if let fraction = limit.usedFraction {
            return String(format: Chrome.localized("%@ used"), fraction.formatted(.percent.precision(.fractionLength(0...1))))
        }
        if let used = limit.used, let maximum = limit.maximum {
            return "\(number(used)) / \(number(maximum)) \(unit)"
        }
        if let remaining = limit.remaining {
            return String(format: Chrome.localized("%@ remaining"), "\(number(remaining)) \(unit)")
        }
        if let used = limit.used { return String(format: Chrome.localized("%@ used"), "\(number(used)) \(unit)") }
        return ""
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.significantDigits(1...5))) }
    private var unit: String {
        let key = switch limit.unit {
        case "tokens": "Tokens"
        case "requests": "Requests"
        case "credits": "Credits"
        case "usd": "USD"
        case "minutes": "Minutes"
        case "bytes": "Bytes"
        default: ""
        }
        return Chrome.localized(key)
    }
    func resetText(_ date: Date) -> String? {
        let key: String
        switch limit.resetLabel {
        case nil, "resets": key = "Resets in %@"
        case "regen", "tick": key = "Regenerates in %@"
        default: return nil
        }
        let duration = RelativeTime.duration(date.timeIntervalSinceNow)
        return String(format: Chrome.localized(key), duration)
    }
}

private struct NativeBalanceRow: View {
    let currency: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Available balance").lineLimit(2)
            Spacer(minLength: 4)
            Text(verbatim: currency + " " + value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.ui(.callout)).foregroundStyle(Chrome.secondaryText)
        .accessibilityElement(children: .combine)
    }
}
