import Foundation

struct OMPMCPError: LocalizedError, Sendable {
    var errorDescription: String?
}

enum OMPMCPTransport: String, CaseIterable, Sendable {
    case stdio, http, sse

    var title: String {
        switch self {
        case .stdio: "Local process (stdio)"
        case .http: "Streamable HTTP"
        case .sse: "Server-Sent Events (SSE)"
        }
    }
}

struct OMPMCPServer: Identifiable, Sendable {
    var id: String
    var definition: JSONValue
    var enabled: Bool

    var transport: OMPMCPTransport? {
        if let type = definition["type"]?.string { return OMPMCPTransport(rawValue: type) }
        return definition["command"] != nil ? .stdio : .http
    }

    var detail: String {
        // Arguments, headers, URL queries and userinfo can contain credentials.
        if transport == .stdio { return definition["command"]?.string ?? "stdio" }
        return definition["url"]?.string.flatMap { URL(string: $0)?.host } ?? transport?.rawValue ?? "MCP"
    }
}

/// Unknown fields and literal secret references survive form edits. The GUI
/// never resolves or runs them; OMP remains the only MCP runtime.
enum OMPMCPDocument {
    static let byteLimit = 2 * 1024 * 1024
    static let empty: JSONValue = [
        "$schema": "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json",
        "mcpServers": [:]
    ]

    static func decode(_ text: String) throws -> JSONValue {
        let value = try json(text)
        guard value.object != nil,
              value["mcpServers"] == nil || value["mcpServers"]?.object != nil else {
            throw failure("MCP configuration needs a mcpServers object.")
        }
        return value
    }

    static func json(_ text: String) throws -> JSONValue {
        guard text.utf8.count <= byteLimit else { throw failure("MCP configuration exceeds the 2 MiB editing limit.") }
        guard let value = JSONValue.parse(text) else { throw failure("Enter valid JSON.") }
        return value
    }

    static func servers(in value: JSONValue) -> [OMPMCPServer] {
        let disabled = Set(value["disabledServers"]?.array?.compactMap(\.string) ?? [])
        let enabled = Set(value["enabledServers"]?.array?.compactMap(\.string) ?? [])
        return (value["mcpServers"]?.object ?? [:]).sorted { $0.key < $1.key }.map { name, definition in
            OMPMCPServer(id: name, definition: definition,
                         enabled: !disabled.contains(name) && (enabled.contains(name) || definition["enabled"]?.bool != false))
        }
    }

    static func validateName(_ name: String) throws {
        // Match the native writer, including namespaces and single spaces.
        guard name.utf16.count <= 100,
              name.range(of: "\\A[a-zA-Z0-9_.:-]+(?: [a-zA-Z0-9_.:-]+)*\\z", options: .regularExpression) != nil else {
            throw failure("Use a server name of up to 100 letters, numbers, dots, colons, underscores, hyphens or single spaces.")
        }
    }

