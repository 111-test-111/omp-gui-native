import Foundation

struct BrowserHistoryVisit: Sendable {
    let id: UUID
    let url: String
    let visitedAt: Date
}

struct BrowserHistoryEntry: Identifiable, Equatable, Sendable {
    let id: Int64
    let url: String
    let title: String
    let visitedAt: Date
    var icon: BrowserHistoryIcon? = nil
    var source: BrowserHistorySource = .gui
    var sourceName: String = ""

    var displayTitle: String { title.isEmpty ? (URL(string: url)?.host ?? url) : title }
    var host: String { URL(string: url)?.host ?? url }
    var cursor: BrowserHistoryCursor { .init(date: visitedAt, id: id) }
}

struct BrowserHistoryIcon: Equatable, Sendable {
    static let maximumBytes = 65_536
    let png: Data
    let isTemplate: Bool
}

struct BrowserHistoryCursor: Equatable, Sendable {
    let date: Date
    let id: Int64
}

struct BrowserHistoryPage: Sendable {
    static let size = 50
    var entries: [BrowserHistoryEntry] = []
    var hasMore = false
}

struct BrowserHistoryDay: Identifiable {
    let id: Date
    var entries: [BrowserHistoryEntry]

    static func groups(_ entries: [BrowserHistoryEntry], calendar: Calendar = .current) -> [Self] {
        var groups: [Self] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.visitedAt)
            if groups.last?.id == day { groups[groups.count - 1].entries.append(entry) }
            else { groups.append(Self(id: day, entries: [entry])) }
        }
        return groups
    }
}

enum BrowserHistoryRange: String, CaseIterable, Identifiable {
    case hour, today, week, all
    var id: Self { self }
    var title: String {
        switch self {
        case .hour: "Last hour"
        case .today: "Today"
        case .week: "Last 7 days"
        case .all: "All time"
        }
    }

    func start(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .hour: now.addingTimeInterval(-3_600)
        case .today: calendar.startOfDay(for: now)
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .all: nil
        }
    }
}

/// Tracks committed main-frame addresses, never speculative address-field input.
/// Repeated notifications/reloads of the same address do not create extra visits.
struct BrowserHistoryNavigation {
    private(set) var visit: BrowserHistoryVisit?

    mutating func navigate(to address: String, at date: Date = .now) -> BrowserHistoryVisit? {
        guard let url = BrowserAddress.resolve(address), url.scheme != "about" else {
            visit = nil
            return nil
        }
        guard visit?.url != url.absoluteString else { return nil }
        let next = BrowserHistoryVisit(id: UUID(), url: url.absoluteString, visitedAt: date)
        visit = next
        return next
    }
}
