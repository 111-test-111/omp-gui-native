import Foundation

struct ArchiveFilter: Equatable {
    enum ChatType: CaseIterable {
        case all, chats, heads

        var title: String {
            switch self {
            case .all: "All chats"
            case .chats: "Chats"
            case .heads: "Hydra heads"
            }
        }
    }

    enum ProjectScope: Hashable {
        case all, project(UUID), none
    }

    var query = ""
    var chatType: ChatType = .all
    var project: ProjectScope = .all

    var isActive: Bool { !search.isEmpty || chatType != .all || project != .all }
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The archive's projects, by name, for the project picker and the groups.
    static func projects(in archived: [ChatThread], from all: [Project]) -> [Project] {
        let ids = Set(archived.compactMap(\.projectID))
        return all.filter { ids.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func scope(of thread: ChatThread, known: Set<UUID>) -> ProjectScope {
        thread.projectID.flatMap { known.contains($0) ? .project($0) : nil } ?? .none
    }

    func apply(to archived: [ChatThread], known: Set<UUID>) -> [ChatThread] {
        let search = search
        return archived.filter { thread in
            let matchesType = chatType == .all || (chatType == .heads ? thread.isHydraHead : !thread.isHydraHead)
            let matchesProject = project == .all || project == Self.scope(of: thread, known: known)
            let matchesSearch = search.isEmpty || [thread.title, thread.hydra?.persona.name ?? "", thread.hydra?.task ?? ""].contains {
                $0.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return matchesType && matchesProject && matchesSearch
        }
    }
}

