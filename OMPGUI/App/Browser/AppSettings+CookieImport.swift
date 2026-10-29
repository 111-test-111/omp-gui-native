import Foundation

extension AppSettings {
    func importBrowserCookies(from source: ChromeCookieProfile) async throws -> BrowserCookieImportResult {
        let id = UUID()
        var preflight = browserProfiles
        _ = try preflight.addChromeImport(id: id, sourceName: source.name)
        do {
            let payload = try await BrowserCookieImporter.shared.importChrome(source, profileID: id)
            try Task.checkCancellation()
            // Other settings windows may have added profiles during native I/O.
            // Append to the current catalogue, never replace it with the preflight.
            let profile = try browserProfiles.addChromeImport(id: id, sourceName: payload.sourceProfileName)
            return BrowserCookieImportResult(profile: profile, cookieCount: payload.cookies.count, skippedCount: payload.skippedCount)
        } catch {
            BrowserCookieImporter.shared.discardUnpublishedProfile(id)
            throw error
        }
    }
}