    static func validateServer(_ server: JSONValue) throws {
        guard let fields = server.object else { throw failure("The MCP server definition must be a JSON object.") }
        let type = server["type"]?.string ?? (server["url"] != nil && server["command"] == nil ? "http" : "stdio")
        guard let transport = OMPMCPTransport(rawValue: type), server["type"] == nil || server["type"]?.string != nil else {
            throw failure("Choose a supported MCP transport: stdio, http or sse.")
        }
        if transport == .stdio {
            guard server["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  server["url"] == nil else { throw failure("A local MCP server needs a command and must not contain a URL.") }
        } else {
            guard let address = server["url"]?.string, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  server["command"] == nil else { throw failure("A remote MCP server needs a URL and must not contain a command.") }
            // Keep native placeholders literal until OMP discovery.
            guard address.contains("${") || URL(string: address).map({ ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil }) == true else {
                throw failure("Enter an HTTP or HTTPS MCP endpoint URL.")
            }
        }
        for key in ["command", "url", "cwd"] where fields[key] != nil {
            guard let text = fields[key]?.string, !text.contains("\0") else { throw invalidField(key) }
        }
        if let args = fields["args"] {
            guard let values = args.array, values.allSatisfy({ $0.string.map { !$0.contains("\0") } == true }) else { throw invalidField("args") }
        }
        for key in ["env", "headers"] where fields[key] != nil {
            guard let entries = fields[key]?.object,
                  entries.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("\0") && $0.value.string.map { !$0.contains("\0") } == true }) else { throw invalidField(key) }
        }
        for key in ["enabled", "instructions"] where fields[key] != nil {
            guard fields[key]?.bool != nil else { throw invalidField(key) }
        }
        if let timeout = fields["timeout"] {
            guard let number = timeout.double, number.isFinite, number >= 0 else { throw invalidField("timeout") }
        }
        if let format = fields["requestIdFormat"], ![JSONValue.string("number"), .string("string")].contains(format) { throw invalidField("requestIdFormat") }
        for key in ["auth", "oauth"] where fields[key] != nil {
            guard fields[key]?.object != nil else { throw invalidField(key) }
        }
    }

    static func validate(_ value: JSONValue) throws {
        guard value.object != nil, value["mcpServers"] == nil || value["mcpServers"]?.object != nil else {
            throw failure("MCP configuration needs a mcpServers object.")
        }
        for key in ["disabledServers", "enabledServers"] where value[key] != nil {
            guard let entries = value[key]?.array, entries.allSatisfy({ $0.string?.isEmpty == false }) else { throw invalidField(key) }
        }
        for (name, server) in value["mcpServers"]?.object ?? [:] {
            try validateName(name)
            try validateServer(server)
        }
    }

    static func replacingServer(in value: JSONValue, oldName: String?, name: String, definition: JSONValue, enabled: Bool) throws -> JSONValue {
        try validateName(name)
        try validateServer(definition)
        var result = value.object ?? [:]
        var definitions = value["mcpServers"]?.object ?? [:]
        guard oldName == name || definitions[name] == nil else { throw failure("A server with this name already exists.") }
        if let oldName {
            guard definitions[oldName] != nil else { throw failure("The OMP configuration changed. Reopen the editor before saving.") }
            definitions[oldName] = nil
            if oldName != name {
                for key in ["enabledServers", "disabledServers"] {
                    if let entries = result[key]?.array {
                        result[key] = .array(entries.map { $0.string == oldName ? .string(name) : $0 })
                    }
                }
            }
        }
        definitions[name] = definition
        result["mcpServers"] = .object(definitions)
        let assembled = JSONValue.object(result)
        if servers(in: assembled).first(where: { $0.id == name })?.enabled == enabled { return assembled }
        return try settingEnabled(enabled, server: name, in: assembled)
    }

    static func settingEnabled(_ enabled: Bool, server name: String, in value: JSONValue) throws -> JSONValue {
        var result = value.object ?? [:]
        var servers = value["mcpServers"]?.object ?? [:]
        guard var fields = servers[name]?.object else { throw failure("The OMP configuration changed. Reopen the editor before saving.") }
        fields["enabled"] = .bool(enabled)
        servers[name] = .object(fields)
        result["mcpServers"] = .object(servers)
        for key in ["enabledServers", "disabledServers"] {
            var entries = result[key]?.array?.filter { $0.string != name } ?? []
            if (key == "enabledServers") == enabled { entries.append(.string(name)) }
            result[key] = .array(entries)
        }
        return .object(result)
    }

    static func removingServer(_ name: String, from value: JSONValue) -> JSONValue {
        var result = value.object ?? [:]
        var servers = value["mcpServers"]?.object ?? [:]
        servers[name] = nil
        result["mcpServers"] = .object(servers)
        for key in ["enabledServers", "disabledServers"] {
            if let entries = result[key]?.array { result[key] = .array(entries.filter { $0.string != name }) }
        }
        return .object(result)
    }

    static func failure(_ key: String) -> OMPMCPError { OMPMCPError(errorDescription: AppText.localized(key)) }
    static func invalidField(_ key: String) -> OMPMCPError {
        OMPMCPError(errorDescription: String(format: AppText.localized("Invalid MCP field: %@."), key))
    }
}

struct OMPMCPArgument: Identifiable, Sendable {
    var id = UUID()
    var value = ""
}

struct OMPMCPKeyValue: Identifiable, Sendable {
    var id = UUID()
    var key = ""
    var value = ""
}

struct OMPMCPServerDraft: Sendable {
    static let rowLimit = 128
    private var original: JSONValue
    private var initialEmptyArgumentID: UUID?
    var transport: OMPMCPTransport
    var command: String
    var arguments: [OMPMCPArgument]
    var environment: [OMPMCPKeyValue]
    var directory: String
    var url: String
    var headers: [OMPMCPKeyValue]
    var timeout: String
    var instructions: Bool

