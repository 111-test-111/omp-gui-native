import AppKit
import Foundation

extension AppModel {
    /// True consumes a web link in this window. False leaves system dispatch to
    /// OpenURLAction, preserving non-web links and the user's external choice.
    @discardableResult
    func openWebLink(_ url: URL, previews: FilePreviewStore, materialize: Bool = true) -> Bool {
        guard url.isHTTPWebLink,
              settings.webLinkDestination == .embeddedBrowser else { return false }
        if previews.context == nil {
            guard let thread = selectedThread ?? newThread(affiliation: .standalone),
                  let project = executionProject(for: thread) else { return false }
            previews.setContext(FilePreviewContext(threadID: thread.id,
                workingDirectory: thread.executionDirectory(projectPath: project.path)))
        }
        guard let state = previews.session?.webBrowser else { return false }
        do { _ = try state.open(url: url, materialize: materialize) }
        catch { state.error = error.localizedDescription }
        // A full tab budget or runtime failure stays visible in the requested
        // browser rather than silently sending the URL to another application.
        previews.openPanel(.browser)
        SettingsNavigation.shared.dismiss()
        return true
    }

    func handleBrowserHostTool(_ request: OMPHostToolRequest, threadID: UUID) async throws -> JSONValue {
        guard thread(threadID) != nil else { throw WorkspaceBrowserError.closed }
        try Task.checkCancellation()
        let state = BrowserWorkspaceRegistry.shared.workspace(for: threadID)
        let previews = NSApp.windows.compactMap { ($0 as? ThreadWindow)?.filePreviews }
            .first { $0.context?.threadID == threadID }
        let result: JSONValue
        switch request.arguments["action"]?.string {
        case "list":
            result = .object(["tabs": .array(state.pages.map { page in
                .object(["id": .string(page.id.uuidString), "url": .string(page.url), "title": .string(page.title),
                         "selected": .bool(page.id == state.selectedID), "hasDialog": .bool(page.dialog != nil)])
            })])
        case "open":
            guard let url = BrowserAddress.resolve(request.arguments["url"]?.string ?? "about:blank") else { throw WorkspaceBrowserError.invalidAddress }
            let page = try state.open(url: url)
            previews?.openPanel(.browser)
            result = try await page.attachment()
        case "attach", "select", "close":
            guard let rawID = request.arguments["id"]?.string, let id = UUID(uuidString: rawID),
                  let page = state.pages.first(where: { $0.id == id }) else { throw WorkspaceBrowserError.closed }
            if request.arguments["action"]?.string == "close" {
                page.requestClose()
                result = .object(["id": .string(id.uuidString), "closeRequested": true,
                    "instruction": "If beforeunload is pending, answer the page dialog with the existing native Browser handle. List again to confirm closure."])
            } else {
                if request.arguments["action"]?.string == "select" { state.selectedID = id; previews?.openPanel(.browser) }
                result = try await page.attachment()
            }
        default: throw WorkspaceBrowserError.invalidAddress
        }
        try Task.checkCancellation()
        return .object(["content": .array([.object(["type": "text", "text": .string(result.compactString)])]), "details": result])
    }
}
