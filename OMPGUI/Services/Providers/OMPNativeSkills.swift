import Foundation

/// OMP owns discovery, source opt-ins, exclusions and name resolution. Settings
/// only projects its public CLI inventory, independently of a conversation.
@MainActor
@Observable
final class OMPNativeSkills {
    private(set) var skills: [OMPGlobalSkill] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    @ObservationIgnored private var context: OMPDiscoveryContext?
    @ObservationIgnored private var generation = UUID()

    nonisolated static func inventory(_ value: JSONValue) throws -> [OMPGlobalSkill] {
        guard let rows = value["skills"]?.array else {
            throw ProviderError.failed(AppText.localized("OMP returned invalid JSON."))
        }
        var paths: Set<String> = []
        return rows.compactMap { row -> OMPGlobalSkill? in
            guard let source = row["source"]?.string,
                  source.split(separator: ":", omittingEmptySubsequences: false).count == 2,
                  source.hasSuffix(":user"),
                  let name = row["name"]?.string, !name.isEmpty,
                  let path = row["filePath"]?.string, path.hasPrefix("/"),
                  !path.contains("\0"), (path as NSString).lastPathComponent == "SKILL.md" else { return nil }
            let normalized = (path as NSString).standardizingPath
            guard paths.insert(normalized).inserted else { return nil }
            return OMPGlobalSkill(name: name, description: row["description"]?.string ?? "",
                                  filePath: normalized, source: source)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.filePath < $1.filePath : order == .orderedAscending
        }
    }

    @concurrent static func list(executable: URL, environment: [String: String]) async throws -> [OMPGlobalSkill] {
        // Never inspect the selected project: it can shadow a global skill before
        // the CLI emits its resolved inventory. No session or model is started.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omp-gui-skills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await Shell.run(executable, ["skill", "list", directory.path, "--json"], in: directory,
            environment: OMPCLI.profileConfigurationEnvironment(environment), timeout: 30, outputLimit: 4 * 1024 * 1024)
        guard result.succeeded else { throw ProviderError.failed(result.failureMessage) }
        guard let value = JSONValue.parse(result.stdout) else {
            throw ProviderError.failed(AppText.localized("OMP returned invalid JSON."))
        }
        return try inventory(value)
    }

    func refresh(_ next: OMPDiscoveryContext?) async {
        guard let next else {
            generation = UUID()
            context = nil
            skills = []
            hasLoaded = false
            isLoading = false
            error = ProviderError.notInstalled(.omp).localizedDescription
            return
        }
        guard !isLoading || context != next else { return }
        if context != next { skills = []; hasLoaded = false }
        context = next
        let expected = UUID()
        generation = expected
        isLoading = true
        error = nil
        defer { if generation == expected { isLoading = false } }
        do {
            let value = try await Self.list(executable: next.executable, environment: next.environment)
            try Task.checkCancellation()
            guard generation == expected else { return }
            skills = value
            hasLoaded = true
        } catch is CancellationError {
            // A closed page or replaced profile cannot publish a late result.
        } catch {
            guard generation == expected else { return }
            self.error = error.localizedDescription
        }
    }
}
