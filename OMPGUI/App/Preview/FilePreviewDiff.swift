import Observation
import SwiftUI

struct FilePreviewDiffRequest: Hashable, Sendable {
    let url: URL
    let context: FilePreviewContext
    let revision: String
    let showsDiff: Bool
}

/// One visible preview owns this state. The view's task cancels Git reads on
/// request changes; generations also reject late, non-cooperative completions.
@MainActor @Observable
final class FilePreviewDiffState {
    typealias Locator = @Sendable (URL, String) async throws -> PreviewFileDiffLocation?
    typealias Loader = @Sendable (PreviewFileDiffLocation) async throws -> PreviewFileDiffResult

    private(set) var request: FilePreviewDiffRequest?
    private(set) var location: PreviewFileDiffLocation?
    private(set) var result: PreviewFileDiffResult?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var refreshRevision = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchers: [PreviewFileWatch] = []
    @ObservationIgnored private let locator: Locator
    @ObservationIgnored private let loader: Loader

    init(locator: @escaping Locator = { try await PreviewFileDiff.locate($0, workingDirectory: $1) },
         loader: @escaping Loader = { try await PreviewFileDiff.load($0) }) {
        self.locator = locator
        self.loader = loader
    }

    isolated deinit { for watcher in watchers { watcher.stop() } }

    func update(_ next: FilePreviewDiffRequest?) async {
        let sameFile = request?.url == next?.url && request?.context == next?.context
        let previousLocation = sameFile ? location : nil
        suspend()
        let token = generation
        request = next
        location = previousLocation
        guard let next else { return }
        isLoading = next.showsDiff
        do {
            let located = try await locator(next.url, next.context.workingDirectory)
            guard !Task.isCancelled, generation == token else { return }
            location = located
            guard next.showsDiff, let located else { isLoading = false; return }
            // Install before loading so an index/HEAD change during the read
            // schedules another request rather than leaving a stale result.
            let metadata = try await PreviewFileDiff.metadataWatches(located)
            guard !Task.isCancelled, generation == token else { return }
            watchers = metadata.map { entry in
                PreviewFileWatch(url: entry.url, expectedRevision: entry.revision) { [weak self] in self?.refreshRevision &+= 1 }
            }
            let loaded = try await loader(located)
            guard !Task.isCancelled, generation == token else { return }
            result = loaded
            isLoading = false
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func suspend() {
        generation &+= 1
        for watcher in watchers { watcher.stop() }
        watchers.removeAll()
        isLoading = false
        request = nil
        location = nil
        result = nil
        error = nil
    }
}

struct FilePreviewDiffView: View {
    let state: FilePreviewDiffState

    var body: some View {
        Group {
            if let error = state.error {
                Text(verbatim: error).textSelection(.enabled).padding(16)
            } else if let result = state.result {
                switch result {
                case .unchanged:
                    Text("No uncommitted changes in this file")
                        .foregroundStyle(Chrome.secondaryText).padding(16)
                case .ignored:
                    Text("This file is ignored by Git")
                        .foregroundStyle(Chrome.secondaryText).padding(16)
                case .changed(let file):
                    VStack(spacing: 0) {
                        HStack {
                            Text("Uncommitted changes").foregroundStyle(Chrome.secondaryText)
                            Spacer(minLength: 8)
                            DiffStatLabel(additions: file.additions, deletions: file.deletions)
                        }
                        .font(.ui(.caption)).padding(.horizontal, 12).padding(.vertical, 6)
                        ScrollView {
                            if file.isDeferred {
                                DeferredDiffLinesView(file: file, collapsesLongDiff: false)
                                    .id(file.revision)
                            } else if file.isBinary || file.hunks.isEmpty {
                                Text(verbatim: Chrome.localized(file.isBinary ? "Binary file" : "No text changes"))
                                    .foregroundStyle(Chrome.secondaryText).padding(12)
                            } else {
                                DiffLinesView(file: file, collapsesLongDiff: false).equatable()
                                    .padding(.bottom, 8)
                            }
                        }
                    }
                }
            } else if state.isLoading {
                Text("Loading diff…").foregroundStyle(Chrome.secondaryText).padding(16)
            } else {
                Color.clear
            }
        }
        .font(.ui(.callout))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
