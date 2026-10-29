import Foundation

enum ThreadAffiliation: Equatable, Sendable, Codable {
    case project(UUID)
    case standalone

    var projectID: UUID? {
        if case .project(let id) = self { return id }
        return nil
    }
}

enum NewThreadAffiliation: Sendable {
    case project(UUID)
    case standalone
    case current
}

enum NewThreadLocation: String, Codable, CaseIterable {
    case recent
    case standalone
    var title: String { self == .recent ? "Follow recent location" : "Tasks" }
}

enum ThreadOrganization {
    struct TaskSection {
        enum Kind: Equatable { case attention, pinned, day(Date), settled }
        let kind: Kind
        let threads: [ChatThread]
    }

    /// Root conversations across projects and tasks; helpers stay with a visible parent.
    static func activityThreads(_ threads: [ChatThread]) -> [ChatThread] {
        let shown = threads.filter(\.isStandaloneListCandidate)
        let shownIDs = Set(shown.map(\.id))
        return shown.filter { $0.parentThreadID.map { !shownIDs.contains($0) } ?? true }
    }

    /// One ordering for task/activity sections, drag peers and keyboard navigation.
    static func taskSections(_ tasks: [ChatThread], attention: Set<UUID>, calendar: Calendar = .current) -> [TaskSection] {
        let open = tasks.filter { !$0.isSettled }
        let waiting = open.filter { attention.contains($0.id) }
        let rest = open.filter { !attention.contains($0.id) }
        var sections: [TaskSection] = []
        if !waiting.isEmpty { sections.append(TaskSection(kind: .attention, threads: orderedByActivity(waiting, calendar: calendar))) }
        let pinned = rest.filter(\.isPinned)
        if !pinned.isEmpty { sections.append(TaskSection(kind: .pinned, threads: orderedByActivity(pinned, calendar: calendar))) }
        let days = Dictionary(grouping: rest.filter { !$0.isPinned }) { calendar.startOfDay(for: $0.updatedAt) }
        for day in days.keys.sorted(by: >) {
            sections.append(TaskSection(kind: .day(day), threads: orderedByActivity(days[day]!, calendar: calendar)))
        }
        let settled = tasks.filter(\.isSettled).sorted { ($0.settledAt ?? $0.updatedAt) > ($1.settledAt ?? $1.updatedAt) }
        if !settled.isEmpty { sections.append(TaskSection(kind: .settled, threads: settled)) }
        return sections
    }

    private static func orderedByActivity(_ threads: [ChatThread], calendar: Calendar) -> [ChatThread] {
        func order(_ thread: ChatThread) -> Double? {
            guard let order = thread.activityOrder, let day = thread.activityOrderDay,
                  calendar.isDate(day, inSameDayAs: thread.updatedAt) else { return nil }
            return order
        }
        return threads.sorted { lhs, rhs in
            switch (order(lhs), order(rhs)) {
            case let (left?, right?) where left != right: return left < right
            case (nil, .some): return true
            case (.some, nil): return false
            default: return lhs.updatedAt == rhs.updatedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.updatedAt > rhs.updatedAt
            }
        }
    }
}
