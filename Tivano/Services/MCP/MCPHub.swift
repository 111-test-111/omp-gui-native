import Foundation
import Synchronization

enum MCPHubError: LocalizedError, Sendable {
    case unknownTool(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)."
        case .server(let message):
            return message
        }
    }
}

actor MCPHub {
    static let shared = MCPHub()

    /// Every server process started this run, so the app can end them as it quits: a
    /// `Process` child outlives its parent, and an `npx` server left behind would keep
    /// running until the Mac restarts.
    private static let liveProcesses = MCPLiveProcesses()

    nonisolated static func track(_ process: StdioProcess) { liveProcesses.add(process) }

    /// Ends every running server at once. Called from `applicationWillTerminate`, where
    /// nothing asynchronous would get to run.
    nonisolated static func terminateAll() { liveProcesses.terminateAll() }

    struct Tool: Sendable, Hashable {
        let server: String
        let name: String
        let description: String
        let inputSchema: JSONValue

        var callName: String { "mcp__" + server + "__" + name }
    }

    struct Result: Sendable {
        let text: String
        let isError: Bool
    }

    private var specs: [String: MCPServerSpec]?
    private var clients: [String: MCPClient] = [:]
    private var toolCache: [String: [Tool]] = [:]
    private var failed: Set<String> = []

    func tools() async -> [Tool] {
        if specs == nil { specs = Self.readSpecs() }
        guard let current = specs else { return [] }
        var all: [Tool] = []
        for id in current.keys.sorted() {
            if let cached = toolCache[id] {
                all += cached
                continue
            }
            if failed.contains(id) { continue }
            guard let spec = current[id] else { continue }
            let client = self.client(for: id, spec: spec)
            do {
                let listed = try await client.listTools()
                toolCache[id] = listed
                all += listed
            } catch {
                print("MCPHub: \(id): \(error.localizedDescription)")
                failed.insert(id)
                await client.stop()
            }
        }
        return all.sorted {
            if $0.server != $1.server { return $0.server < $1.server }
            return $0.name < $1.name
        }
    }

    func call(_ callName: String, arguments: JSONValue) async throws -> Result {
        if specs == nil { specs = Self.readSpecs() }
        guard let parsed = Self.parse(callName: callName),
              let spec = specs?[parsed.server]
        else { throw MCPHubError.unknownTool(callName) }
        if let cached = toolCache[parsed.server],
           !cached.contains(where: { $0.name == parsed.tool }) {
            throw MCPHubError.unknownTool(callName)
        }
        let client = self.client(for: parsed.server, spec: spec)
        do {
            return try await client.callTool(name: parsed.tool, arguments: arguments)
        } catch let error as MCPHubError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPHubError.server(error.localizedDescription)
        }
    }

    func reload() {
        let existing = clients
        clients = [:]
        toolCache = [:]
        failed = []
        specs = nil
        for client in existing.values { Task { await client.stop() } }
    }

    nonisolated static func parse(callName: String) -> (server: String, tool: String)? {
        guard callName.hasPrefix("mcp__") else { return nil }
        let rest = callName.dropFirst("mcp__".count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    private func client(for id: String, spec: MCPServerSpec) -> MCPClient {
        if let existing = clients[id] { return existing }
        let created = MCPClient(id: id, spec: spec)
        clients[id] = created
        return created
    }

    nonisolated private static func readSpecs() -> [String: MCPServerSpec] {
        guard let data = try? Data(contentsOf: MCPPaths.claudeConfigURL),
              let parsed = JSONValue.parse(data),
              let servers = parsed["mcpServers"]?.object
        else { return [:] }
        var out: [String: MCPServerSpec] = [:]
        for (id, entry) in servers {
            if let command = entry["command"]?.string, !command.isEmpty {
                let args = entry["args"]?.array?.compactMap(\.string) ?? []
                var env: [String: String] = [:]
                for (key, value) in entry["env"]?.object ?? [:] {
                    if let string = value.string { env[key] = string }
                }
                out[id] = .stdio(command: command, args: args, env: env)
            } else if let url = entry["url"]?.string, !url.isEmpty {
                var headers: [String: String] = [:]
                for (key, value) in entry["headers"]?.object ?? [:] {
                    if let string = value.string { headers[key] = string }
                }
                out[id] = .http(url: url, headers: headers)
            }
        }
        return out
    }
}

private enum MCPServerSpec: Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(url: String, headers: [String: String])
}

