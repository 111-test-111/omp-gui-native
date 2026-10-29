import Foundation
import Observation

/// Settings can be recreated without repeating native discovery. Keep only the
/// current conversation's global file metadata, never memory contents on disk.
@MainActor @Observable
final class MemoryFileCache {
    struct Context: Equatable {
        let threadID: UUID
        let configuration: OMPMemoryConfiguration
    }

    private(set) var files: [OMPMemoryFile] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var generation = UUID()

    func invalidate() {
        generation = UUID()
        context = nil
        files = []
        hasLoaded = false
        isLoading = false
        error = nil
    }

    func load(for context: Context, refresh: Bool = false,
              read: @MainActor () async throws -> OMPMemoryInspection) async {
        guard context.configuration.enabled else { invalidate(); return }
        if self.context != context { invalidate(); self.context = context }
        guard !isLoading, refresh || !hasLoaded else { return }
        let expected = UUID()
        generation = expected
        isLoading = true
        defer { if generation == expected { isLoading = false } }
        do {
            let inspection = try await read()
            guard generation == expected, self.context == context else { return }
            files = inspection.files.filter(\.isGlobal)
            hasLoaded = true
            error = nil
        } catch {
            guard generation == expected, self.context == context else { return }
            self.error = error.localizedDescription
        }
    }
}
