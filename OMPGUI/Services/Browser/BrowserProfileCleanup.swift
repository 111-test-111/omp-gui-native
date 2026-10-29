import Foundation

/// Deletes only retired UUID profile directories in this edition's library.
/// Failed/unsafe paths stay queued; default, active and published profiles stay.
enum BrowserProfileCleanup {
    static func clean(_ pending: Set<UUID>, keeping protected: Set<UUID>, libraryRoot: URL) -> Set<UUID> {
        let candidates = pending.subtracting(protected).subtracting([BrowserProfileRecord.defaultProfile.id])
        guard !candidates.isEmpty, libraryRoot.isFileURL else { return [] }
        let files = FileManager.default
        let browser = libraryRoot.appendingPathComponent("browser", isDirectory: true)
        let root = browser.appendingPathComponent("profiles", isDirectory: true)
        // Never traverse a substituted library/browser/profile-root symlink.
        for directory in [libraryRoot, browser, root] {
            do {
                let attributes = try files.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { return [] }
            } catch { return isMissing(error) ? candidates : [] }
        }
        var removed = Set<UUID>()
        for id in candidates {
            if Task.isCancelled { break }
            let record = BrowserProfileRecord(id: id, name: "")
            let directory = root.appendingPathComponent("Profile-" + record.storageName, isDirectory: true)
            do {
                let attributes = try files.attributesOfItem(atPath: directory.path)
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeSymbolicLink else { continue }
                // removeItem unlinks a final symlink; it does not remove its target.
                try files.removeItem(at: directory)
                removed.insert(id)
            } catch { if isMissing(error) { removed.insert(id) } }
        }
        return removed
    }

    private static func isMissing(_ error: Error) -> Bool {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return true }
        if failure.domain == NSPOSIXErrorDomain, failure.code == 2 { return true }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error { return isMissing(underlying) }
        return false
    }
}
