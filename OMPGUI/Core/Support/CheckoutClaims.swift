import Foundation

/// Several chats share one checkout, and a working-tree diff cannot tell whose write it was.
@MainActor
enum CheckoutClaims {
    private struct Claim {
        var owner: UUID
        var date: Date
    }

    private static var claims: [String: [String: Claim]] = [:]

    private static func key(_ root: String) -> String {
        URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func claim(_ paths: some Sequence<String>, root: String, owner: UUID) {
        let root = key(root)
        let now = Date.now
        for path in paths { claims[root, default: [:]][path] = Claim(owner: owner, date: now) }
    }

    static func foreign(_ paths: some Sequence<String>, root: String, owner: UUID, since: Date) -> Set<String> {
        let latest = claims[key(root)] ?? [:]
        return Set(paths.filter { path in
            guard let claim = latest[path] else { return false }
            return claim.owner != owner && claim.date >= since
        })
    }

    static func othersActive(root: String, owner: UUID, since: Date) -> Bool {
        (claims[key(root)] ?? [:]).values.contains { $0.owner != owner && $0.date >= since }
    }
}