    static func supportsVisualEditing(_ value: JSONValue) -> Bool {
        (try? OMPMCPDocument.validateServer(value)) != nil &&
        (value["args"]?.array?.count ?? 0) <= rowLimit &&
        (value["env"]?.object?.count ?? 0) <= rowLimit &&
        (value["headers"]?.object?.count ?? 0) <= rowLimit
    }

    init(_ value: JSONValue = ["type": "stdio", "command": ""]) {
        original = value
        transport = OMPMCPTransport(rawValue: value["type"]?.string ?? "") ?? (value["url"] == nil ? .stdio : .http)
        command = value["command"]?.string ?? ""
        arguments = (value["args"]?.array ?? []).map { OMPMCPArgument(value: $0.string ?? "") }
        if arguments.isEmpty {
            let argument = OMPMCPArgument()
            arguments = [argument]
            initialEmptyArgumentID = argument.id
        }
        environment = Self.pairs(value["env"])
        if environment.isEmpty { environment = [OMPMCPKeyValue()] }
        directory = value["cwd"]?.string ?? ""
        url = value["url"]?.string ?? ""
        headers = Self.pairs(value["headers"])
        if headers.isEmpty { headers = [OMPMCPKeyValue()] }
        timeout = value["timeout"]?.displayText ?? ""
        instructions = value["instructions"]?.bool ?? true
    }

    func definition(validate: Bool = true) throws -> JSONValue {
        var fields = original.object ?? [:]
        // Patch only changed fields, including default-valued optional fields.
        func put(_ key: String, _ value: JSONValue?, default defaultValue: JSONValue? = nil) {
            if fields[key] == nil && value == defaultValue { return }
            fields[key] = value
        }
        let originalTransport = original["type"]?.string ?? (original["url"] == nil ? "stdio" : "http")
        if original["type"] != nil || originalTransport != transport.rawValue { fields["type"] = .string(transport.rawValue) }
        if transport == .stdio {
            put("command", .string(command))
            // Omit only the automatic blank row; existing empty argv entries are meaningful.
            let argv = arguments.filter { $0.id != initialEmptyArgumentID || !$0.value.isEmpty }.map { JSONValue.string($0.value) }
            put("args", .array(argv), default: [])
            put("env", try Self.dictionary(environment, caseInsensitive: false), default: [:])
            if original["cwd"]?.string != directory { put("cwd", directory.isEmpty ? nil : .string(directory)) }
            if originalTransport != transport.rawValue { fields["url"] = nil; fields["headers"] = nil }
        } else {
            fields["type"] = .string(transport.rawValue)
            put("url", .string(url))
            put("headers", try Self.dictionary(headers, caseInsensitive: true), default: [:])
            if originalTransport != transport.rawValue {
                for key in ["command", "args", "env", "cwd"] { fields[key] = nil }
            }
        }
        if timeout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["timeout"] = nil }
        else {
            guard let number = Double(timeout), number.isFinite, number >= 0 else { throw OMPMCPDocument.invalidField("timeout") }
            if original["timeout"]?.double != number { fields["timeout"] = .double(number) }
        }
        put("instructions", .bool(instructions), default: true)
        let value = JSONValue.object(fields)
        if validate { try OMPMCPDocument.validateServer(value) }
        return value
    }

    private static func pairs(_ value: JSONValue?) -> [OMPMCPKeyValue] {
        (value?.object ?? [:]).sorted { $0.key < $1.key }.map { OMPMCPKeyValue(key: $0.key, value: $0.value.string ?? "") }
    }

    private static func dictionary(_ entries: [OMPMCPKeyValue], caseInsensitive: Bool) throws -> JSONValue {
        var keys: Set<String> = []
        var values: [String: JSONValue] = [:]
        for entry in entries {
            // A pristine row is an input affordance, not native config.
            if entry.key.isEmpty, entry.value.isEmpty { continue }
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, keys.insert(caseInsensitive ? key.lowercased() : key).inserted else {
                throw OMPMCPDocument.failure("Environment variables and headers need unique, nonempty names.")
            }
            values[key] = .string(entry.value)
        }
        return .object(values)
    }
}
