import Foundation

struct OMPHostToolRequest: Sendable {
    var id: String
    var toolCallID: String
    var name: String
    var arguments: JSONValue
}

enum OMPHostToolError: LocalizedError {
    case noSelection, invalidLocation, unavailablePreview

    var errorDescription: String? {
        switch self {
        case .noSelection: AppText.localized("Add file context from the preview before OMP can read it.")
        case .invalidLocation: AppText.localized("The requested file location is outside the selected worktree.")
        case .unavailablePreview: AppText.localized("Open this conversation to show its file preview.")
        }
    }
}
