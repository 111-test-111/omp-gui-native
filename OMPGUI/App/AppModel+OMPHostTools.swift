import AppKit
import Foundation

extension AppModel {
    func handleOMPHostTool(_ request: OMPHostToolRequest, threadID: UUID) async throws -> JSONValue {
        try Task.checkCancellation()
        if request.name == "gui_browser" { return try await handleBrowserHostTool(request, threadID: threadID) }
        let runtime = runtime(for: threadID)
        if request.name == "gui_read_selected_context" {
            guard let selected = runtime.explicitFileContext else { throw OMPHostToolError.noSelection }
            return .object(["content": .array([.object(["type": "text", "text": .string(selected.promptText)])]),
                            "details": .object(["path": .string(selected.path), "worktree": .string(selected.source.workingDirectory),
                                "line": selected.startLine.map(JSONValue.int) ?? .null,
                                "endLine": selected.endLine.map(JSONValue.int) ?? .null])])
        }
        guard request.name == "gui_open_file_location", let thread = thread(threadID),
              let project = executionProject(for: thread), let path = request.arguments["path"]?.string,
              !path.isEmpty, FilePreviewResolver.isLocalReference(path) else { throw OMPHostToolError.invalidLocation }
        let ownDirectory = thread.executionDirectory(projectPath: project.path)
        let explicit = runtime.explicitFileContext
        let source = explicit?.source ?? FilePreviewContext(threadID: threadID, workingDirectory: ownDirectory)
        let line = request.arguments["line"]?.int
        let column = request.arguments["column"]?.int
        guard (request.arguments["line"] == nil || line.map { $0 > 0 } == true),
              (request.arguments["column"] == nil || column.map { $0 > 0 } == true) else { throw OMPHostToolError.invalidLocation }
        let target = try await Task.detached(priority: .userInitiated) {
            try FilePreviewResolver.resolve(FilePreviewReference(path: path, line: line, column: column), relativeTo: source.workingDirectory)
        }.value
        try Task.checkCancellation()
        let allowed = [FilePreviewContext(threadID: threadID, workingDirectory: ownDirectory), explicit?.source]
            .compactMap { $0 }.map { context in
                FilePreviewContext(threadID: context.threadID, workingDirectory:
                    URL(fileURLWithPath: context.workingDirectory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path)
            }.sorted { $0.workingDirectory.count > $1.workingDirectory.count }
        guard let selectedSource = allowed.first(where: {
            target.url.path == $0.workingDirectory || target.url.path.hasPrefix($0.workingDirectory.hasSuffix("/") ? $0.workingDirectory : $0.workingDirectory + "/")
        }) else {
            throw OMPHostToolError.invalidLocation
        }
        let previews = NSApp.windows.compactMap { ($0 as? ThreadWindow)?.filePreviews }
            .first { $0.context?.threadID == threadID }
        guard let previews else { throw OMPHostToolError.unavailablePreview }
        // Resolution is cancellable before the visible UI action, and context
        // carries its worktree rather than following a later selected chat.
        guard previews.open(FilePreviewReference(path: target.url.path, line: target.location?.line, column: target.location?.column), context: selectedSource) else {
            throw OMPHostToolError.unavailablePreview
        }
        return .object(["content": .array([.object(["type": "text", "text": .string(target.url.path + (target.location.map { "#L\($0.line)" } ?? ""))])])])
    }
}
