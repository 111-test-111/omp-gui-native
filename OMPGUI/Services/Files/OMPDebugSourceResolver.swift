import Foundation

enum OMPDebugSourceResolver {
    /// Debuggee cwd wins over the conversation directory. DAP virtual sources
    /// and LLDB's library`symbol names must never create nonexistent file tabs.
    @concurrent static func resolve(_ source: OMPDebugSource, cwd: String?, directory: String) async -> FilePreviewReference? {
        guard !Task.isCancelled, (source.sourceReference ?? 0) == 0,
              let path = source.path, !path.isEmpty,
              let target = try? FilePreviewResolver.resolve(FilePreviewReference(path: path, line: source.line, column: source.column),
                                                           relativeTo: cwd ?? directory),
              let values = try? target.url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true, !Task.isCancelled else { return nil }
        return FilePreviewReference(path: target.url.path, line: target.location?.line, column: target.location?.column)
    }
}
