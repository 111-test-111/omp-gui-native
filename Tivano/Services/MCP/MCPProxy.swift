import Foundation
import Network
import OSLog
import Synchronization

final class MCPProxy: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "mcp-proxy")
    static let shared = MCPProxy()

    /// The proxy's port, kept in the library so the provider configs written on one launch
    /// still point at it on the next. Re-picked when the saved port cannot be bound: the
    /// Dev build runs over a mirror of the release library, so both would otherwise ask for
    /// the same one, and the second to launch would answer nothing.
    static var port: UInt16 { portBox.withLock { $0 } }

    private static let portBox = Mutex<UInt16>(loadPort())
    private static let portFile = MCPPaths.directory.appendingPathComponent("proxy-port")

    private static func loadPort() -> UInt16 {
        if let text = try? String(contentsOf: portFile, encoding: .utf8),
           let saved = UInt16(text.trimmed), saved != 0 {
            return saved
        }
        let picked = pickFreePort()
        try? "\(picked)".write(to: portFile, atomically: true, encoding: .utf8)
        return picked
    }

    /// Moves to a fresh port after the saved one refused to bind, and remembers it.
    private static func repickPort() -> UInt16 {
        let picked = pickFreePort()
        portBox.withLock { $0 = picked }
        try? "\(picked)".write(to: portFile, atomically: true, encoding: .utf8)
        return picked
    }

    static func url(for serverID: String) -> String {
        "http://127.0.0.1:\(port)/mcp/\(serverID)"
    }

    private struct Route: Sendable {
        var upstream: String
        var headers: [String: String]
        var usesOAuth: Bool
    }

    private struct ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
    }

    private static let headLimit = 65_536
    private static let bodyLimit = 32 * 1_024 * 1_024
    private static let divider = Data("\r\n\r\n".utf8)

    private let queue = DispatchQueue(label: "MCPProxy")

    private struct State {
        var routes: [String: Route] = [:]
        var listener: NWListener?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var running = false
    }

    private let state = Mutex(State())

    private init() {}

    func register(serverID: String, upstream: String, headers: [String: String], usesOAuth: Bool) {
        state.withLock {
            $0.routes[serverID] = Route(upstream: upstream, headers: headers, usesOAuth: usesOAuth)
        }
    }

    func unregister(serverID: String) {
        state.withLock { _ = $0.routes.removeValue(forKey: serverID) }
    }

    func replaceAll(_ routes: [(serverID: String, upstream: String, headers: [String: String], usesOAuth: Bool)]) {
        state.withLock {
            $0.routes = Dictionary(uniqueKeysWithValues: routes.map { entry in
                (entry.serverID, Route(upstream: entry.upstream, headers: entry.headers, usesOAuth: entry.usesOAuth))
            })
        }
    }

    func start() {
        let alreadyRunning = state.withLock { state -> Bool in
            if state.running { return true }
            state.running = true
            return false
        }
        if alreadyRunning { return }
        listen(on: Self.port, canRepick: true)
    }

    /// Binds the loopback listener. The port rides in the required local endpoint alone:
    /// naming it a second time through `NWListener(using:on:)` is rejected outright
    /// (EINVAL), which left the proxy silent and every OAuth server unreachable. A port
    /// already taken (another copy of the app) fails only once the listener starts, so
    /// that case moves to a fresh port and tries again, once.
    private func listen(on port: UInt16, canRepick: Bool) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        guard let listener = try? NWListener(using: parameters) else {
            Self.log.error("could not listen on \(port)")
            state.withLock { $0.running = false }
            return
        }
        state.withLock { $0.listener = listener }
        listener.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                Self.log.info("listening on \(port)")
            case .failed(let error):
                Self.log.error("listener on \(port) failed: \(error)")
                guard let self else { return }
                listener.cancel()
                self.state.withLock { state in
                    if state.listener === listener { state.listener = nil }
                }
                if canRepick {
                    self.listen(on: Self.repickPort(), canRepick: false)
                } else {
                    self.state.withLock { $0.running = false }
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        let (listener, open) = state.withLock { state -> (NWListener?, [NWConnection]) in
            let listener = state.listener
            let open = Array(state.connections.values)
            state.listener = nil
            state.connections.removeAll()
            state.running = false
            return (listener, open)
        }
        listener?.cancel()
        for connection in open {
            connection.cancel()
        }
    }

    /// A loopback port nobody holds, from the kernel: bind port 0, read back what it gave,
    /// let it go. A listener asked for an ephemeral port instead fails with EINVAL on
    /// current macOS, which is how every launch used to end up on the same fallback.
    private static func pickFreePort() -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return 48123 }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound else { return 48123 }
        let picked = UInt16(bigEndian: address.sin_port)
        return picked == 0 ? 48123 : picked
    }

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections[ObjectIdentifier(connection)] = connection }
        connection.start(queue: queue)
        readHead(connection, Data())
    }

    private func forget(_ connection: NWConnection) {
        state.withLock { _ = $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    private func readHead(_ connection: NWConnection, _ prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headLimit) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = prefix
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if let divider = buffer.range(of: Self.divider) {
                let head = buffer[buffer.startIndex..<divider.lowerBound]
                let rest = buffer[divider.upperBound..<buffer.endIndex]
                self.handleExchange(connection: connection, head: Data(head), rest: Data(rest))
                return
            }
            if buffer.count > Self.headLimit {
                self.respond(connection: connection, status: 413, body: Self.jsonError("request head too large"))
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                self.forget(connection)
                return
            }
            self.readHead(connection, buffer)
        }
    }

    private static func parseHead(_ head: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: head, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                headers[name] = value
            }
        }
        return (String(parts[0]), String(parts[1]), headers)
    }

    private func handleExchange(connection: NWConnection, head: Data, rest: Data) {
        guard let (method, path, clientHeaders) = Self.parseHead(head) else {
            respond(connection: connection, status: 400, body: Self.jsonError("bad request"))
            return
        }
        if let transferEncoding = clientHeaders["transfer-encoding"],
           transferEncoding.lowercased().contains("chunked") {
            respond(connection: connection, status: 411, body: Self.jsonError("chunked request bodies are not supported"))
            return
        }
        let contentLength = max(0, clientHeaders["content-length"].flatMap(Int.init) ?? 0)
        if contentLength > Self.bodyLimit {
            respond(connection: connection, status: 413, body: Self.jsonError("request body too large"))
            return
        }
        if rest.count >= contentLength {
            routeRequest(connection: connection, method: method, path: path, clientHeaders: clientHeaders, body: Data(rest.prefix(contentLength)))
        } else {
            readBody(connection: connection, method: method, path: path, clientHeaders: clientHeaders, buffer: rest, need: contentLength)
        }
    }

    private func readBody(connection: NWConnection, method: String, path: String, clientHeaders: [String: String], buffer: Data, need: Int) {
        if buffer.count >= need {
            routeRequest(connection: connection, method: method, path: path, clientHeaders: clientHeaders, body: Data(buffer.prefix(need)))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(need - buffer.count, Self.headLimit)) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data, !data.isEmpty {
                next.append(data)
            }
            if next.count >= need {
                self.routeRequest(connection: connection, method: method, path: path, clientHeaders: clientHeaders, body: Data(next.prefix(need)))
            } else if isComplete || error != nil {
                self.routeRequest(connection: connection, method: method, path: path, clientHeaders: clientHeaders, body: next)
            } else {
                self.readBody(connection: connection, method: method, path: path, clientHeaders: clientHeaders, buffer: next, need: need)
            }
        }
    }

    private func routeRequest(connection: NWConnection, method: String, path: String, clientHeaders: [String: String], body: Data) {
        let bare = String(path.prefix(upTo: path.firstIndex(of: "?") ?? path.endIndex))
        // A path the proxy holds no route for is a bad gateway, never a 404: the app reads a 404
        // seen through the proxy as the server's own answer (GitLab answers 404 while MCP is off).
        guard bare.hasPrefix("/mcp/") else {
            respond(connection: connection, status: 502, body: Self.jsonError("unknown server"))
            return
        }
        let serverID = String(bare.dropFirst("/mcp/".count))
        guard !serverID.isEmpty, !serverID.contains("/") else {
            respond(connection: connection, status: 502, body: Self.jsonError("unknown server"))
            return
        }
        let route = state.withLock { $0.routes[serverID] }
        guard let route else {
            respond(connection: connection, status: 502, body: Self.jsonError("unknown server"))
            return
        }
        let box = ConnectionBox(connection: connection)
        Task { [weak self] in
            guard let self else {
                box.connection.cancel()
                return
            }
            do {
                try await self.sendUpstream(box: box, serverID: serverID, route: route, method: method, clientHeaders: clientHeaders, body: body)
            } catch {
                Self.log.error("request to '\(serverID)' failed: \(error.localizedDescription)")
                self.respond(connection: box.connection, status: 502, body: Self.jsonError("upstream request failed"))
            }
        }
    }

    private func sendUpstream(box: ConnectionBox, serverID: String, route: Route, method: String, clientHeaders: [String: String], body: Data) async throws {
        guard let upstreamURL = URL(string: route.upstream) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = method
        request.timeoutInterval = 3_600
        let passthrough = [
            ("content-type", "Content-Type"),
            ("accept", "Accept"),
            ("mcp-session-id", "Mcp-Session-Id"),
            ("mcp-protocol-version", "MCP-Protocol-Version"),
            ("last-event-id", "Last-Event-ID"),
        ]
        for (clientName, canonicalName) in passthrough {
            if let value = clientHeaders[clientName] {
                request.setValue(value, forHTTPHeaderField: canonicalName)
            }
        }
        for (name, value) in route.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if route.usesOAuth {
            let token: String
            do {
                token = try await MCPOAuth.accessToken(serverID: serverID)
            } catch {
                respond(connection: box.connection, status: 401, body: Self.jsonError(error.localizedDescription))
                return
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if !body.isEmpty {
            request.httpBody = body
        }
        var (stream, response) = try await URLSession.shared.bytes(for: request)
        var http = response as? HTTPURLResponse
        if route.usesOAuth, http?.statusCode == 401 {
            if let refreshed = try? await MCPOAuth.accessToken(serverID: serverID) {
                request.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
                (stream, response) = try await URLSession.shared.bytes(for: request)
                http = response as? HTTPURLResponse
            }
        }
        guard let http else {
            throw URLError(.badServerResponse)
        }
        try await writeBack(box: box, response: http, stream: stream)
    }

    private func writeBack(box: ConnectionBox, response: HTTPURLResponse, stream: URLSession.AsyncBytes) async throws {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        var headers: [(String, String)] = []
        if let contentType {
            headers.append(("Content-Type", contentType))
        }
        if let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            headers.append(("Mcp-Session-Id", sessionID))
        }
        if let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") {
            headers.append(("Cache-Control", cacheControl))
        }
        let connection = box.connection
        if contentType?.lowercased().contains("text/event-stream") == true {
            headers.append(("Transfer-Encoding", "chunked"))
            headers.append(("Connection", "close"))
            await send(connection, Data(Self.statusHead(status: response.statusCode, headers: headers).utf8))
            do {
                var buffer = Data()
                for try await byte in stream {
                    buffer.append(byte)
                    if byte == UInt8(ascii: "\n") {
                        await send(connection, Self.chunk(buffer))
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    await send(connection, Self.chunk(buffer))
                }
            } catch {
            }
            await send(connection, Data("0\r\n\r\n".utf8))
            connection.cancel()
            forget(connection)
        } else {
            var payload = Data()
            if response.expectedContentLength > 0 {
                payload.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in stream {
                payload.append(byte)
            }
            headers.append(("Content-Length", "\(payload.count)"))
            headers.append(("Connection", "close"))
            var out = Data(Self.statusHead(status: response.statusCode, headers: headers).utf8)
            out.append(payload)
            await send(connection, out)
            connection.cancel()
            forget(connection)
        }
    }

    private static func chunk(_ payload: Data) -> Data {
        var frame = Data((String(payload.count, radix: 16) + "\r\n").utf8)
        frame.append(payload)
        frame.append(Data("\r\n".utf8))
        return frame
    }

    private func send(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    private func respond(connection: NWConnection, status: Int, body: Data) {
        var out = Data(Self.statusHead(status: status, headers: [
            ("Content-Type", "application/json"),
            ("Content-Length", "\(body.count)"),
            ("Connection", "close"),
        ]).utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.forget(connection)
        })
    }

    private static func statusHead(status: Int, headers: [(String, String)]) -> String {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return head
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default:
            if (200..<300).contains(status) { "OK" } else { "Error" }
        }
    }

    private static func jsonError(_ message: String) -> Data {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return Data("{\"error\":\"\(escaped)\"}".utf8)
    }
}
