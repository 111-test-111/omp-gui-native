import Foundation

extension AppSettings {
    @discardableResult func deleteBrowserProfile(_ id: UUID) -> BrowserProfileRecord? {
        guard !BrowserCookieImporter.shared.isImporting else { return nil }
        return browserProfiles.remove(id)
    }

    /// Called once from application bootstrap, never from the delete action.
    /// A queued active profile remains protected until a subsequent process.
    func cleanDeletedBrowserProfiles() async {
        let pending = Set(browserProfiles.pendingDeletionIDs)
        guard !pending.isEmpty else { return }
        let protected = Set(browserProfiles.profiles.map(\.id)).union([BrowserProfileConfiguration.activeProfile.id])
        let root = StoragePaths.root
        let removed = await Task.detached(priority: .utility) {
            BrowserProfileCleanup.clean(pending, keeping: protected, libraryRoot: root)
        }.value
        // Other windows may have retired additional profiles during disk I/O.
        browserProfiles.acknowledgeDeletions(removed)
    }
}
