import Foundation

/// Which scaling the heatmap colors use.
enum TokenActivityMode: String, Sendable, CaseIterable {
    case daily
    case weekly
    case cumulative

    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .cumulative: "Cumulative"
        }
    }
}

/// Contribution grid over the current year, January to December, Sunday rows.
/// Columns are week buckets starting on the Sunday on or before New Year's
/// Day; every column keeps all seven rows so the grid never shears mid-month.
/// Days still to come stay in the grid as faint cells, so the year keeps its
/// shape and the months read Jan through Dec whatever today's date.
struct TokenActivityGrid {
    /// One column of the grid: the day in each Sunday-first row, nil where
    /// the cell falls outside the year.
    var columns: [[Date?]]
    /// Display value per cell, already scaled for the mode.
    var values: [[Int]]
    var maxValue: Int
    var monthTicks: [(label: String, column: Int)]
    /// The first day after today, so the canvas can tell a quiet day from one not yet here.
    var tomorrow: Date

    static let rows = 7
    static let months = 12

    static func build(daily: [String: Int], mode: TokenActivityMode, now: Date = Date()) -> TokenActivityGrid {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        let startOfToday = calendar.startOfDay(for: now)
        let rangeStart = calendar.date(from: calendar.dateComponents([.year], from: startOfToday)) ?? startOfToday
        let rangeEnd = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: rangeStart) ?? startOfToday
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday

        // First column starts on the Sunday on or before the range start.
        let leadingGap = (calendar.component(.weekday, from: rangeStart) - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingGap, to: rangeStart) ?? rangeStart

        // Day totals inside the range, keyed by day start.
        var totalsByDay: [Date: Int] = [:]
        var cursor = rangeStart
        while cursor <= startOfToday {
            let key = UsageCalendar.dayKey(cursor)
            if let total = daily[key] { totalsByDay[calendar.startOfDay(for: cursor)] = total }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        // Pack days into Sunday-first columns through the week that holds
        // New Year's Eve.
        var columns: [[Date?]] = []
        var day = gridStart
        while true {
            var column: [Date?] = []
            for _ in 0..<rows {
                column.append(day < rangeStart || day > rangeEnd ? nil : day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            columns.append(column)
            if day > rangeEnd { break }
        }

        // Per-mode display values. The shape never changes, only the value
        // each cell is colored by.
        var values = Array(repeating: Array(repeating: 0, count: rows), count: columns.count)
        switch mode {
        case .daily:
            for c in columns.indices {
                for r in 0..<rows {
                    if let date = columns[c][r] { values[c][r] = totalsByDay[date] ?? 0 }
                }
            }
        case .weekly:
            for c in columns.indices {
                var week = 0
                for r in 0..<rows {
                    if let date = columns[c][r] { week += totalsByDay[date] ?? 0 }
                }
                for r in 0..<rows { values[c][r] = columns[c][r] == nil ? 0 : week }
            }
        case .cumulative:
            var running = 0
            for c in columns.indices {
                for r in 0..<rows {
                    if let date = columns[c][r] { running += totalsByDay[date] ?? 0 }
                    values[c][r] = running
                }
            }
        }
        let maxValue = values.flatMap { $0 }.max() ?? 0

        // One tick per month at the column holding its first day.
        var monthTicks: [(label: String, column: Int)] = []
        for offset in 0..<months {
            guard let monthDate = calendar.date(byAdding: .month, value: offset, to: rangeStart) else { continue }
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) ?? monthDate
            let clamped = max(monthStart, rangeStart)
            let daysOut = calendar.dateComponents([.day], from: gridStart, to: clamped).day ?? 0
            let column = daysOut / rows
            let label = monthDate.formatted(.dateTime.month(.abbreviated))
            if column < columns.count { monthTicks.append((label, column)) }
        }

        return TokenActivityGrid(columns: columns, values: values, maxValue: maxValue, monthTicks: monthTicks, tomorrow: tomorrow)
    }
}