private actor MCPClient {
    let id: String
    let spec: MCPServerSpec

    private var stdio: MCPStdioConnection?
    private var nextID = 1
    private var initialized = false
    private var didRestart = false
    private var dead = false
    private var sessionID: String?

    init(id: String, spec: MCPServerSpec) {
        self.id = id
        self.spec = spec
    }

    func stop() {
        stdio?.stop()
        stdio = nil
        initialized = false
        sessionID = nil
    }

    func listTools() async throws -> [MCPHub.Tool] {
        let items = try await MCPWire.listTools { params in
            try await self.rpc(method: "tools/list", params: params, timeout: 60)
        }
        return items.compactMap { item in
            guard let name = item["name"]?.string else { return nil }
            let rawDescription = item["description"]?.string ?? ""
            let schema: JSONValue
            if let found = item["inputSchema"], found.object != nil {
                schema = found
            } else {
                schema = .object(["type": .string("object"), "properties": .object([:])])
            }
            return MCPHub.Tool(
                server: id,
                name: name,
                description: String(rawDescription.prefix(400)),
                inputSchema: schema
            )
        }
    }

    func callTool(name: String, arguments: JSONValue) async throws -> MCPHub.Result {
        let args: JSONValue = arguments.isNull ? .object([:]) : arguments
        let reply = try await rpc(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": args]),
            timeout: 120
        )
        let result = reply["result"]
        var lines: [String] = []
        for item in result?["content"]?.array ?? [] {
            if let text = item["text"]?.string {
                lines.append(text)
            } else if item["type"]?.string == "image" {
                lines.append("[image]")
            } else if item["type"]?.string == "resource" {
                lines.append("[resource: \(item["resource"]?["uri"]?.string ?? "")]")
            }
        }
        return MCPHub.Result(
            text: lines.joined(separator: "\n"),
            isError: result?["isError"]?.bool ?? false
        )
    }

    private func rpc(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        switch spec {
        case .stdio(let command, let args, let env):
            return try await stdioRPC(command: command, args: args, env: env, method: method, params: params, timeout: timeout)
        case .http(let url, let headers):
            return try await httpRPC(urlString: url, headers: headers, method: method, params: params, timeout: timeout)
        }
    }

    private func checkReply(_ value: JSONValue) throws {
        if let message = MCPWire.errorMessage(in: value) {
            throw MCPHubError.server(message)
        }
    }

    // MARK: - Local servers over stdio

    private func stdioRPC(command: String, args: [String], env: [String: String], method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        try await ensureStdio(command: command, args: args, env: env)
        guard let connection = stdio else {
            throw MCPHubError.server("The server quit.")
        }
        return try await stdioReply(connection, method: method, params: params, timeout: timeout)
    }

    private func stdioReply(_ connection: MCPStdioConnection, method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        do {
            let reply = try await connection.request(method, params, timeout: timeout)
            try checkReply(reply)
            return reply
        } catch let error as MCPWireError {
            switch error {
            case .exited(let code):
                throw MCPHubError.server(code.map { "The server quit (exit \($0))." } ?? "The server quit.")
            case .timedOut:
                throw MCPHubError.server("The server didn't answer in time.")
            }
        }
    }

    private func ensureStdio(command: String, args: [String], env: [String: String]) async throws {
        if dead { throw MCPHubError.server("The server quit.") }
        if let connection = stdio, connection.process.isRunning, initialized { return }
        if stdio != nil {
            if didRestart {
                dead = true
                throw MCPHubError.server("The server quit.")
            }
            didRestart = true
        }
        try await startStdio(command: command, args: args, env: env)
    }

    private func startStdio(command: String, args: [String], env: [String: String]) async throws {
        guard let executable = LoginEnvironment.which(command, in: LoginEnvironment.current) else {
            throw MCPHubError.server("\(command) isn't installed.")
        }
        var environment = LoginEnvironment.current
        for (key, value) in env { environment[key] = value }

        let connection: MCPStdioConnection
        do {
            connection = try MCPStdioConnection.launch(executable: executable, arguments: args, environment: environment)
        } catch {
            throw MCPHubError.server(error.localizedDescription)
        }
        stdio = connection
        MCPHub.track(connection.process)
        do {
            let reply = try await stdioReply(connection, method: "initialize", params: MCPWire.initializeParams(), timeout: 60)
            guard reply["result"]?.object != nil else {
                throw MCPHubError.server("The server sent something unexpected: missing result.")
            }
            connection.notify("notifications/initialized")
            initialized = true
        } catch {
            stop()
            if error is MCPHubError || error is CancellationError { throw error }
            throw MCPHubError.server(error.localizedDescription)
        }
    }

    // MARK: - Remote servers over streamable HTTP

    private func httpRPC(urlString: String, headers: [String: String], method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard let url = URL(string: urlString) else {
            throw MCPHubError.server("The server address is invalid.")
        }
        if !initialized {
            let id = nextID
            nextID += 1
            let posted = try await post(url: url, headers: headers, payload: MCPWire.request(id: id, method: "initialize", params: MCPWire.initializeParams()), id: id, timeout: 60)
            guard let body = posted.body else {
                throw MCPHubError.server("The server sent something unexpected: empty reply.")
            }
            try checkReply(body)
            guard body["result"]?.object != nil else {
                throw MCPHubError.server("The server sent something unexpected: missing result.")
            }
            sessionID = posted.sessionID ?? sessionID
            initialized = true
            do {
                _ = try await post(url: url, headers: headers, payload: MCPWire.notification(method: "notifications/initialized"), id: nil, timeout: 30)
            } catch {
                if error is CancellationError { throw error }
            }
        }
        let id = nextID
        nextID += 1
        let posted = try await post(url: url, headers: headers, payload: MCPWire.request(id: id, method: method, params: params), id: id, timeout: timeout)
        guard let body = posted.body else {
            throw MCPHubError.server("The server sent something unexpected: empty reply.")
        }
        try checkReply(body)
        return body
    }

    private func post(url: URL, headers: [String: String], payload: JSONValue, id: Int?, timeout: TimeInterval) async throws -> MCPHTTPReply {
        do {
            return try await MCPWire.post(to: url, headers: headers, sessionID: sessionID, payload: payload, id: id, timeout: timeout)
        } catch let error as MCPHTTPError {
            guard let status = error.status else {
                throw MCPHubError.server("The server sent something unexpected: invalid reply.")
            }
            throw MCPHubError.server("The server answered \(status).")
        }
    }
}

/// The server processes alive this run, behind a lock so the quit path can reach them
/// from any thread without an actor hop.
private final class MCPLiveProcesses: Sendable {
    private let state = Mutex<[StdioProcess]>([])

    func add(_ process: StdioProcess) {
        state.withLock { processes in
            processes.removeAll { !$0.isRunning }
            processes.append(process)
        }
    }

    func terminateAll() {
        let running = state.withLock { $0.filter(\.isRunning) }
        for process in running { process.terminate() }
        // The app is quitting, so the delayed SIGKILL in terminate() never fires.
        for process in running where process.isRunning {
            let pid = process.processIdentifier
            kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
    }
}
