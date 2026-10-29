import Foundation

struct ProviderStatus: Equatable, Sendable {
    enum Auth: Equatable, Sendable { case unknown, signedIn(String?), signedOut }
    var executable: URL?
    var version: String?
    var auth: Auth = .unknown
    var isChecking = false
    var apiKeyConfigured = false
    var isInstalled: Bool { executable != nil }
    var summary: String {
        guard isInstalled else { return AppText.localized("Not installed") }
        return version.map { String(format: AppText.localized("Installed · %@"), $0) } ?? AppText.localized("Installed")
    }
}

/// OMP is the sole runtime. Model providers are entries in OMP's native catalog,
/// never separate CLI adapters or app-owned credential stores.
@MainActor
@Observable
final class ProviderRegistry {
    private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    private(set) var catalogs: [ProviderKind: [ModelOption]] = [:]
    private(set) var commands: [String: [SlashCommand]] = [:]
    private(set) var commandErrors: [String: String] = [:]
    private(set) var recentCommands: [String: [String]] = [:]
    private(set) var loadingCatalogs: Set<ProviderKind> = []
    private(set) var catalogErrors: [ProviderKind: String] = [:]
    private(set) var isRefreshing = false
    private(set) var nativeConfiguration: [String: JSONValue] = [:]
    private(set) var modelCatalogRevision: UInt64 = 0
    @ObservationIgnored let settings: any ProviderSettings
    @ObservationIgnored var isProviderBusy: @MainActor (ProviderKind) -> Bool = { _ in false }
    @ObservationIgnored private var commandLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var catalogLoads: [ProviderKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var catalogLoadContexts: [ProviderKind: OMPDiscoveryContext] = [:]
    @ObservationIgnored private var catalogContexts: [ProviderKind: OMPDiscoveryContext] = [:]
    // The token-activity UI keeps its existing types. Subscription scraping is
    // deliberately absent: authentication and account limits belong to OMP.
    var planLimits: [ProviderKind: PlanLimits] = [:]
    var loadingLimits: Set<ProviderKind> = []
    var credits: [ProviderKind: ProviderCredits] = [:]
    var loadingCredits: Set<ProviderKind> = []
    var redeemingReset: String?
    @ObservationIgnored lazy var subscriptionUsage = OMPProviderUsageStore(registry: self)

    init(settings: any ProviderSettings) { self.settings = settings }
    var availableProviders: [ProviderKind] { [.omp] }
    func countsAsInstalled(_ provider: ProviderKind) -> Bool { provider == .omp && (statuses[provider]?.isInstalled ?? true) }
    func status(_ provider: ProviderKind) -> ProviderStatus { statuses[provider] ?? ProviderStatus() }

    func executable(for provider: ProviderKind) -> URL? {
        guard provider == .omp else { return nil }
        let custom = settings.binaryPath(for: .omp)
        if let found = LoginEnvironment.which(custom.isEmpty ? "omp" : custom) { return found }
        guard custom.isEmpty else { return nil }
        let home = LoginEnvironment.homeDirectory
        return ["\(home)/.bun/bin/omp", "\(home)/.local/bin/omp", "\(home)/.npm-global/bin/omp", "/opt/homebrew/bin/omp", "/usr/local/bin/omp"]
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func environment(for provider: ProviderKind) -> [String: String] {
        var environment = LoginEnvironment.current
        if let directory = executable(for: .omp)?.deletingLastPathComponent().path {
            environment["PATH"] = directory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        }
        return environment
    }

    func refreshEverything() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refresh(.omp)
        await loadCatalog(.omp, force: true)
    }
    func refreshAll() async { await refreshEverything() }
    func refresh(_ provider: ProviderKind) async {
        guard provider == .omp else { return }
        await LoginEnvironment.load()
        let executable = executable(for: provider)
        statuses[provider] = ProviderStatus(executable: executable, isChecking: true)
        var version: String?
        if let executable { version = try? await OMPCLI.run(["--version"], executable: executable, environment: environment(for: provider)) }
        statuses[provider] = ProviderStatus(executable: executable, version: version)
    }

    func models(for provider: ProviderKind) -> [ModelOption] { provider == .omp ? catalogs[.omp] ?? [] : [] }
    func model(_ id: String?, for provider: ProviderKind) -> ModelOption? {
        guard let id else { return nil }
        return models(for: provider).first { $0.id == id }
    }
    func defaultModel(for provider: ProviderKind) -> ModelOption? {
        let roles = nativeConfiguration["modelRoles"]
        return model(roles?["default"]?.string, for: provider) ?? model(settings.lastModel(for: provider), for: provider) ?? models(for: provider).first
    }
    func loadCatalog(_ provider: ProviderKind, force: Bool = false) async {
        guard provider == .omp else { return }
        guard let executable = executable(for: .omp) else { return }
        let environment = environment(for: provider)
        let context = OMPDiscoveryContext(executable: executable, environment: environment)
        if let task = catalogLoads[provider] {
            let existing = catalogLoadContexts[provider]
            await task.value
            if existing != context { await loadCatalog(provider, force: true) }
            return
        }
        guard force || catalogs[provider] == nil || catalogContexts[provider] != context else { return }
        loadingCatalogs.insert(provider)
        let task = Task { [self] in
            defer {
                catalogLoads[provider] = nil
                catalogLoadContexts[provider] = nil
                loadingCatalogs.remove(provider)
            }
            do {
                let models = try await OMPCLI.models(executable: executable, environment: environment)
                let config = try await OMPCLI.configuration(executable: executable, environment: environment, force: force)
                guard self.executable(for: .omp) == executable, self.environment(for: provider) == environment else { return }
                catalogs[provider] = models
                catalogContexts[provider] = context
                nativeConfiguration = config
                modelCatalogRevision &+= 1
                subscriptionUsage.invalidate()
                catalogErrors[provider] = nil
            } catch {
                guard self.executable(for: .omp) == executable, self.environment(for: provider) == environment else { return }
                catalogErrors[provider] = error.localizedDescription
            }
        }
        catalogLoads[provider] = task
        catalogLoadContexts[provider] = context
        await task.value
    }
    func updateCatalog(_ list: [ModelOption], for provider: ProviderKind) {
        guard provider == .omp else { return }
        catalogs[provider] = list
        modelCatalogRevision &+= 1
        subscriptionUsage.invalidate()
        if let executable = executable(for: provider) {
            catalogContexts[provider] = OMPDiscoveryContext(executable: executable, environment: environment(for: provider))
        }
    }
    static func commandKey(_ provider: ProviderKind, directory: String) -> String { "\(provider.rawValue):\(directory)" }
    func updateCommands(_ list: [SlashCommand], for provider: ProviderKind, directory: String) { commands[Self.commandKey(provider, directory: directory)] = list }
    func recordCommand(_ name: String, for provider: ProviderKind) {
        var list = recentCommands[provider.rawValue] ?? []
        list.removeAll { $0 == name }; list.insert(name, at: 0)
        recentCommands[provider.rawValue] = Array(list.prefix(12))
    }
    func loadCommands(_ provider: ProviderKind, directory: String, force: Bool = false) async {
        guard provider == .omp, let executable = executable(for: provider) else { return }
        let key = Self.commandKey(provider, directory: directory)
        if let task = commandLoads[key] { await task.value; return }
        guard force || commands[key] == nil else { return }
        let environment = environment(for: provider)
        let task = Task {
            let rpc = OMPRPC()
            defer { rpc.stop() }
            do {
                try rpc.start(executable: executable, arguments: ["--mode", "rpc", "--no-session", "--no-ui", "--no-title"],
                              directory: URL(fileURLWithPath: directory), environment: environment)
                let value = try await rpc.request("get_available_commands", timeout: .seconds(60))
                commands[key] = OMPSession.commands(value)
                commandErrors[key] = nil
            } catch { commandErrors[key] = error.localizedDescription }
            await rpc.stopAndWait(timeout: 5)
        }
        commandLoads[key] = task
        await task.value
        commandLoads[key] = nil
    }

    func cliUpdateBlocksWarmup(_ provider: ProviderKind) -> Bool { false }
    func waitWhileCLIUpdating(_ provider: ProviderKind) async {}
    func refreshPlanLimits(_ provider: ProviderKind, force: Bool = false) {}
    func refreshCredits(_ provider: ProviderKind, force: Bool = false) {}
    func invalidateCredits(_ provider: ProviderKind) {}
    func invalidatePlanLimits(_ provider: ProviderKind) {}
    func consumeResetCredit(_ provider: ProviderKind, _ id: String?) async throws -> PlanLimits.ResetOutcome { throw ProviderError.failed(AppText.localized("Account limits are managed by OMP.")) }
}
