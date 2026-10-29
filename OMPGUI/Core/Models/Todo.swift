import Foundation

struct TodoStep: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case active
        case done
        case blocked
        case abandoned
    }

    var text: String
    var status: Status
    var phase: String? = nil
    var blocker: String? = nil
}

/// Native active state plus the nearest nonempty list on its current branch.
/// The latter recovers completion followed by rm inside a single eval cell.
struct TodoSnapshot: Equatable, Sendable {
    var steps: [TodoStep]
    var recentList: [TodoStep]? = nil

    func displayed(after previous: [TodoStep]) -> [TodoStep] {
        if !steps.isEmpty { return steps }
        let candidate = recentList ?? previous
        return !candidate.isEmpty && candidate.allSatisfy { $0.status == .done } ? candidate : []
    }
}
