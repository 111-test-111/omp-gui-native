import AppKit
import Observation

@MainActor @Observable
final class ChromeHistoryImportStore {
    var selectedID: String? { didSet { if selectedID != oldValue { preview = nil; result = nil } } }
    var range: BrowserHistoryRange = .all { didSet { if range != oldValue { preview = nil; result = nil } } }
    private(set) var profiles: [ChromeSourceProfile] = []
    private(set) var preview: ChromeHistoryImportPreview?
    private(set) var result: ChromeHistoryImportSummary?
    private(set) var isBusy = false
    private(set) var isCommitting = false
    private(set) var errorKey: String?
    private(set) var permissionDenied = false
    @ObservationIgnored private let history: BrowserHistoryStore
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    var selectedProfile: ChromeSourceProfile? { profiles.first { $0.id == selectedID } }

    init(history: BrowserHistoryStore, root: URL = ChromeSourceDatabase.defaultRoot) {
        self.history = history
        self.root = root
    }

    func discover() {
        run {
            let root = self.root
            let work = Task.detached(priority: .userInitiated) { try ChromeHistorySource.profiles(root: root) }
            let profiles = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            self.profiles = profiles
            self.selectedID = profiles.first?.id
        }
    }

    func prepare() {
        guard let profile = selectedProfile, !isBusy else { return }
        let range = range
        preview = nil
        result = nil
        run {
            let work = Task.detached(priority: .userInitiated) { try ChromeHistorySource.read(profile, range: range) }
            var read = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            for (index, pair) in read.iconData.enumerated() {
                try Task.checkCancellation()
                if let image = BrowserHistoryIconCodec.downloaded(pair.value),
                   let icon = BrowserHistoryIconCodec.encode(image) { read.content.icons[pair.key] = icon }
                if index.isMultiple(of: 8) { await Task.yield() }
            }
            let preview = try await self.history.previewImport(read.content)
            try Task.checkCancellation()
            self.preview = preview
        }
    }

    func commit(onComplete: @escaping @MainActor () -> Void = {}) {
        guard let preview, !isBusy, preview.summary.added > 0 else { return }
        run(committing: true) {
            self.result = try await self.history.commitImport(preview)
            self.preview = nil
            onComplete()
        }
    }

    func resetExclusions() {
        guard let profile = selectedProfile, !isBusy else { return }
        preview = nil
        result = nil
        run { try await self.history.resetImportExclusions(sourceID: profile.historySourceID) }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isBusy = false
        isCommitting = false
    }

    func waitForOperation() async { await task?.value }

    private func run(committing: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        generation &+= 1
        let request = generation
        isBusy = true
        isCommitting = committing
        errorKey = nil
        permissionDenied = false
        task = Task {
            defer {
                if request == generation { isBusy = false; isCommitting = false }
            }
            do { try Task.checkCancellation(); try await operation() }
            catch is CancellationError { }
            catch {
                guard request == generation else { return }
                let failure: ChromeHistoryImportError
                if let error = error as? ChromeSourceError {
                    failure = .source(error)
                    permissionDenied = error == .permissionDenied
                } else { failure = (error as? ChromeHistoryImportError) ?? .storage }
                errorKey = failure.messageKey
                preview = nil
            }
        }
    }
}
