import AppKit

extension AppModel {
    /// The workspace host remains registered while its sidebar is folded.
    /// Scope the intent to windows already displaying this conversation.
    func revealDebugPanel(threadID: UUID) {
        for window in NSApp?.windows ?? [] {
            guard let previews = (window as? ThreadWindow)?.filePreviews,
                  previews.context?.threadID == threadID else { continue }
            // An explicit historical selection stays pinned while new work is
            // recorded. Only the default live view follows the new run.
            if previews.session?.debugRunID == nil { previews.session?.debugRecordID = nil }
            previews.openPanel(.debug)
        }
    }
}
