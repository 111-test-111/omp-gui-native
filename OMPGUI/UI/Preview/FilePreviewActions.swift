import Foundation
import SwiftUI

/// A local file action supplied by the window. The callback queues the read;
/// accepting a reference does not mean that the file already exists.
struct FilePreviewAction: Equatable {
    private let identity: UUID
    private let handler: @MainActor (FilePreviewReference, FilePreviewContext?, Bool) -> Bool

    init() {
        identity = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        handler = { _, _, _ in false }
    }

    init(identity: UUID = UUID(), _ handler: @escaping @MainActor (FilePreviewReference, FilePreviewContext?, Bool) -> Bool) {
        self.identity = identity
        self.handler = handler
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    @MainActor @discardableResult
    func callAsFunction(_ reference: FilePreviewReference, context: FilePreviewContext? = nil, pinned: Bool = false) -> Bool {
        handler(reference, context, pinned)
    }

    /// A URL has already distinguished a link scheme from a filesystem name.
    /// Preserve external application links instead of treating them as filenames.
    nonisolated static func isFileReference(_ url: URL) -> Bool {
        let bareLocation = url.absoluteString.range(of: #"^[^/]+\.[^:]+:[1-9][0-9]*(?::[1-9][0-9]*|-[1-9][0-9]*)?$"#, options: .regularExpression) != nil
        return url.isFileURL || url.scheme == nil || bareLocation
    }

    @MainActor @discardableResult
    func callAsFunction(_ url: URL, context: FilePreviewContext? = nil, pinned: Bool = false) -> Bool {
        guard Self.isFileReference(url) else { return false }
        // Keep parsed-URL escaping distinct from a raw OMP filename. In a
        // folder containing both "a b" and "a%20b", a link to a%20b means a b.
        let reference = url.isFileURL ? url.absoluteString : "file:" + url.absoluteString
        return handler(FilePreviewReference(path: reference), context, pinned)
    }
}

struct FilePreviewToggleAction: Equatable {
    private let identity: UUID
    private let handler: @MainActor () -> Void

    init() {
        identity = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        handler = {}
    }

    init(identity: UUID, _ handler: @escaping @MainActor () -> Void) {
        self.identity = identity
        self.handler = handler
    }

    @MainActor func callAsFunction() { handler() }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}

/// Routes a turn's Review action to the sidebar owned by the same chat window.
struct WorkspaceReviewAction: Equatable {
    private let identity: UUID
    private let handler: @MainActor (UUID, UUID?) -> Bool

    init() {
        identity = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        handler = { _, _ in false }
    }

    init(identity: UUID, _ handler: @escaping @MainActor (UUID, UUID?) -> Bool) {
        self.identity = identity
        self.handler = handler
    }

    @MainActor @discardableResult
    func callAsFunction(threadID: UUID, turnID: UUID?) -> Bool { handler(threadID, turnID) }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}

/// Opens or closes this window's sidebar terminal tab without changing shells.
struct WorkspaceTerminalAction: Equatable {
    private let identity: UUID
    private let handler: (@MainActor (UUID, Bool) -> Bool)?

    init() {
        identity = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        handler = nil
    }

    init(identity: UUID, _ handler: @escaping @MainActor (UUID, Bool) -> Bool) {
        self.identity = identity
        self.handler = handler
    }

    var isAvailable: Bool { handler != nil }
    @MainActor @discardableResult
    func callAsFunction(threadID: UUID, isOpen: Bool) -> Bool { handler?(threadID, isOpen) ?? false }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}

extension EnvironmentValues {
    @Entry var workspaceTerminalAction = WorkspaceTerminalAction()
    @Entry var workspaceReviewAction = WorkspaceReviewAction()
    @Entry var filePreviewAction = FilePreviewAction()
    @Entry var filePreviewContext: FilePreviewContext? = nil
    @Entry var filePreviewToggle = FilePreviewToggleAction()
    @Entry var filePreviewIsVisible = false
}
