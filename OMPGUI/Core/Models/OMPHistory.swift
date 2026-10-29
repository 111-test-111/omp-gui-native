import Foundation

/// Durable OMP entries bind displayed messages to native editing and branching.
/// Only a durable user entry ID can be passed to the native branch command.
struct OMPHistoryImage: Hashable, Sendable {
    var data: String
    var mimeType: String
}

struct OMPHistoryMessage: Hashable, Sendable {
    var role: String
    var text: String
    var images: [OMPHistoryImage]
    var timestamp: Double?

    init?(_ value: JSONValue) {
        guard let role = value["role"]?.string, !role.isEmpty else { return nil }
        self.role = role
        let content = value["content"]
        text = content?.string ?? (content?.array ?? []).compactMap { block in
            block["type"]?.string == "text" ? block["text"]?.string : nil
        }.joined()
        let imageBlocks = (content?.array ?? []).filter { $0["type"]?.string == "image" }
        images = imageBlocks.compactMap { block in
            guard let data = block["data"]?.string,
                  let mime = block["mimeType"]?.string, mime.hasPrefix("image/") else { return nil }
            return OMPHistoryImage(data: data, mimeType: mime)
        }
        guard images.count == imageBlocks.count else { return nil }
        timestamp = value["timestamp"]?.double
    }
}

struct OMPHistoryEntry: Identifiable, Hashable, Sendable {
    var id: String
    var parentID: String?
    var timestamp: String?
    var type: String
    var message: OMPHistoryMessage?
    var summary: String?
    var method: String?

    var isUserMessage: Bool { type == "message" && message?.role == "user" }
    var text: String { message?.text ?? summary ?? "" }

    init(_ value: JSONValue) throws {
        guard let id = value["id"]?.string, !id.isEmpty,
              let type = value["type"]?.string, !type.isEmpty,
              let parent = value["parentId"], parent.isNull || parent.string?.isEmpty == false else {
            throw OMPHistoryError.invalidHistory
        }
        self.id = id
        parentID = parent.string
        timestamp = value["timestamp"]?.string
        self.type = type
        message = value["message"].flatMap(OMPHistoryMessage.init)
        if type == "message", message == nil { throw OMPHistoryError.invalidHistory }
        summary = value["summary"]?.string ?? value["label"]?.string ?? value["title"]?.string ?? value["model"]?.string
        method = value["method"]?.string
    }
}

struct OMPHistoryUserInput: Sendable {
    var id: UUID
    /// The exact payload submitted to OMP, including any hidden context.
    var text: String
    var imageCount: Int
    var nativeEntryID: String? = nil
}

struct OMPHistorySnapshot: Sendable {
    let sessionFile: String
    let sessionID: String
    private(set) var entries: [OMPHistoryEntry]
    private(set) var leafID: String?

    init(_ value: JSONValue, sessionFile: String, sessionID: String) throws {
        guard let rows = value["entries"]?.array, let leaf = value["leafId"],
              leaf.isNull || leaf.string?.isEmpty == false,
              !sessionFile.isEmpty, !sessionID.isEmpty else { throw OMPHistoryError.invalidHistory }
        self.sessionFile = sessionFile
        self.sessionID = sessionID
        entries = try rows.map(OMPHistoryEntry.init)
        leafID = leaf.string
        guard Set(entries.map(\.id)).count == entries.count else { throw OMPHistoryError.invalidHistory }
        _ = try activePath()
    }

    /// Follow parent links; append order also includes abandoned paths.
    func activePath() throws -> [OMPHistoryEntry] {
        let index = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var seen: Set<String> = []
        var path: [OMPHistoryEntry] = []
        var next = leafID
        while let id = next {
            guard seen.insert(id).inserted, let entry = index[id] else { throw OMPHistoryError.invalidHistory }
            path.append(entry)
            next = entry.parentID
        }
        return path.reversed()
    }

    var activeUserEntries: [OMPHistoryEntry] { ((try? activePath()) ?? []).filter(\.isUserMessage) }

    /// Migration is deliberately conservative: compare a complete ordered prefix,
    /// never search for the next equal text. Repeated messages remain unambiguous
    /// only when every preceding durable user message also matches.
    func mapUserEntries(to inputs: [OMPHistoryUserInput]) -> [UUID: String] {
        guard let path = try? activePath() else { return [:] }
        let users = path.filter(\.isUserMessage)
        guard inputs.count <= users.count, Set(inputs.map(\.id)).count == inputs.count else { return [:] }
        var mapped: [UUID: String] = [:]
        for (input, entry) in zip(inputs, users) {
            guard let message = entry.message, message.text == input.text,
                  message.images.count == input.imageCount,
                  input.nativeEntryID == nil || input.nativeEntryID == entry.id else { return [:] }
            mapped[input.id] = entry.id
        }
        return mapped
    }
}

struct OMPHistoryBranchResult: Sendable {
    var cancelled: Bool
    var sessionFile: String
    var sessionID: String
    var editorText: String
    var images: [OMPHistoryImage]
}

enum OMPHistoryError: LocalizedError {
    case invalidHistory
    case staleCursor
    case sessionBusy
    case invalidBranchEntry
    case identityUnavailable
    case branchOutcomeUnknown
    case branchFailedAfterChange

    var errorDescription: String? {
        switch self {
        case .invalidHistory: AppText.localized("OMP returned invalid native history.")
        case .staleCursor: AppText.localized("Native history changed. Reload it before continuing.")
        case .sessionBusy: AppText.localized("Wait for OMP to finish before reading or branching history.")
        case .invalidBranchEntry: AppText.localized("This native entry is not a user message on the current path.")
        case .identityUnavailable: AppText.localized("OMP created a branch but its new session identity could not be read. The original conversation is preserved.")
        case .branchOutcomeUnknown: AppText.localized("OMP did not confirm the branch result. The connection was closed to protect the original conversation; reopen it before retrying.")
        case .branchFailedAfterChange: AppText.localized("OMP changed the session while branching failed. The connection was closed; the original conversation is preserved.")
        }
    }
}
