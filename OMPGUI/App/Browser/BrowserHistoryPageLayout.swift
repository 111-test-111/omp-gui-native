import AppKit

/// Pagination and native rows share the same geometry, including date headings.
/// Only complete rows enter a page; the last visible visit is its next cursor.
struct BrowserHistoryPageLayout: Equatable, Sendable {
    static let maximumHeight: CGFloat = 360
    let rowHeight: CGFloat = 40
    let rowSpacing: CGFloat = 4
    let groupSpacing: CGFloat = 12
    let contentPadding: CGFloat = 8
    let headingHeight: CGFloat
    let headingSpacing: CGFloat
    let calendar: Calendar

    @MainActor init(calendar: Calendar = .current) {
        self.calendar = calendar
        let heading = NSFont.systemFont(ofSize: TypeScale.shared.ui(11), weight: .semibold)
        let title = NSFont.systemFont(ofSize: TypeScale.shared.ui(12))
        headingHeight = ceil(heading.ascender - heading.descender + heading.leading)
        let titleHeight = ceil(title.ascender - title.descender + title.leading)
        // A title has no row hit-area padding. Add the row's lower inset so
        // heading-to-title whitespace matches title-to-title whitespace.
        headingSpacing = rowSpacing + max(0, (rowHeight - titleHeight) / 2)
    }

    func height(for entries: [BrowserHistoryEntry]) -> CGFloat {
        let groups = BrowserHistoryDay.groups(entries, calendar: calendar)
        return contentPadding * 2 + groups.reduce(CGFloat.zero) { height, group in
            height + headingHeight + headingSpacing + CGFloat(group.entries.count) * rowHeight
                + CGFloat(group.entries.count - 1) * rowSpacing
        } + CGFloat(max(0, groups.count - 1)) * groupSpacing
    }

    func fitting(_ source: BrowserHistoryPage) -> BrowserHistoryPage {
        var entries: [BrowserHistoryEntry] = []
        for entry in source.entries {
            let candidate = entries + [entry]
            guard height(for: candidate) <= Self.maximumHeight else { break }
            entries = candidate
        }
        return .init(entries: entries, hasMore: source.hasMore || entries.count < source.entries.count)
    }
}
