import Foundation
import Observation

enum OMPProviderUsageReader {
    private final class ResourceBundle: NSObject {}
    static var extensionURL: URL? { Bundle(for: ResourceBundle.self).url(forResource: "OMPProviderUsage", withExtension: "js") }
    @concurrent static func profile(_ context: OMPDiscoveryContext) async throws -> URL {
        let result = try await Shell.run(context.executable, ["config", "path"],
                                         in: FileManager.default.temporaryDirectory, environment: context.environment,
                                         timeout: 15, outputLimit: 8_192)
        let path = result.trimmedOutput
        guard result.succeeded, path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0") else { throw ReadError.unavailable }
        return URL(fileURLWithPath: path)
    }

    @concurrent static func read(_ context: OMPDiscoveryContext, extensionURL: URL? = OMPProviderUsageReader.extensionURL) async throws -> OMPProviderUsage {
        let native = context.executable.resolvingSymlinksInPath()
        let usesSDK = native.lastPathComponent == "cli.js" && native.deletingLastPathComponent().lastPathComponent == "dist"
            && LoginEnvironment.which("bun", in: context.environment) != nil
        async let balances = supplementaryBalances(context, enabled: usesSDK)
        var arguments = ["usage", "--json"]
        // The SDK path follows OMP's model-config key precedence; standalone can use its extension loader.
        if !usesSDK, let extensionURL { arguments += ["--extension", extensionURL.path] }
        let result = try await Shell.run(context.executable, arguments,
                                         in: FileManager.default.temporaryDirectory, environment: context.environment,
                                         timeout: 45, outputLimit: 3 * 1_024 * 1_024)
        try Task.checkCancellation()
        guard result.succeeded, let json = JSONValue.parse(result.stdout), case .object(var fields) = json,
              let reports = fields["reports"]?.array else { throw ReadError.unavailable }
        let additional = await balances
        // An external active-profile change cannot relabel one account's report as another's.
        guard try await profile(context) == context.directory else { throw ReadError.profileChanged }
        if !additional.isEmpty { fields["reports"] = .array(reports + additional) }
        return try OMPProviderUsage.decode(.object(fields))
    }

    private static func supplementaryBalances(_ context: OMPDiscoveryContext, enabled: Bool) async -> [JSONValue] {
        guard enabled, let directory = context.directory else { return [] }
        do {
            let value = try await OMPModelConfiguration.request(["action": "balances", "directory": .string(directory.path)], context: context)
            guard !Task.isCancelled, value["directory"]?.string == directory.path else { return [] }
            return Array((value["reports"]?.array ?? []).prefix(8))
        } catch { return [] }
    }

    enum ReadError: Error { case unavailable, profileChanged }
}

/// A shared, memory-only cache. Only visible provider settings acquire read leases.
/// Leaving the last settings view cancels its native subprocess; there is no background polling.
@MainActor
@Observable
final class OMPProviderUsageStore {
    typealias Profile = @MainActor (OMPDiscoveryContext) async throws -> URL
    typealias Reader = @MainActor (OMPDiscoveryContext) async throws -> OMPProviderUsage
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var context: OMPDiscoveryContext?
    private var cached: OMPProviderUsage?
    private var validated = false
    var snapshot: OMPProviderUsage? { validated ? cached : nil }
    @ObservationIgnored private unowned let registry: ProviderRegistry
    @ObservationIgnored private let profile: Profile
    @ObservationIgnored private let read: Reader
    @ObservationIgnored private var consumers: Set<UUID> = []
    @ObservationIgnored private var loadedAt: ContinuousClock.Instant?
    @ObservationIgnored private var lastAttempt: ContinuousClock.Instant?
    @ObservationIgnored private var flight: (id: UUID, task: Task<Void, Never>)?

    init(registry: ProviderRegistry,
         profile: @escaping Profile = { try await OMPProviderUsageReader.profile($0) },
         read: @escaping Reader = { try await OMPProviderUsageReader.read($0) }) {
        self.registry = registry
        self.profile = profile
        self.read = read
    }

    func begin(_ consumer: UUID) async {
        if consumers.isEmpty { validated = false }
        consumers.insert(consumer)
        await refresh()
    }

    func end(_ consumer: UUID) {
        consumers.remove(consumer)
        guard consumers.isEmpty else { return }
        flight?.task.cancel()
        flight = nil
        isLoading = false
        validated = false
    }

    func invalidate() {
        flight?.task.cancel()
        flight = nil
        cached = nil
        loadedAt = nil
        lastAttempt = nil
        validated = false
        isLoading = false
        error = nil
    }

    func refresh(force: Bool = false) async {
        guard !consumers.isEmpty else { return }
        await LoginEnvironment.load()
        guard !Task.isCancelled, !consumers.isEmpty else { return }
        guard let executable = registry.executable(for: .omp) else {
            cached = nil; error = AppText.localized("OMP is unavailable. Usage could not be read."); return
        }
        let environment = OMPCLI.profileConfigurationEnvironment(registry.environment(for: .omp))
        var requested = OMPDiscoveryContext(executable: executable, environment: environment)
        do { requested.directory = try await profile(requested) }
        catch {
            guard !Task.isCancelled, !consumers.isEmpty else { return }
            validated = false
            self.error = AppText.localized("OMP usage is unavailable. Try refreshing again.")
            return
        }
        guard !Task.isCancelled, !consumers.isEmpty,
              registry.executable(for: .omp) == executable,
              OMPCLI.profileConfigurationEnvironment(registry.environment(for: .omp)) == environment else { return }
        if context != requested {
            flight?.task.cancel(); flight = nil
            context = requested
            cached = nil; loadedAt = nil; lastAttempt = nil; error = nil
        }
        validated = true
        if let flight { await flight.task.value; return }
        if !force, let loadedAt, loadedAt.duration(to: .now) < .seconds(60) { return }
        if !force, error != nil, let lastAttempt, lastAttempt.duration(to: .now) < .seconds(10) { return }
        let id = UUID(), expected = requested
        isLoading = true
        lastAttempt = .now
        flight = (id, Task { [self] in
            defer {
                if flight?.id == id { flight = nil; isLoading = false }
            }
            do {
                let result = try await read(expected)
                guard !Task.isCancelled, flight?.id == id, context == expected, !consumers.isEmpty,
                      registry.executable(for: .omp) == expected.executable,
                      OMPCLI.profileConfigurationEnvironment(registry.environment(for: .omp)) == expected.environment else { return }
                cached = result
                loadedAt = .now
                error = nil
            } catch {
                guard !Task.isCancelled, flight?.id == id else { return }
                if case OMPProviderUsageReader.ReadError.profileChanged = error {
                    validated = false; cached = nil
                }
                self.error = AppText.localized("OMP usage is unavailable. Try refreshing again.")
            }
        })
        await flight?.task.value
    }
}
