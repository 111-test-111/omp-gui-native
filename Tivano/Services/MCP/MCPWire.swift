import Foundation
import Synchronization

/// The wire pieces MCPHub and MCPProbe share. The HTTP POST returns at the first SSE
/// message with a matching id, so a stream the server holds open doesn't hang it.
enum MCPWire {
    nonisolated static let protocolVersion = "2025-06-18"

    nonisolated static func initializeParams() -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Tivano"), "version": .string("1.0")]),
        ])
    }

    nonisolated static func request(id: Int, method: String, params: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    nonisolated static func notification(method: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method)])
    }

    nonisolated static func errorMessage(in value: JSONValue) -> String? {
        guard let error = value["error"], error.object != nil else { return nil }
        return error["message"]?.string ?? "unknown error"
    }

    /// Paging for `tools/list`: ten pages at most, each cursor fed back until the server
    /// stops handing one out. The caller owns the request and its error type.
    nonisolated static func listTools(_ page: (JSONValue) async throws -> JSONValue) async throws -> [JSONValue] {
        var tools: [JSONValue] = []
        var cursor: String?
        for _ in 0..<10 {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let reply = try await page(.object(params))
            let list = reply["result"]
            tools += list?["tools"]?.array ?? []
            guard let next = list?["nextCursor"]?.string, !next.isEmpty else { break }
            cursor = next
        }
        return tools
    }

    // MARK: - Streamable HTTP

    nonisolated static func post(
        to url: URL,
        headers: [String: String],
        sessionID: String?,
        payload: JSONValue,
        id: Int?,
        timeout: TimeInterval
    ) async throws -> MCPHTTPReply {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = payload.data()
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPHTTPError(status: nil, body: "")
        }
        let session = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 2_000 { break }
            }
            throw MCPHTTPError(status: http.statusCode, body: String(decoding: data, as: UTF8.self).trimmed)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.contains("text/event-stream") else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard !data.isEmpty else { return MCPHTTPReply(sessionID: session, body: nil) }
            return MCPHTTPReply(sessionID: session, body: JSONValue.parse(data))
        }
        guard let id else { return MCPHTTPReply(sessionID: session, body: nil) }
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let text = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let value = JSONValue.parse(String(text)),
                  value.object != nil, value["id"]?.int == id
            else { continue }
            return MCPHTTPReply(sessionID: session, body: value)
        }
        return MCPHTTPReply(sessionID: session, body: nil)
    }
}

struct MCPHTTPReply: Sendable {
    let sessionID: String?
    let body: JSONValue?
}

struct MCPHTTPError: Error, Sendable {
    let status: Int?
    let body: String
}

enum MCPWireError: Error, Sendable {
    case exited(Int32?)
    case timedOut
}

/// A stdio MCP server; each request waits on a continuation for the reply with its id.
final class MCPStdioConnection: Sendable {
    let process: StdioProcess

    private struct State {
        var nextID = 1
        var pending: [RPCID: CheckedContinuation<JSONValue, Error>] = [:]
        var buffered: [RPCID: JSONValue] = [:]
        var exitStatus: Int32?
        var closed = false
    }

    private let state = Mutex(State())

    init(process: StdioProcess) {
        self.process = process
    }

    static func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> MCPStdioConnection {
        let process = StdioProcess(
            executable: executable,
            arguments: arguments,
            directory: FileManager.default.homeDirectoryForCurrentUser,
            environment: environment
        )
        let connection = MCPStdioConnection(process: process)
        try process.start()
        connection.read()
        return connection
    }

    func stop() {
        process.terminate()
    }

    var errorTail: String { process.errorTail }

    func notify(_ method: String) {
        process.send(MCPWire.notification(method: method))
    }

    func request(_ method: String, _ params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard process.isRunning else { throw MCPWireError.exited(await process.waitForExit()) }
        let id = state.withLock { state -> Int in
            let id = state.nextID
            state.nextID += 1
            return id
        }
        let key = RPCID.int(id)
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.awaitReply(key) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPWireError.timedOut
            }
            self.process.send(MCPWire.request(id: id, method: method, params: params))
            do {
                guard let value = try await group.next() else { throw MCPWireError.timedOut }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                self.abandon(key)
                throw error
            }
        }
    }

    private func read() {
        let messages = process.messages
        Task {
            for await message in messages { self.handle(message) }
            let status = await self.process.waitForExit()
            self.close(status: status)
        }
    }

    private func awaitReply(_ id: RPCID) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let immediate = self.state.withLock { state -> Result<JSONValue, Error>? in
                    if let value = state.buffered.removeValue(forKey: id) { return .success(value) }
                    if state.closed { return .failure(MCPWireError.exited(state.exitStatus)) }
                    state.pending[id] = continuation
                    return nil
                }
                switch immediate {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                case nil: break
                }
            }
        } onCancel: {
            self.abandon(id)
        }
    }

    private func handle(_ message: JSONValue) {
        guard let object = message.object,
              let rawID = object["id"], let id = RPCID(rawID) else { return }
        let continuation = state.withLock { state -> CheckedContinuation<JSONValue, Error>? in
            if let continuation = state.pending.removeValue(forKey: id) { return continuation }
            state.buffered[id] = message
            return nil
        }
        continuation?.resume(returning: message)
    }

    private func abandon(_ id: RPCID) {
        let continuation = state.withLock { $0.pending.removeValue(forKey: id) }
        continuation?.resume(throwing: CancellationError())
    }

    private func close(status: Int32?) {
        let pending = state.withLock { state -> [CheckedContinuation<JSONValue, Error>] in
            guard !state.closed else { return [] }
            state.closed = true
            state.exitStatus = status
            let pending = Array(state.pending.values)
            state.pending.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume(throwing: MCPWireError.exited(status)) }
    }
}
