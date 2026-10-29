import Foundation

struct OMPAuthenticationProvider: Sendable {
    let id: String
    let supportsBrowserLogin: Bool
    let credentialProviderID: String

    static func decode(_ value: JSONValue, directory: URL) throws -> [String: Self] {
        guard value["directory"]?.string == directory.path, let providers = value["providers"]?.array else {
            throw OMPModelConfiguration.failure("unavailable")
        }
        var result: [String: Self] = [:]
        for provider in providers {
            guard let id = provider["id"]?.string, !id.isEmpty, result[id] == nil,
                  let supportsBrowserLogin = provider["supportsBrowserLogin"]?.bool,
                  let credentialProviderID = provider["credentialProviderID"]?.string, !credentialProviderID.isEmpty else {
                throw OMPModelConfiguration.failure("unavailable")
            }
            result[id] = Self(id: id, supportsBrowserLogin: supportsBrowserLogin, credentialProviderID: credentialProviderID)
        }
        return result
    }
}

struct OMPAPIKeyProvider: Identifiable, Sendable {
    var id: String
    var name: String
    var environmentKeys: [String]
    var value: String
    var hasOAuth: Bool?
}

struct OMPModelConfigurationSnapshot: Identifiable, Sendable {
    let id = UUID()
    var directory: URL
    var file: String
    var revision: String
    var providers: [OMPAPIKeyProvider]
    var context: OMPDiscoveryContext

    static func decode(_ value: JSONValue, context: OMPDiscoveryContext) throws -> Self {
        guard let directory = value["directory"]?.string, directory.hasPrefix("/"),
              let file = value["file"]?.string, file.hasPrefix(directory + "/"),
              let revision = value["revision"]?.string, !revision.isEmpty,
              let rows = value["providers"]?.array else { throw OMPModelConfiguration.failure("unavailable") }
        var seen: Set<String> = []
        let providers = try rows.map { row -> OMPAPIKeyProvider in
            guard let id = row["id"]?.string, !id.isEmpty, seen.insert(id).inserted,
                  let name = row["name"]?.string, let key = row["value"]?.string else {
                throw OMPModelConfiguration.failure("unavailable")
            }
            return OMPAPIKeyProvider(id: id, name: name, environmentKeys: row["environmentKeys"]?.array?.compactMap(\.string) ?? [],
                                     value: key, hasOAuth: row["hasOAuth"]?.bool)
        }
        return Self(directory: URL(fileURLWithPath: directory), file: file, revision: revision, providers: providers, context: context)
    }

    func changes(from fields: [String: String]) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
            guard let value = fields[provider.id], value != provider.value else { return nil }
            return (provider.id, .string(value))
        })
    }
}

/// A bounded, on-demand editor for native models.yml. Secrets cross stdin only;
/// no API key is placed in arguments, GUI preferences, logs or discovery caches.
enum OMPModelConfiguration {
    private final class ResourceBundle: NSObject {}

    static func authenticationProviders(context: OMPDiscoveryContext, directory: URL) async throws -> [String: OMPAuthenticationProvider] {
        let value = try await request(["action": "authentication", "directory": .string(directory.path)], context: context)
        return try OMPAuthenticationProvider.decode(value, directory: directory)
    }

    static func read(executable: URL, environment: [String: String]) async throws -> OMPModelConfigurationSnapshot {
        let environment = OMPCLI.profileConfigurationEnvironment(environment)
        let directory = try await OMPCLI.run(["config", "path"], executable: executable, environment: environment)
        let context = OMPDiscoveryContext(executable: executable, environment: environment)
        let value = try await request(["action": "read", "directory": .string(directory)], context: context)
        return try OMPModelConfigurationSnapshot.decode(value, context: context)
    }

    static func save(_ snapshot: OMPModelConfigurationSnapshot, fields: [String: String],
                     executable: URL, environment: [String: String]) async throws {
        let context = OMPDiscoveryContext(executable: executable, environment: OMPCLI.profileConfigurationEnvironment(environment))
        guard snapshot.context == context else { throw failure("profile_changed") }
        _ = try await request(["action": "save", "directory": .string(snapshot.directory.path),
                              "file": .string(snapshot.file), "revision": .string(snapshot.revision),
                              "changes": .object(snapshot.changes(from: fields))], context: context)
    }

    static func request(_ input: JSONValue, context: OMPDiscoveryContext, unavailableCode: String = "unavailable") async throws -> JSONValue {
        let native = context.executable.resolvingSymlinksInPath()
        guard native.lastPathComponent == "cli.js", native.deletingLastPathComponent().lastPathComponent == "dist",
              let bun = LoginEnvironment.which("bun", in: context.environment),
              let helper = Bundle(for: ResourceBundle.self).url(forResource: "OMPModelConfiguration", withExtension: "js") else {
            throw failure(unavailableCode)
        }
        let result = try await Shell.run(bun, [helper.path, native.path], environment: context.environment,
                                         input: input.data(), timeout: 30, outputLimit: 3 * 1_024 * 1_024)
        guard let value = JSONValue.parse(result.stdout) else { throw failure(unavailableCode) }
        if let error = value["error"]?.string { throw failure(error) }
        guard result.succeeded else { throw failure(unavailableCode) }
        return value
    }

    static func failure(_ code: String) -> ProviderError {
        let message: String
        switch code {
        case "conflict", "profile_changed": message = "The OMP configuration changed. Reopen the editor before saving."
        case "invalid_file": message = "The model configuration cannot be read. Fix the file before editing API keys."
        case "invalid_configuration": message = "OMP rejected the updated model configuration. Other provider settings may require this API key."
        case "invalid_request": message = "Enter a single-line API key or native key reference."
        case "write_failed": message = "The model configuration could not be saved. Check file permissions and reopen the editor."
        case "image_credentials_unavailable": message = "OMP could not check image backend credentials. Reload or check its native credential store."
        case "image_configuration_invalid": message = "OMP could not read image settings. Check its native model configuration and reload."
        case "images_unavailable": message = "Image backend settings require an OMP npm installation with its native image SDK and Bun."
        default: message = "API key editing requires an OMP npm installation with its native SDK and Bun."
        }
        return .failed(AppText.localized(message))
    }
}
