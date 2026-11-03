import AppKit
import Observation

@MainActor @Observable
final class BrowserHistoryStore {
    static let shared = BrowserHistoryStore()
    private(set) var recent: [BrowserHistoryEntry] = []
    private(set) var revision = 0
    private(set) var errorKey: String?
    @ObservationIgnored private let database: BrowserHistoryDatabase
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let iconLoader: @MainActor (String) async -> NSImage?

    init(url: URL = StoragePaths.root.appendingPathComponent("browser/history.sqlite"),
         iconLoader: @escaping @MainActor (String) async -> NSImage? = BrowserHistoryIconLoader.image) {
        database = BrowserHistoryDatabase(url: url)
        self.iconLoader = iconLoader
    }

    func record(_ visit: BrowserHistoryVisit) {
        enqueue { try await $0.record(visit) }
    }

    func updateTitle(_ title: String, visitID: UUID) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !title.isEmpty else { return }
        enqueue { try await $0.updateTitle(title, visitID: visitID) }
    }

    func updateIcon(_ image: NSImage, visitID: UUID) {
        guard let icon = BrowserHistoryIconCodec.encode(image) else { return }
        updateIcon(icon, visitID: visitID)
    }

    func updateIcon(_ icon: BrowserHistoryIcon, visitID: UUID) {
        enqueue { try await $0.updateIcon(icon, visitID: visitID) }
    }

    func icon(for entry: BrowserHistoryEntry) async -> NSImage? {
        if let icon = entry.icon, let image = BrowserHistoryIconCodec.decode(icon) { return image }
        guard !Task.isCancelled, let image = await iconLoader(entry.url), !Task.isCancelled else { return nil }
        if let icon = BrowserHistoryIconCodec.encode(image) {
            enqueue { try await $0.updateIcon(icon, entryID: entry.id) }
        }
        return image
    }

    func clearRecent() { enqueue { try await $0.clearRecent() } }
    func remove(_ id: Int64) { enqueue { try await $0.remove(id) } }
    func clear(_ range: BrowserHistoryRange, now: Date = .now, source: BrowserHistorySource = .all) {
        let since = range.start(now: now)
        enqueue { try await $0.clear(since: since, through: now, source: source) }
    }

    func loadRecent() async {
        enqueue { _ in }
        await flush()
    }

    func page(before cursor: BrowserHistoryCursor?, source: BrowserHistorySource = .all) async throws -> BrowserHistoryPage {
        await flush()
        try Task.checkCancellation()
        return try await database.page(before: cursor, source: source)
    }

    func previewImport(_ content: ChromeHistoryImport) async throws -> ChromeHistoryImportPreview {
        await flush()
        try Task.checkCancellation()
        return try await database.previewImport(content)
    }

    func commitImport(_ preview: ChromeHistoryImportPreview) async throws -> ChromeHistoryImportSummary {
        let previous = pending
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            let result = try await database.commitImport(preview)
            // The commit is final even if cancellation arrives immediately after it.
            do { recent = try await database.recent(); errorKey = nil }
            catch { errorKey = "Browser history could not be saved or loaded. Try again." }
            revision &+= 1
            return result
        }
        pending = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func resetImportExclusions(sourceID: String) async throws {
        await flush()
        try await database.resetImportExclusions(sourceID: sourceID)
        revision &+= 1
    }

    func flush() async { await pending?.value }

    private func enqueue(_ operation: @escaping @Sendable (BrowserHistoryDatabase) async throws -> Void) {
        let previous = pending
        pending = Task { [weak self, database] in
            // Preserve navigation/title/clear order across actor suspension.
            await previous?.value
            do {
                try await operation(database)
                let recent = try await database.recent()
                guard let self else { return }
                self.recent = recent
                errorKey = nil
                revision &+= 1
            } catch {
                self?.errorKey = "Browser history could not be saved or loaded. Try again."
            }
        }
    }
}

@MainActor @Observable
final class BrowserHistoryListStore {
    private(set) var page = BrowserHistoryPage()
    private(set) var isLoading = false
    private(set) var errorKey: String?
    private(set) var cursors: [BrowserHistoryCursor] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var layout: BrowserHistoryPageLayout?
    @ObservationIgnored private var source = BrowserHistorySource.all
    var number: Int { cursors.count + 1 }
    var canClear: Bool { !isLoading && errorKey == nil && !page.entries.isEmpty }

    func older() {
        guard !isLoading, page.hasMore, let cursor = page.entries.last?.cursor else { return }
        isLoading = true
        cursors.append(cursor)
    }

    func newer() {
        guard !isLoading, !cursors.isEmpty else { return }
        isLoading = true
        cursors.removeLast()
    }
    func reset() { cursors.removeAll() }

    func refresh(history: BrowserHistoryStore, layout: BrowserHistoryPageLayout = .init(), source: BrowserHistorySource = .all) async {
        if self.source != source || self.layout.map({ $0 != layout }) == true { reset() }
        self.source = source
        self.layout = layout
        generation &+= 1
        let request = generation
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            var result = try await history.page(before: cursors.last, source: source)
            guard !Task.isCancelled, request == generation else { return }
            if result.entries.isEmpty, !cursors.isEmpty {
                // Deletions can empty the last page, including from another window.
                // Return to the newest page so cleanup never relies on stale cursors.
                reset()
                result = try await history.page(before: nil, source: source)
            }
            guard !Task.isCancelled, request == generation else { return }
            page = layout.fitting(result)
            errorKey = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, request == generation else { return }
            errorKey = "Browser history could not be saved or loaded. Try again."
        }
    }
}
