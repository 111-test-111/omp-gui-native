import Foundation

struct OMPImageBackend: Identifiable, Sendable {
    var id: String
    var name: String
    var preferredModel: String
    var loginProvider: String?
    var keyProvider: String?
    var environmentKeys: [String]
}

struct OMPImageModel: Identifiable, Sendable {
    var id: String
    var provider: String
    var name: String
    var hasCredentials: Bool
    var requiresCredentials: Bool
}

/// Only catalogue and credential-presence metadata cross the SDK boundary.
struct OMPImageConfiguration: Sendable {
    var directory: URL
    var context: OMPDiscoveryContext
    var selector: String
    var selectedID: String?
    var models: [OMPImageModel]
    var backends: [OMPImageBackend]

    var selected: OMPImageModel? { models.first { $0.id == selectedID } }
    var backend: OMPImageBackend? { backends.first { $0.id == selected?.provider } }

    static func decode(_ value: JSONValue, context: OMPDiscoveryContext) throws -> Self {
        func invalid() -> ProviderError { OMPModelConfiguration.failure("images_unavailable") }
        guard let directory = value["directory"]?.string, directory.hasPrefix("/"),
              let selector = value["selector"]?.string,
              let modelRows = value["models"]?.array, let backendRows = value["backends"]?.array else { throw invalid() }
        var modelIDs: Set<String> = []
        let models = try modelRows.map { row -> OMPImageModel in
            guard let id = row["id"]?.string, modelIDs.insert(id).inserted,
                  let provider = row["provider"]?.string, !provider.isEmpty, id.hasPrefix(provider + "/"),
                  let name = row["name"]?.string, let configured = row["hasCredentials"]?.bool,
                  let required = row["requiresCredentials"]?.bool else { throw invalid() }
            return OMPImageModel(id: id, provider: provider, name: name, hasCredentials: configured, requiresCredentials: required)
        }
        var backendIDs: Set<String> = []
        let backends = try backendRows.map { row -> OMPImageBackend in
            guard let id = row["id"]?.string, backendIDs.insert(id).inserted,
                  let name = row["name"]?.string, let preferred = row["preferredModel"]?.string,
                  models.contains(where: { $0.id == preferred && $0.provider == id }) else { throw invalid() }
            return OMPImageBackend(id: id, name: name, preferredModel: preferred,
                                   loginProvider: row["loginProvider"]?.string, keyProvider: row["keyProvider"]?.string,
                                   environmentKeys: row["environmentKeys"]?.array?.compactMap(\.string) ?? [])
        }
        let selectedID = value["selected"]?.string
        guard selectedID.map(modelIDs.contains) ?? true,
              models.allSatisfy({ backendIDs.contains($0.provider) }) else { throw invalid() }
        return Self(directory: URL(fileURLWithPath: directory), context: context, selector: selector,
                    selectedID: selectedID, models: models, backends: backends)
    }

    static func read(context: OMPDiscoveryContext) async throws -> Self {
        let directory = try await OMPCLI.run(["config", "path"], executable: context.executable, environment: context.environment)
        let value = try await OMPModelConfiguration.request(["action": "images", "directory": .string(directory)],
                                                           context: context, unavailableCode: "images_unavailable")
        return try decode(value, context: context)
    }
}
