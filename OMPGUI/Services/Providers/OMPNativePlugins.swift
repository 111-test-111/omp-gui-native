import Foundation

struct OMPNativePlugin: Identifiable, Sendable {
    var id: String
    var name: String
    var version: String?
    var scope: String
    var enabled: Bool?
    var detail: String?
}

struct OMPPluginDiagnostic: Identifiable, Sendable {
    var id: String
    var status: String
    var message: String
}

/// OMP's public plugin CLI owns its registry, installation and dependency work.
@MainActor
@Observable
final class OMPNativePlugins {
    private(set) var plugins: [OMPNativePlugin] = []
    private(set) var diagnostics: [OMPPluginDiagnostic] = []
    private(set) var isBusy = false
    private(set) var hasLoaded = false
    var error: String?

    static func inventory(_ value: JSONValue) -> [OMPNativePlugin] {
        let npm = (value["npm"]?.array ?? []).compactMap { row -> OMPNativePlugin? in
            guard let name = row["name"]?.string else { return nil }
            return OMPNativePlugin(id: "npm:" + name, name: name, version: row["version"]?.string,
                scope: "user", enabled: row["enabled"]?.bool, detail: row["manifest"]?["description"]?.string)
        }
        let marketplace = (value["marketplace"]?.array ?? []).compactMap { row -> OMPNativePlugin? in
            guard let id = row["id"]?.string else { return nil }
            let scope = row["scope"]?.string ?? "unknown"
            return OMPNativePlugin(id: "marketplace:" + scope + ":" + id, name: id, version: row["entries"]?[0]?["version"]?.string,
                scope: scope, enabled: row["enabled"]?.bool, detail: row["shadowedBy"]?.string)
        }
        return (npm + marketplace).sorted { ($0.name, $0.scope) < ($1.name, $1.scope) }
    }

    private func execute(_ arguments: [String], registry: ProviderRegistry, directory: URL?) async throws -> JSONValue {
        guard let executable = registry.executable(for: .omp) else { throw ProviderError.notInstalled(.omp) }
        let result = try await Shell.run(executable, ["plugin"] + arguments + ["--json"],
            in: directory ?? FileManager.default.temporaryDirectory,
            environment: registry.environment(for: .omp), timeout: ["install", "uninstall"].contains(arguments.first ?? "") ? 300 : 60)
        // `doctor` returns structured failures with a nonzero exit status.
        if let value = JSONValue.parse(result.trimmedOutput) {
            if arguments.first == "doctor" || result.succeeded { return value }
        }
        // Some marketplace mutations intentionally emit human-readable success
        // even with --json. Exit status remains the native acceptance evidence.
        if result.succeeded, ["install", "uninstall"].contains(arguments.first ?? "") { return .null }
        throw ProviderError.failed(result.failureMessage)
    }

    func refresh(registry: ProviderRegistry, directory: URL?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let value = try await execute(["list"], registry: registry, directory: directory)
            guard value["npm"]?.array != nil, value["marketplace"]?.array != nil else {
                throw ProviderError.failed(AppText.localized("OMP returned invalid JSON."))
            }
            plugins = Self.inventory(value)
            hasLoaded = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func diagnose(registry: ProviderRegistry, directory: URL?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let value = try await execute(["doctor"], registry: registry, directory: directory)
            guard let checks = value.array else { throw ProviderError.failed(AppText.localized("OMP returned invalid JSON.")) }
            diagnostics = checks.enumerated().compactMap { index, row in
                guard let name = row["name"]?.string, let status = row["status"]?.string else { return nil }
                return OMPPluginDiagnostic(id: String(index) + ":" + name, status: status,
                    message: name + ": " + (row["message"]?.string ?? ""))
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func change(_ action: String, target: String, scope: String, registry: ProviderRegistry, directory: URL?) async -> Bool {
        guard !isBusy, ["install", "uninstall"].contains(action), !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await execute([action, target, "--scope", scope], registry: registry, directory: directory)
            error = nil
            hasLoaded = false
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
