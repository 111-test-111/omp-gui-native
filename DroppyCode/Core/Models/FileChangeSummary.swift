import Foundation

/// What a turn changed, file by file, as the timeline and the changes tab show it.
struct FileChangeSummary: Codable, Hashable, Sendable {
    struct File: Codable, Hashable, Sendable {
        var path: String
        var additions: Int
        var deletions: Int
        var isBinary: Bool
    }

    let files: [File]
    let additions: Int
    let deletions: Int
}
