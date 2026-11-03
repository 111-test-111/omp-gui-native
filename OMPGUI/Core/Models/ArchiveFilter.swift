import Foundation

struct ArchiveFilter: Equatable {
    struct Conversation: Identifiable {
        let thread: ChatThread
        let helpers: [ChatThread]
        var id: UUID { thread.id }
    }

    enum ProjectScope: Hashable {
        case all, project(UUID), none
    }

    var query = ""
    var project: ProjectScope = .all

    var isActive: Bool { !search.isEmpty || project != .all }
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A surviving parent owns its descendants, even when older records have mixed
    /// archive flags. Detached imported helpers retain an entry instead of disappearing.
    static func conversations(in threads: [ChatThread]) -> [Conversation] {
        let known = Set(threads.map(\.id))
        let children = Dictionary(grouping: threads.filter { $0.parentThreadID != nil }) { $0.parentThreadID! }
        return threads.filter { thread in
            thread.isArchived && thread.hydra?.nativeCanonicalID == nil
                && (thread.parentThreadID.map { !known.contains($0) } ?? true)
        }.sorted { $0.updatedAt > $1.updatedAt }.map { root in
            var seen: Set<UUID> = [root.id]
            var pending = children[root.id] ?? []
            var helpers: [ChatThread] = []
            while let child = pending.popLast() {
                guard seen.insert(child.id).inserted else { continue }
                if child.hydra?.nativeCanonicalID == nil { helpers.append(child) }
                pending.append(contentsOf: children[child.id] ?? [])
            }
            helpers.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return ($0.hydra?.index ?? Int.max) < ($1.hydra?.index ?? Int.max)
            }
            return Conversation(thread: root, helpers: helpers)
        }
    }

    /// The archive's projects, by name, for the project picker and the groups.
    static func projects(in archived: [Conversation], from all: [Project]) -> [Project] {
        let ids = Set(archived.compactMap(\.thread.projectID))
        return all.filter { ids.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func scope(of thread: ChatThread, known: Set<UUID>) -> ProjectScope {
        thread.projectID.flatMap { known.contains($0) ? .project($0) : nil } ?? .none
    }

    func apply(to archived: [Conversation], known: Set<UUID>) -> [Conversation] {
        let search = search
        return archived.filter { conversation in
            let matchesProject = project == .all || project == Self.scope(of: conversation.thread, known: known)
            let matchesSearch = search.isEmpty || ([conversation.thread] + conversation.helpers).contains { thread in
                [thread.title, thread.hydra?.persona.name ?? "", thread.hydra?.task ?? ""].contains {
                    $0.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            return matchesProject && matchesSearch
        }
    }
}

