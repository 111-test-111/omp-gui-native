import Foundation

/// Catalog templates become ordinary native profile definitions, never GUI connections.
enum OMPMCPQuickConnect {
    static func matches(_ entry: MCPCatalogEntry, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || ([entry.id, entry.name, entry.vendor, entry.summary, entry.category.title]
            + entry.sampleTools + [AppText.localized(entry.summary), AppText.localized(entry.category.title)])
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func definition(for entry: MCPCatalogEntry, values: [String: String]) throws -> JSONValue {
        for field in entry.fields where field.isRequired {
            guard !(values[field.key]?.nilIfEmpty ?? field.defaultValue ?? "").trimmed.isEmpty else {
                throw OMPMCPError(errorDescription: String(format: AppText.localized("Enter %@."), AppText.localized(field.label)))
            }
        }
        func fill(_ text: String) -> String { entry.fill(text, values: values) }
        func fields(_ templates: [String: String]) -> JSONValue {
            .object(templates.compactMapValues { template in
                let missingOptional = entry.fields.contains {
                    !$0.isRequired && template.contains("{\($0.key)}")
                        && (values[$0.key]?.nilIfEmpty ?? $0.defaultValue) == nil
                }
                return missingOptional ? nil : .string(fill(template))
            })
        }
        let definition: JSONValue
        switch entry.transport {
        case .stdio(let command, let arguments):
            definition = ["type": "stdio", "command": .string(fill(command)),
                          "args": .array(arguments.map { .string(fill($0)) }), "env": fields(entry.env)]
        case .http(let url, let headers):
            definition = ["type": "http", "url": .string(fill(url)), "headers": fields(headers)]
        case .oauth(let url):
            definition = ["type": "http", "url": .string(fill(url))]
        }
        try OMPMCPDocument.validateServer(definition)
        return definition
    }
}
