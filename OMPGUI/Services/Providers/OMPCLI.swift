import Foundation

/// All model discovery and configuration writes go through OMP, so its provider
/// registry, YAML schema, credential sources and custom models stay authoritative.
enum OMPCLI {
    @MainActor private static let configurationCache = OMPDiscoveryCache<[String: JSONValue]>()
    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max", "auto"]

    /// Read only the public session header in this edition's own OMP store.
    /// A worker's tools may use paths relative to an OMP-managed worktree.
    static func sessionWorkingDirectory(_ file: String) -> String? {
        let root = StoragePaths.directory("omp/sessions").resolvingSymlinksInPath().path + "/"
        let url = URL(fileURLWithPath: file).resolvingSymlinksInPath()
        guard url.path.hasPrefix(root), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Native journals can reserve a title record before the session header.
        // Inspect only the bounded preamble; never scan a worker's full history.
        guard let data = try? handle.read(upToCount: 32_768),
              let header = data.split(separator: 0x0A).prefix(8)
                .compactMap({ JSONValue.parse(Data($0)) }).first(where: { $0["type"]?.string == "session" }) else { return nil }
        return header["cwd"]?.string
    }

    static func agentDirectory(environment: [String: String]) -> URL {
        let home = environment["HOME"] ?? LoginEnvironment.homeDirectory
        let config = environment["PI_CONFIG_DIR"]?.nilIfEmpty ?? ".omp"
        let root = config.hasPrefix("/") ? URL(fileURLWithPath: config) : URL(fileURLWithPath: home).appendingPathComponent(config)
        if let profile = (environment["OMP_PROFILE"] ?? environment["PI_PROFILE"])?.nilIfEmpty, profile != "default" {
            return root.appendingPathComponent("profiles/\(profile)/agent")
        }
        if let override = environment["PI_CODING_AGENT_DIR"]?.nilIfEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return root.appendingPathComponent("agent")
    }

    /// APPEND_SYSTEM.md uses OMP's shared config base, not an arbitrary SDK
    /// agent-directory override. Named profiles still select their native base.
    static func appendPromptDirectory(environment: [String: String]) -> URL {
        var sharedEnvironment = environment
        sharedEnvironment.removeValue(forKey: "PI_CODING_AGENT_DIR")
        return agentDirectory(environment: sharedEnvironment)
    }

    static func run(_ arguments: [String], executable: URL, environment: [String: String], directory: URL? = nil) async throws -> String {
        let result = try await Shell.run(executable, arguments, in: directory ?? FileManager.default.temporaryDirectory,
                                         environment: environment, timeout: 60)
        guard result.succeeded else {
            throw ProviderError.failed(result.failureMessage)
        }
        return result.trimmedOutput
    }

    static func models(executable: URL, environment: [String: String], directory: URL? = nil) async throws -> [ModelOption] {
        let output = try await run(["models", "--json"], executable: executable, environment: environment, directory: directory)
        guard let value = JSONValue.parse(output) else { throw ProviderError.failed(AppText.localized("OMP returned invalid JSON.")) }
        var options = modelOptions(value["models"]?.array ?? value.array ?? [], pricesAreCLISnapshot: true)
        // The CLI's compact list omits API identity and service tiers. Read the
        // public, model-free RPC catalogue once; never probe a mutating toggle.
        if let native = try? await nativeModelOptions(executable: executable, environment: environment, directory: directory) {
            let tiers = Dictionary(native.map { ($0.id, $0.fastTier) }, uniquingKeysWith: { first, _ in first })
            for index in options.indices { options[index].fastTier = tiers[options[index].id] ?? nil }
        }
        return options
    }

    @MainActor private static func nativeModelOptions(executable: URL, environment: [String: String], directory: URL?) async throws -> [ModelOption] {
        let rpc = OMPRPC()
        do {
            try rpc.start(executable: executable, arguments: ["--mode", "rpc", "--no-session", "--no-ui", "--no-title"],
                          directory: directory ?? FileManager.default.temporaryDirectory, environment: environment)
            let catalog = try await rpc.request("get_available_models", timeout: .seconds(15))
            await rpc.stopAndWait(timeout: 5)
            return modelOptions(catalog["models"]?.array ?? [])
        } catch {
            await rpc.stopAndWait(timeout: 5)
            throw error
        }
    }

    /// OMP's public model API/identity/tier facts, matching its realizable Fast
    /// families. No model-name guesses, custom relay allowlist or provider launch.
    static func fastTier(_ row: JSONValue) -> String? {
        guard let provider = row["provider"]?.string, let api = row["api"]?.string else { return nil }
        let modelClass = row["identity"]?["class"]?.string
        if api == "openai-codex-responses", let tiers = row["serviceTiers"]?.array, !tiers.isEmpty,
           !tiers.contains(.string("priority")) { return nil }
        if provider == "anthropic" { return "priority" }
        if provider == "openrouter" {
            return modelClass == "openai" || modelClass == "gemini" ? "priority" : nil
        }
        if api == "anthropic-messages" { return nil }
        if ["openai", "openai-codex", "google", "google-vertex"].contains(provider) { return "priority" }
        if !["github-copilot", "fireworks"].contains(provider), modelClass == "openai",
           ["openai-completions", "openai-responses", "openai-codex-responses"].contains(api) { return "priority" }
        return nil
    }

