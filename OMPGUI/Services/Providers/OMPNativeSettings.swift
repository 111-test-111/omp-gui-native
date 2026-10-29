import Foundation

struct OMPLoginProvider: Identifiable, Sendable {
    var id: String
    var name: String
    var authenticated: Bool
    var supportsBrowserLogin = false
    var credentialProviderID: String? = nil
    var accountProviderID: String { credentialProviderID ?? id }

    static func decode(_ value: JSONValue, policies: [String: OMPAuthenticationProvider]) -> Self? {
        guard let id = value["id"]?.string, !id.isEmpty, value["available"]?.bool != false else { return nil }
        return Self(id: id, name: value["name"]?.string ?? id, authenticated: value["authenticated"]?.bool ?? false,
                    supportsBrowserLogin: policies[id]?.supportsBrowserLogin ?? false,
                    credentialProviderID: policies[id]?.credentialProviderID)
    }
}

@MainActor
@Observable
final class OMPNativeSettings {
    private struct Snapshot: Sendable {
        var directory: URL
        var values: [String: JSONValue]
        var providers: [OMPLoginProvider]
        var revision: OMPConfigurationRevision
    }
    @ObservationIgnored private let discovery = OMPDiscoveryCache<Snapshot>()
    @ObservationIgnored private let configurationDiscovery = OMPDiscoveryCache<Snapshot>()
    let registry: ProviderRegistry
    private(set) var values: [String: JSONValue] = [:]
    private(set) var loginProviders: [OMPLoginProvider] = []
    var browserLoginProviders: [OMPLoginProvider] { loginProviders.filter(\.supportsBrowserLogin) }
    private var configurationRevision: OMPConfigurationRevision?
    private var loadingCount = 0
    private var refreshGeneration = 0
    var isLoading: Bool { loadingCount > 0 }
    private(set) var isSaving = false
    var error: String?
    private(set) var signingOutProviderID: String?
    private(set) var signOutError: String?
    private(set) var remainingAuthenticationSource: String?
    private(set) var agentDirectory: URL
    private(set) var configurationContext: OMPDiscoveryContext?

    init(registry: ProviderRegistry) {
        self.registry = registry
        agentDirectory = OMPCLI.agentDirectory(environment: LoginEnvironment.current)
    }

