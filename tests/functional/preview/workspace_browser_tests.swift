import AppKit
import PDFKit
import SwiftUI
import SwiftTerm
@testable import CefKit
@testable import OMPGUI

@main
private enum WorkspaceBrowserChecks {
    @MainActor static func main() async throws {
        guard let root = CaptureRun.storageRoot else { fatalError("Requires isolated capture storage") }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        let attachmentID = UUID()
        let attachment = BrowserAutomationAttachment.openOptions(pageID: attachmentID, targetID: "TARGET-B",
            endpoint: URL(string: "http://127.0.0.1:9222")!, downloads: "/tmp/test-downloads")
        expect(attachment["dialogs"] == nil, "Open uses OMP's default policy, without an invalid manual enum")
        expect(attachment["app"]?["target"]?.string == "omp-gui-target:TARGET-B",
               "Exact native target identity survives independent of title and URL")
        expect(attachment["app"]?["cdp_url"]?.string == "http://127.0.0.1:9222",
               "Attachment retains the native browser endpoint")
        expect(BrowserAddress.resolve(" example.com/a ")?.absoluteString == "https://example.com/a", "Bare hosts use HTTPS")
        expect(BrowserAddress.resolve("localhost:5173/a")?.absoluteString == "http://localhost:5173/a", "Local development ports use HTTP")
        expect(BrowserAddress.resolve("127.0.0.1:3000")?.host == "127.0.0.1", "Loopback IPv4")
        expect(BrowserAddress.resolve("[::1]:3000") != nil, "Loopback IPv6")
        for input in ["", "javascript:alert(1)", "file:///etc/passwd", "chrome://settings", "https://user:secret@example.com", "https://", "foo\nbar"] {
            expect(BrowserAddress.resolve(input) == nil, "Reject unsafe or malformed address: \(input)")
        }
        expect(BrowserAddress.resolve("https://example.com/a?q=中文") != nil, "Unicode web address")
        expect(BrowserAddress.restoredURL("file:///tmp/private") == "about:blank", "Restore cannot introduce a privileged navigation")
        expect(BrowserAddress.isBootstrapURL(URL(string: "about:blank#omp-gui-ABCD")!), "Canonicalized bootstrap URLs are never user navigation")
        expect(BrowserAddress.restoredURL("about:blank#omp-gui-abcd") == "about:blank", "Old persisted bootstrap URLs recover to a blank page")

        let query = "C++ & 中文 #swift? = 100% + café"
        let engines: [(BrowserSearchEngine, String, String, String)] = [
            (.google, "www.google.com", "/search", "q"),
            (.bing, "www.bing.com", "/search", "q"),
            (.duckDuckGo, "duckduckgo.com", "/", "q"),
            (.baidu, "www.baidu.com", "/s", "wd")
        ]
        for (engine, host, path, parameter) in engines {
            let url = engine.searchURL(for: "  \(query)  ")!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            expect(url.scheme == "https" && url.host == host && url.path == path,
                   "Search uses the selected engine's public HTTPS endpoint")
            expect(components.queryItems == [URLQueryItem(name: parameter, value: query)] && components.fragment == nil,
                   "Unicode and query delimiters stay in one search term instead of changing URL structure")
            expect(components.percentEncodedQuery?.contains("+") == false,
                   "Form-style decoding cannot turn the plus signs in C++ into spaces")
            expect(engine.searchURL(for: " \n ") == nil && engine.searchURL(for: String(repeating: "x", count: 16_385)) == nil,
                   "Empty and oversized searches do not create navigation URLs")
        }
        let defaults = CaptureRun.defaults!
        defaults.removeObject(forKey: BrowserProfileConfiguration.preferenceKey)
        defaults.removeObject(forKey: "browserSearchEngine")
        let settings = AppSettings()
        expect(settings.browserSearchEngine == .google, "New installations have a stable default search engine")
        for engine in BrowserSearchEngine.allCases {
            settings.browserSearchEngine = engine
            expect(AppSettings().browserSearchEngine == engine, "The engine preference survives settings recreation")
        }
        defaults.set("retired-engine", forKey: "browserSearchEngine")
        expect(AppSettings().browserSearchEngine == .google, "Unknown saved engines recover to the default")
        defaults.removeObject(forKey: "browserSearchEngine")

        expect(settings.browserInterfaceLanguage == .app, "Browser interface language follows the app by default")
        expect(BrowserInterfaceLanguage.app.localizationIdentifier(appLocalization: "zh-Hans") == "zh-Hans"
            && BrowserInterfaceLanguage.app.localizationIdentifier(appLocalization: "en") == "en",
               "Following the app resolves its actual supported localization")
        expect(BrowserInterfaceLanguage.english.localizationIdentifier(appLocalization: "zh-Hans") == "en"
            && BrowserInterfaceLanguage.simplifiedChinese.localizationIdentifier(appLocalization: "en") == "zh-Hans",
               "Explicit browser languages can differ from the application language")
        let currentLanguage = BrowserLocalization.identifier
        for language in BrowserInterfaceLanguage.allCases {
            settings.browserInterfaceLanguage = language
            expect(AppSettings().browserInterfaceLanguage == language, "Browser language selection survives settings recreation")
            expect(BrowserLocalization.identifier == currentLanguage, "Saving a language cannot split the running browser's UI and CEF locale")
        }
        defaults.set("unknown-language", forKey: BrowserInterfaceLanguage.preferenceKey)
        expect(AppSettings().browserInterfaceLanguage == .app, "Unknown saved browser languages fall back to the app")
        defaults.removeObject(forKey: BrowserInterfaceLanguage.preferenceKey)
        let english = BrowserLocalization.localizedBundle(for: "en")
        let chinese = BrowserLocalization.localizedBundle(for: "zh-Hans")
        expect(Chrome.localized("Search the web", bundle: english) == "Search the web"
            && Chrome.localized("Search the web", bundle: chinese) == "搜索网页",
               "Chrome controls can localize within the browser without changing application text")
        expect(Chrome.localized("New browser tab", bundle: chinese) == "新建浏览器标签页",
               "Browser-specific titles use the bundled Chinese catalog")
        let framework = BrowserLocalization.resources.bundleURL
            .appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework/Resources")
        for locale in ["en", "zh_CN"] {
            let pack = framework.appendingPathComponent("\(locale).lproj/locale.pak")
            expect((try? Data(contentsOf: pack).isEmpty) == false, "The built app already carries the supported CEF language pack: \(locale)")
        }

        let searching = BrowserWorkspaceStore(threadID: UUID(), record: .init(pages: [.init(), .init()]))
        let searchPage = searching.selectedPage!, sibling = searching.pages[1]
        searchPage.search("   ", using: .bing)
        expect(searchPage.url == "about:blank" && searchPage.error == nil, "Submitting an empty search keeps the new-tab page")
        searchPage.search(query, using: .baidu)
        expect(URL(string: searchPage.url)?.host == "www.baidu.com" && searching.selectedPage === searchPage && sibling.url == "about:blank",
               "Submitting searches in the same tab without changing siblings or selection")
        searchPage.search(query, using: .duckDuckGo)
        expect(URL(string: searchPage.url)?.host == "duckduckgo.com", "Later searches use the current engine immediately")
        let previous = searchPage.url
        searchPage.search(String(repeating: "中", count: 4_000), using: .google)
        expect(searchPage.url == previous && searchPage.error != nil, "Encoded URL limits preserve the current page and expose a query error")
        expect(searchPage.host == nil && sibling.host == nil && EmbeddedBrowserRuntime.shared.endpoint == nil,
               "Search URL and preference checks do not initialize Chromium")

        let profileRoot = root.appendingPathComponent("profiles", isDirectory: true)
        let activeProfile = BrowserProfileConfiguration.activeProfile
        expect(activeProfile.isDefault && settings.browserProfiles.selectedID == activeProfile.id,
               "New installations use the shared default profile")
        let added = settings.browserProfiles.add(named: "  Work / 工作  ")!
        expect(added.name == "Work / 工作" && settings.browserProfiles.selectedID == added.id,
               "Creating a named blank profile selects it for the next launch")
        expect(AppSettings().browserProfiles == settings.browserProfiles,
               "The profile list and selection persist together")
        expect(BrowserProfileConfiguration.activeProfile == activeProfile,
               "Saving a new selection cannot change the running profile before the first browser starts")
        settings.browserProfiles.select(activeProfile.id)
        expect(AppSettings().browserProfiles.selectedID == activeProfile.id,
               "Selecting an existing profile persists without deleting another profile")
        settings.browserProfiles.select(UUID())
        expect(settings.browserProfiles.selectedID == activeProfile.id,
               "Unknown selections cannot redirect browser storage")
        expect(settings.browserProfiles.add(named: " \n ") == nil,
               "Blank profile names cannot create an unusable selection")
        expect(settings.browserProfiles.add(named: added.name) == nil && settings.browserProfiles.add(named: "  work / 工作  ") == nil,
               "Manual profiles reject trimmed case-insensitive duplicate names")
        defaults.set(Data("broken".utf8), forKey: BrowserProfileConfiguration.preferenceKey)
        expect(AppSettings().browserProfiles.selected.isDefault,
               "Damaged profile preferences recover to the stable default")
        let malformed: [String: Any] = ["profiles": [
            ["id": added.id.uuidString, "name": " Work "],
            ["id": added.id.uuidString, "name": "Duplicate"],
            ["id": UUID().uuidString, "name": "   "]
        ], "selectedID": UUID().uuidString]
        defaults.set(try JSONSerialization.data(withJSONObject: malformed), forKey: BrowserProfileConfiguration.preferenceKey)
        let recovered = AppSettings().browserProfiles
        expect(recovered.profiles.count == 2 && recovered.selected.isDefault,
               "Restore deduplicates identities, rejects empty names and repairs missing selections")
        expect(recovered.pendingDeletionIDs.isEmpty, "Existing profile catalogues decode without the new deletion queue")
        defaults.removeObject(forKey: BrowserProfileConfiguration.preferenceKey)

        settings.browserProfiles = BrowserProfileConfiguration()
        let retired = settings.browserProfiles.add(named: "Remove this profile")!
        let kept = settings.browserProfiles.add(named: "Keep this profile")!
        settings.browserProfiles.select(retired.id)
        let original = settings.browserProfiles
        expect(settings.deleteBrowserProfile(BrowserProfileRecord.defaultProfile.id) == nil && settings.deleteBrowserProfile(UUID()) == nil
            && settings.browserProfiles == original, "Deleting a default or missing profile changes neither catalogue nor selection")
        expect(settings.deleteBrowserProfile(retired.id) == retired && settings.browserProfiles.selected.isDefault,
               "Deleting the selected profile falls back to the default profile")
        expect(settings.browserProfiles.profiles.contains(kept) && !settings.browserProfiles.profiles.contains(retired),
               "Deletion removes only the explicitly confirmed profile")
        expect(AppSettings().browserProfiles.pendingDeletionIDs == [retired.id]
            && BrowserProfileConfiguration.activeProfile == activeProfile,
               "A pending deletion persists without changing the frozen running profile")
        do {
            _ = try settings.browserProfiles.addChromeImport(id: retired.id, sourceName: "Retired identity")
            fatalError("A retired identity must not be reused before cleanup")
        } catch { expect(error is BrowserCookieImportError, "New imports cannot revive a queued profile's old data") }

        let cacheRoot = root.appendingPathComponent("browser/profiles", isDirectory: true)
        func cache(_ record: BrowserProfileRecord) -> URL { cacheRoot.appendingPathComponent("Profile-" + record.storageName, isDirectory: true) }
        for record in [retired, kept, activeProfile] {
            try FileManager.default.createDirectory(at: cache(record), withIntermediateDirectories: true)
            try Data("fixture-only".utf8).write(to: cache(record).appendingPathComponent("Cookies"))
        }
        let outside = root.appendingPathComponent("unrelated-site-data", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("must-survive")
        try Data("unrelated".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: cache(retired).appendingPathComponent("external-link"), withDestinationURL: outside)
        expect(FileManager.default.fileExists(atPath: cache(retired).path), "The delete action leaves all disk data intact until restart cleanup")
        let protected = BrowserProfileCleanup.clean([retired.id, kept.id, activeProfile.id], keeping: [retired.id, kept.id], libraryRoot: root)
        expect(protected.isEmpty && FileManager.default.fileExists(atPath: cache(retired).path),
               "Cleanup never deletes a running or published profile even if queued")
        await settings.cleanDeletedBrowserProfiles()
        expect(!FileManager.default.fileExists(atPath: cache(retired).path)
            && FileManager.default.fileExists(atPath: sentinel.path), "Retired data is removed without following nested links outside the profile")
        expect(FileManager.default.fileExists(atPath: cache(kept).path) && FileManager.default.fileExists(atPath: cache(activeProfile).path),
               "Default and other retained profile data survives cleanup")
        expect(AppSettings().browserProfiles.pendingDeletionIDs.isEmpty, "Only successfully completed deletions leave the persistent queue")

        let linked = settings.browserProfiles.add(named: "Linked profile")!
        _ = settings.deleteBrowserProfile(linked.id)
        try FileManager.default.createSymbolicLink(at: cache(linked), withDestinationURL: outside)
        await settings.cleanDeletedBrowserProfiles()
        expect((try? FileManager.default.attributesOfItem(atPath: cache(linked).path)) == nil
            && FileManager.default.fileExists(atPath: sentinel.path), "A final profile symlink is unlinked without deleting its destination")

        let retry = settings.browserProfiles.add(named: "Retry cleanup")!
        _ = settings.deleteBrowserProfile(retry.id)
        let ownedRoot = cacheRoot.appendingPathExtension("owned")
        try FileManager.default.moveItem(at: cacheRoot, to: ownedRoot)
        try FileManager.default.createSymbolicLink(at: cacheRoot, withDestinationURL: outside)
        await settings.cleanDeletedBrowserProfiles()
        expect(AppSettings().browserProfiles.pendingDeletionIDs.contains(retry.id) && FileManager.default.fileExists(atPath: sentinel.path),
               "Unsafe root substitutions stay queued and never traverse another directory")
        try FileManager.default.removeItem(at: cacheRoot)
        try FileManager.default.moveItem(at: ownedRoot, to: cacheRoot)
        await settings.cleanDeletedBrowserProfiles()
        expect(settings.browserProfiles.pendingDeletionIDs.isEmpty, "A later safe launch can finish an interrupted or already absent deletion")
        settings.browserProfiles = BrowserProfileConfiguration()
        defaults.removeObject(forKey: BrowserProfileConfiguration.preferenceKey)
        let profile = CefProfile.cachePath(for: .persistent(name: activeProfile.storageName), rootCachePath: profileRoot)!
        expect(profile.deletingLastPathComponent() == profileRoot, "Persistent profiles are direct children required by Chromium")
        expect(profile != CefProfile.cachePath(for: .persistent(name: added.storageName), rootCachePath: profileRoot), "Named browser profiles keep distinct storage paths")
        expect(CefProfile.cachePath(for: .persistent(name: "Default"), rootCachePath: profileRoot)?.lastPathComponent != "Default", "Named profiles cannot alias Chromium's default profile")

        let blank = BrowserWorkspaceStore(threadID: UUID(), record: .init(pages: [
            .init(url: "about:blank", title: "about:blank#omp-gui-old-target")
        ])).selectedPage!
        expect(blank.title == BrowserLocalization.localized("New browser tab"), "Blank tabs keep a stable localized title even with old transient metadata")
        let pendingBrowser = CefBrowser(raw: nil, client: nil, delegate: nil)
        blank.model.browser(pendingBrowser, didChangeLoading: true, canGoBack: false, canGoForward: false)
        expect(!blank.isLoading, "Blank-page bootstrap does not flash stop or progress controls")
        blank.navigate("https://example.com")
        expect(blank.isLoading, "User navigation still exposes actual loading state")
        expect(blank.title == "example.com", "A restored bootstrap title cannot reappear when leaving the blank page")

        let firstID = UUID(), secondID = UUID()
        let first = BrowserWorkspaceRegistry.shared.workspace(for: firstID)
        let second = BrowserWorkspaceRegistry.shared.workspace(for: secondID)
        let sharedProfile = EmbeddedBrowserRuntime.shared.browsingProfile()
        expect(sharedProfile === EmbeddedBrowserRuntime.shared.browsingProfile(),
               "Every conversation resolves the same retained runtime profile")
        let url = URL(string: "https://example.com/shared")!
        let a = try first.open(url: url, materialize: false)
        let b = try first.open(url: url, materialize: false)
        let c = try second.open(url: url, materialize: false)
        expect(a.id != b.id && b.id != c.id, "Identical URLs retain separate identities")
        expect(first.selectedPage === b && second.selectedPage === c, "Conversation selection is independent")
        a.navigate("https://example.com/changed")
        expect(b.url == url.absoluteString && c.url == url.absoluteString, "Navigation cannot mutate a sibling or another conversation")
        first.selectedID = a.id
        b.requestClose()
        expect(first.selectedPage === a && second.selectedPage === c, "Closing a background tab preserves both foreground selections")
        expect(a.host == nil && c.host == nil && EmbeddedBrowserRuntime.shared.endpoint == nil, "Metadata checks never start CEF")

        let context = FilePreviewContext(threadID: firstID, workingDirectory: root.path)
        let previews = FilePreviewStore(persistenceURL: root.appendingPathComponent("previews.json"))
        previews.setContext(context)
        previews.openPanel(.browser)
        expect(previews.session?.webBrowser === first, "Sidebar resolves conversation owner")
        previews.openPanel(.files)
        previews.setVisible(false)
        previews.setContext(FilePreviewContext(threadID: secondID, workingDirectory: root.path))
        previews.setContext(context)
        expect(previews.session?.webBrowser.selectedPage === a, "Panel visits, hiding and conversation changes retain page identity")
        let anotherWindow = FilePreviewStore(persistenceURL: root.appendingPathComponent("other-window.json"))
        anotherWindow.setContext(context)
        expect(anotherWindow.session?.webBrowser === first, "Two windows share the same conversation owner")

        let snapshot = try JSONEncoder().encode(first.record)
        let restored = BrowserWorkspaceStore(threadID: firstID, record: try JSONDecoder().decode(BrowserWorkspaceRecord.self, from: snapshot))
        expect(restored.selectedPage?.url == a.url && restored.selectedID == a.id, "Restart restores selected URL and UI identity")
        expect(restored.selectedPage?.targetID == nil && restored.selectedPage?.host == nil, "Restart never restores stale CDP targets or starts pages")
        let invalid = BrowserWorkspaceStore(threadID: UUID(), record: .init(pages: [a.record, a.record], selectedID: UUID()))
        expect(invalid.pages.count == 1 && invalid.selectedID == a.id, "Duplicate persisted IDs are rejected; stale selection falls back")

        for _ in 1..<16 { _ = try restored.open(materialize: false) }
        do { _ = try restored.open(materialize: false); fatalError("Expected tab budget") }
        catch WorkspaceBrowserError.limit { checks += 1 }
        expect(restored.pages.count == 16, "Failed opens preserve existing pages")
        restored.closeAll()
        expect(restored.pages.isEmpty && restored.selectedID == nil, "Explicit close releases all state")
        previews.closeSidebarTab(.panel(.browser))
        expect(first.pages.isEmpty && second.selectedPage === c, "Closing browser panel leaves other conversations alone")
        BrowserWorkspaceRegistry.shared.remove(secondID)
        expect(second.pages.isEmpty, "Deleting conversation releases its pages")
        expect(sharedProfile === EmbeddedBrowserRuntime.shared.browsingProfile(),
               "Closing conversations cannot discard the selected shared profile")
        try checkWebLinks(root: root, expect: expect)
        print("Workspace browser: \(checks) checks passed; CEF and GUI were not started")
    }


    @MainActor private static func checkWebLinks(root: URL, expect: (Bool, String) -> Void) throws {
        let defaults = CaptureRun.defaults!
        defaults.removeObject(forKey: "webLinkDestination")
        let model = AppModel()
        expect(model.settings.webLinkDestination == .embeddedBrowser, "App web links default to the built-in browser")
        for choice in WebLinkDestination.allCases {
            model.settings.webLinkDestination = choice
            expect(AppSettings().webLinkDestination == choice, "Link destination persists independently of browser language and search")
        }
        defaults.set("retired-destination", forKey: "webLinkDestination")
        expect(AppSettings().webLinkDestination == .embeddedBrowser, "Unknown saved link destinations recover to the built-in browser")
        model.settings.webLinkDestination = .embeddedBrowser
        let owner = model.newThread(affiliation: .standalone)!
        let other = model.newThread(affiliation: .standalone)!
        let previews = FilePreviewStore(persistenceURL: root.appendingPathComponent("web-links.json"))
        previews.setContext(FilePreviewContext(threadID: owner.id, workingDirectory: root.path))
        defer {
            previews.suspend()
            for thread in model.threads { BrowserWorkspaceRegistry.shared.remove(thread.id) }
            defaults.removeObject(forKey: "webLinkDestination")
        }
        let url = URL(string: "https://example.com/page?q=中文#section")!
        expect(model.openWebLink(url, previews: previews, materialize: false), "The built-in route consumes HTTP links")
        let state = previews.session!.webBrowser
        let first = state.selectedPage!
        expect(first.url == url.absoluteString && previews.activeSidebarTab == .panel(.browser) && previews.isVisible,
               "A content link opens and reveals a browser tab with its complete URL")
        expect(model.selectedThreadID == other.id && BrowserWorkspaceRegistry.shared.workspace(for: other.id).pages.isEmpty,
               "A link follows its window's conversation instead of the global selection")
        _ = model.openWebLink(url, previews: previews, materialize: false)
        expect(state.pages.count == 2 && state.selectedID != first.id, "Each explicit link activation gets its own tab")
        model.settings.webLinkDestination = .systemBrowser
        expect(!model.openWebLink(url, previews: previews, materialize: false) && state.pages.count == 2,
               "The system-browser choice leaves dispatch to OpenURLAction without creating an embedded page")
        model.settings.webLinkDestination = .embeddedBrowser
        for link in [URL(fileURLWithPath: "/tmp/example.md"), URL(fileURLWithPath: "/tmp/folder", isDirectory: true),
                     URL(string: "/tmp/example.md#L4")!, URL(string: "notes.md:12")!, URL(string: "http:notes.md:12")!,
                     URL(string: "mailto:person@example.com")!, URL(string: "about:blank")!, URL(string: "custom-app://item")!] {
            expect(!link.isHTTPWebLink && !model.openWebLink(link, previews: previews, materialize: false) && state.pages.count == 2,
                   "Only complete HTTP(S) links enter the browser route; files, directories, line references and other schemes are untouched")
        }
        expect(URL(string: "HTTP://localhost:5173/page")!.isHTTPWebLink, "HTTP scheme matching remains case-insensitive")
        let bare = RichLink.build("github.com/xxx")
        expect(bare.runs.contains { $0.link?.absoluteString == "https://github.com/xxx" },
               "Recognized bare web domains are normalized before reaching the browser preference")
        for source in ["README.md", "src/main.swift", "`github.com/xxx`"] {
            expect(!RichLink.build(source).runs.contains { $0.link?.isHTTPWebLink == true },
                   "Filenames, relative source paths and inline code do not become web links")
        }
        let explicitFile = RichLink.build("[File](github.com/xxx)")
        expect(explicitFile.runs.contains { $0.link?.absoluteString == "github.com/xxx" && $0.link?.isHTTPWebLink == false },
               "An explicit relative Markdown destination remains a file reference, even with a domain-shaped folder")
        for _ in state.pages.count..<16 { _ = try state.open(materialize: false) }
        expect(model.openWebLink(url, previews: previews, materialize: false) && state.pages.count == 16 && state.error != nil,
               "A full browser reports its limit without silently opening an external application")
        let empty = FilePreviewStore(persistenceURL: root.appendingPathComponent("web-links-empty.json"))
        defer { empty.suspend() }
        model.selectedThreadID = nil
        let previousCount = model.threads.count
        expect(model.openWebLink(url, previews: empty, materialize: false) && model.threads.count == previousCount + 1,
               "A web link without a conversation gets an independent task to own its browser")

        // Exercise public native link callbacks with a handled URL action. No
        // LaunchServices request, shell, CEF page, visible window or network is needed.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var delivered: [URL] = []
        var environment = EnvironmentValues()
        environment.openURL = OpenURLAction { delivered.append($0); return .handled }
        var localReferences: [FilePreviewReference] = []
        environment.filePreviewAction = FilePreviewAction { reference, _, _ in localReferences.append(reference); return true }
        let native = LinkTextView()
        let paragraph = LinkParagraphView(source: "[Page](https://example.com)")
        let coordinator = paragraph.makeCoordinator()
        paragraph.updateTextView(native, coordinator: coordinator, environment: environment)
        expect(native.onOpenURL != nil, "Native chat links inherit the URL action even outside SwiftUI Text")
        var before = delivered.count
        expect(coordinator.textView(native, clickedOnLink: url, at: 0) && delivered.count == before + 1 && delivered.last == url,
               "Native chat link clicks reach the app's URL route")
        before = delivered.count
        expect(coordinator.textView(native, clickedOnLink: URL(string: "notes.md:12")!, at: 0)
            && localReferences.last?.path == "file:notes.md:12" && delivered.count == before,
               "Native chat file links retain their existing file/line route without consulting the web action")
        let prose = ProseRunRepresentable(blocks: [.paragraph("[Page](https://example.com)")])
        let proseCoordinator = prose.makeCoordinator()
        prose.updateTextView(native, coordinator: proseCoordinator, environment: environment)
        before = delivered.count
        expect(proseCoordinator.textView(native, clickedOnLink: url.absoluteString, at: 0) && delivered.count == before + 1 && delivered.last == url,
               "Grouped chat prose uses the same route for string-valued native links")

        let text = PreviewTextHost()
        let file = root.appendingPathComponent("links.md")
        text.update(url: file, source: url.absoluteString, revision: "links", location: nil,
            state: PreviewReaderState(), wraps: true, findRequest: 0, navigationRequest: 0) { reference, _ in localReferences.append(reference) }
        text.onOpenURL = { delivered.append($0) }
        before = delivered.count
        expect(text.textView(NSTextView(), clickedOnLink: url, at: 0) && delivered.count == before + 1 && delivered.last == url,
               "Source-file web links use the application URL route")
        before = delivered.count
        expect(text.textView(NSTextView(), clickedOnLink: URL(string: "notes.md:12")!, at: 0)
            && localReferences.last?.path == "notes.md:12" && delivered.count == before,
               "Source-file line references never enter the web action")
        text.tearDown()

        let markdown = PreviewMarkdownHost(resourceRoot: BrowserLocalization.resources.resourceURL!.appendingPathComponent("MarkdownPreview"))
        var localLink: FilePreviewReference?
        markdown.update(url: file, source: "# Links", revision: "links", state: PreviewReaderState(), findRequest: 0) { reference, _ in localLink = reference }
        markdown.onOpenURL = { delivered.append($0) }
        before = delivered.count
        markdown.open(url.absoluteString)
        expect(delivered.count == before + 1 && delivered.last == url, "Rendered Markdown web links reach the same URL route")
        markdown.open("./sibling.md#L2")
        expect(localLink?.path == "file:./sibling.md#L2" && delivered.count == before + 1,
               "Markdown file links retain local preview routing without entering the web action")
        markdown.tearDown()

        let pdf = PreviewPDFHost()
        pdf.onOpenURL = { delivered.append($0) }
        before = delivered.count
        pdf.pdfViewWillClick(onLink: PDFView(), with: url)
        expect(delivered.count == before + 1 && delivered.last == url, "PDF links use the application route through PDFKit's public delegate")
        pdf.tearDown()
        let terminal = TerminalSession(threadID: owner.id, directory: root.path, title: "Links", command: nil, startsProcess: false)
        terminal.view.onOpenURL = { delivered.append($0) }
        before = delivered.count
        terminal.view.requestOpenLink(source: terminal.view, link: url.absoluteString, params: [:])
        expect(delivered.count == before + 1 && delivered.last == url && !terminal.isRunning, "Terminal links follow the app route without starting a shell")
        expect(EmbeddedBrowserRuntime.shared.endpoint == nil, "Functional link routing never starts Chromium")
    }
}