    static func modelOptions(_ rows: [JSONValue], current: String? = nil, pricesAreCLISnapshot: Bool = false) -> [ModelOption] {
        rows.compactMap { row in
            guard row["kind"]?.string == nil || row["kind"]?.string == "chat",
                  let provider = row["provider"]?.string, let id = row["id"]?.string else { return nil }
            let selector = row["selector"]?.string ?? "\(provider)/\(id)"
            let levels = row["thinking"]?.array?.compactMap(\.string)
                ?? (row["reasoning"]?.bool == true ? thinkingLevels : [])
            let metadata = modelMetadata(row, pricesAreCLISnapshot: pricesAreCLISnapshot)
            let window = metadata.contextWindow
            let detail = window.map { String(format: AppText.localized("%@ · %lld context"), provider, Int64($0)) } ?? provider
            return ModelOption(id: selector, name: row["name"]?.string ?? id, detail: detail, provider: provider,
                               efforts: levels, defaultEffort: levels.contains("medium") ? "medium" : levels.first,
                               isDefault: selector == current, fastTier: fastTier(row), metadata: metadata)
        }.sorted { ($0.detail ?? "", $0.name) < ($1.detail ?? "", $1.name) }
    }

    private static func modelMetadata(_ row: JSONValue, pricesAreCLISnapshot: Bool) -> ModelMetadata {
        func limit(_ value: JSONValue?) -> Int? {
            guard let number = value?.double, number.isFinite, number > 0 else { return nil }
            return Int(exactly: number)
        }
        func rate(_ key: String) -> Double? {
            guard let number = row["cost"]?[key]?.double, number.isFinite, number >= 0 else { return nil }
            return number
        }
        let input = rate("input"), output = rate("output")
        let cacheRead = rate("cacheRead"), cacheWrite = rate("cacheWrite")
        // Older RPC catalogues omit status for ordinary paid rates. A missing or
        // unfamiliar status never makes an all-zero rate card free.
        let status: ModelPricing.Status
        if let declared = row["pricingStatus"]?.string {
            status = ModelPricing.Status(rawValue: declared) ?? .unknown
        } else {
            status = [input, output, cacheRead, cacheWrite].contains { ($0 ?? 0) > 0 } ? .fixed : .unknown
        }
        let cost = row["cost"]
        return ModelMetadata(
            inputTypes: row["input"]?.array.map { $0.compactMap(\.string) },
            contextWindow: limit(row["contextWindow"]),
            maxOutputTokens: limit(row["maxTokens"]),
            pricing: ModelPricing(
                status: status, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                isCLISnapshot: pricesAreCLISnapshot,
                hasContextOrTimeTiers: cost?["longContext"]?.object != nil || cost?["timeBased"]?.object != nil
            )
        )
    }

    /// Settings forms administer the active profile, independently of chat-only
    /// process overlays. Profile selection and native config roots stay external.
    static func profileConfigurationEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        result.removeValue(forKey: "PI_CONFIG_FILES")
        return result
    }

    @MainActor static func configuration(executable: URL, environment: [String: String], directory: URL? = nil, force: Bool = false) async throws -> [String: JSONValue] {
        let context = OMPDiscoveryContext(executable: executable, environment: environment, directory: directory)
        return try await configurationCache.value(for: context, force: force) {
            try await readConfiguration(executable: executable, environment: environment, directory: directory)
        }
    }

    private static func readConfiguration(executable: URL, environment: [String: String], directory: URL?) async throws -> [String: JSONValue] {
        let output = try await run(["config", "list", "--json"], executable: executable, environment: environment, directory: directory)
        guard let value = JSONValue.parse(output) else { throw ProviderError.failed(AppText.localized("OMP returned invalid JSON.")) }
        // Never retain unrelated settings or credential fields from the CLI response.
        let keys = Set(["modelRoles", "defaultThinkingLevel", "task.maxConcurrency", "task.isolation.enabled", "task.isolation.apply",
                    "task.isolation.merge", "task.eager", "task.agentModelOverrides", "task.disabledAgents",
                    "task.maxRecursionDepth", "tools.approvalMode", "generate_image.enabled"] + OMPToolCatalogue.configurationKeys)
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in value[key]?["value"].map { (key, $0) } })
    }

    @MainActor static func set(_ key: String, value: JSONValue, executable: URL, environment: [String: String], directory: URL? = nil) async throws {
        configurationCache.invalidate()
        defer { configurationCache.invalidate() }
        var argument = value.string ?? value.compactString
        // OMP 18.3.2 config parsing skips positional arguments beginning with
        // '-'. Leading JSON whitespace retains the exact negative numeric value.
        if value.string == nil, argument.hasPrefix("-") { argument = " " + argument }
        _ = try await run(["config", "set", key, argument], executable: executable, environment: environment, directory: directory)
    }
}