    func refresh(force: Bool = false, configurationOnly: Bool = false) async {
        guard !isSaving else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        if configurationOnly, force { discovery.invalidate() }
        loadingCount += 1
        defer { loadingCount -= 1 }
        await LoginEnvironment.load()
        guard let executable = registry.executable(for: .omp) else {
            values = [:]
            loginProviders = []
            configurationContext = nil
            error = ProviderError.notInstalled(.omp).localizedDescription
            return
        }
        let inheritedEnvironment = registry.environment(for: .omp)
        let environment = OMPCLI.profileConfigurationEnvironment(inheritedEnvironment)
        let context = OMPDiscoveryContext(executable: executable, environment: environment)
        do {
            let load = { [self] in
                try await configurationDiscovery.value(for: context, force: force) {
                    let path = try await OMPCLI.run(["config", "path"], executable: executable, environment: environment)
                    guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0") else {
                        throw ProviderError.failed(AppText.localized("OMP returned an invalid active profile path."))
                    }
                    let directory = URL(fileURLWithPath: path)
                    let revision = try OMPConfigurationRevision.read(directory: directory)
                    let values = try await OMPCLI.configuration(executable: executable, environment: environment, force: force)
                    guard try OMPConfigurationRevision.read(directory: directory) == revision else {
                        throw ProviderError.failed(AppText.localized("The OMP configuration changed on disk. Reload before saving."))
                    }
                    return Snapshot(directory: directory, values: values, providers: [], revision: revision)
                }
            }
            let snapshot: Snapshot
            if configurationOnly {
                snapshot = try await load()
            } else {
                snapshot = try await discovery.value(for: context, force: force) {
                    var snapshot = try await load()
                    let rpc = OMPRPC()
                    defer { rpc.stop() }
                    try rpc.start(executable: executable, arguments: ["--mode", "rpc", "--no-session", "--no-ui", "--no-title"],
                                  directory: FileManager.default.temporaryDirectory, environment: environment)
                    let providers = try? await rpc.request("get_login_providers", timeout: .seconds(15))
                    await rpc.stopAndWait(timeout: 5)
                    let policies = (try? await OMPModelConfiguration.authenticationProviders(
                        context: context, directory: snapshot.directory)) ?? [:]
                    snapshot.providers = (providers?["providers"]?.array ?? []).compactMap {
                        OMPLoginProvider.decode($0, policies: policies)
                    }
                    return snapshot
                }
            }
            guard generation == refreshGeneration, !Task.isCancelled, registry.executable(for: .omp) == executable,
                  registry.environment(for: .omp) == inheritedEnvironment else { return }
            agentDirectory = snapshot.directory
            values = snapshot.values
            configurationRevision = snapshot.revision
            configurationContext = context
            if !configurationOnly { loginProviders = snapshot.providers }
            error = nil
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled, registry.executable(for: .omp) == executable,
                  registry.environment(for: .omp) == inheritedEnvironment else { return }
            configurationContext = nil
            self.error = error.localizedDescription
        }
    }

    /// Remove this provider's stored accounts through OMP; never edit the credential store.
    func signOut(providerID: String) async {
        guard signingOutProviderID == nil else { return }
        signOutError = nil
        remainingAuthenticationSource = nil
        guard !isSaving, !isLoading else {
            signOutError = AppText.localized("OMP configuration is busy. Wait for it to finish and try again.")
            return
        }
        guard let executable = registry.executable(for: .omp) else {
            signOutError = ProviderError.notInstalled(.omp).localizedDescription
            return
        }
        signingOutProviderID = providerID
        defer { signingOutProviderID = nil }
        let inheritedEnvironment = registry.environment(for: .omp)
        let environment = OMPCLI.profileConfigurationEnvironment(inheritedEnvironment)
        let rpc = OMPRPC()
        do {
            try rpc.start(executable: executable, arguments: ["--mode", "rpc", "--no-session", "--no-ui", "--no-title"],
                          directory: FileManager.default.temporaryDirectory, environment: environment)
            let result = try await rpc.request("get_logout_accounts", fields: ["providerId": .string(providerID)])
            guard let accounts = result["accounts"]?.array else {
                throw ProviderError.failed(AppText.localized("OMP returned invalid JSON."))
            }
            let credentialIDs = try accounts.map { account -> Int in
                guard let id = account["credentialId"]?.int else {
                    throw ProviderError.failed(AppText.localized("OMP returned invalid JSON."))
                }
                return id
            }
            guard !credentialIDs.isEmpty else {
                throw ProviderError.failed(AppText.localized("OMP has no stored credentials for this provider. Remove its key from the environment or model configuration instead."))
            }
            for id in credentialIDs {
                guard registry.executable(for: .omp) == executable,
                      registry.environment(for: .omp) == inheritedEnvironment else {
                    throw ProviderError.failed(AppText.localized("The OMP configuration changed on disk. Reload before saving."))
                }
                let response = try await rpc.request("logout", fields: [
                    "providerId": .string(providerID), "credentialId": .int(id),
                ], timeout: .seconds(60))
                remainingAuthenticationSource = response["remainingSource"]?.string
            }
        } catch {
            signOutError = error.localizedDescription
            remainingAuthenticationSource = nil
        }
        await rpc.stopAndWait(timeout: 5)
        // A failed multi-account logout may already have removed earlier credentials.
        await refresh(force: true)
        await registry.loadCatalog(.omp, force: true)
    }

    func setSelectors(_ key: String, changes: [String: String], expected: JSONValue) async -> String? {
        await set(key, OMPSelectorRecord.merging(changes, into: expected), expected: expected)
        return error
    }

    func setTool(_ control: OMPToolCatalogue.Control, _ value: JSONValue, expected: JSONValue) async {
        if let page = control.settingsPage {
            error = String(format: AppText.localized("Managed in %@ settings"), AppText.localized(page))
            return
        }
        guard let key = control.key, control.accepts(value), !OMPToolCatalogue.members(of: control).isEmpty else {
            error = AppText.localized("This tool has no independent OMP setting.")
            return
        }
        await set(key, value, expected: expected, refreshCatalog: false)
        if error == nil, values[key] != value {
            error = AppText.localized("Saved in OMP, but overridden by another configuration source.")
        }
    }

    func set(_ key: String, _ value: JSONValue, expected: JSONValue? = nil, refreshCatalog: Bool = true) async {
        guard !isSaving, !isLoading, signingOutProviderID == nil else {
            error = AppText.localized("OMP configuration is busy. Wait for it to finish and try again.")
            return
        }
        guard let executable = registry.executable(for: .omp) else { error = ProviderError.notInstalled(.omp).localizedDescription; return }
        isSaving = true
        discovery.invalidate()
        configurationDiscovery.invalidate()
        defer { isSaving = false }
        do {
            let inheritedEnvironment = registry.environment(for: .omp)
            let environment = OMPCLI.profileConfigurationEnvironment(inheritedEnvironment)
            let context = OMPDiscoveryContext(executable: executable, environment: environment)
            let currentPath = try await OMPCLI.run(["config", "path"], executable: executable, environment: environment)
            guard configurationContext == context, currentPath == agentDirectory.path, let configurationRevision,
                  try OMPConfigurationRevision.read(directory: agentDirectory) == configurationRevision else {
                throw ProviderError.failed(AppText.localized("The OMP configuration changed on disk. Reload before saving."))
            }
            let fresh = try await OMPCLI.configuration(executable: executable, environment: environment, force: true)
            guard fresh[key] == values[key], expected == nil || fresh[key] == expected else {
                throw ProviderError.failed(AppText.localized("The OMP configuration changed on disk. Reload before saving."))
            }
            guard registry.executable(for: .omp) == executable,
                  registry.environment(for: .omp) == inheritedEnvironment,
                  try OMPConfigurationRevision.read(directory: agentDirectory) == configurationRevision else {
                throw ProviderError.failed(AppText.localized("The OMP configuration changed on disk. Reload before saving."))
            }
            try await OMPCLI.set(key, value: value, executable: executable, environment: environment)
            let saved = try await OMPCLI.configuration(executable: executable, environment: environment, force: true)
            guard registry.executable(for: .omp) == executable,
                  registry.environment(for: .omp) == inheritedEnvironment else {
                error = AppText.localized("The OMP configuration changed on disk. Reload before saving.")
                return
            }
            values = saved
            self.configurationRevision = try OMPConfigurationRevision.read(directory: agentDirectory)
            error = nil
            if refreshCatalog { await registry.loadCatalog(.omp, force: true) }
        } catch { self.error = error.localizedDescription }
    }
}
