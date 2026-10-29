import AppKit
import CefSwiftUI
import Observation

/// A one-time writer to a fresh profile. User pages continue using the launch
/// profile; the imported subset is selected only after its Cookies are checked.
@MainActor @Observable
final class BrowserCookieImporter {
    static let shared = BrowserCookieImporter()
    private(set) var isImporting = false
    @ObservationIgnored private var operation: Task<BrowserCookieImport, Error>?
    @ObservationIgnored private var hasUndrainedBrowser = false

    func importChrome(_ profile: ChromeCookieProfile, profileID: UUID) async throws -> BrowserCookieImport {
        guard !isImporting else { throw BrowserCookieImportError.busy }
        guard !hasUndrainedBrowser else { throw BrowserCookieImportError.unavailable }
        let known = BrowserProfileConfiguration.load()
        guard profileID != BrowserProfileConfiguration.activeProfile.id,
              !known.profiles.contains(where: { $0.id == profileID }), !known.pendingDeletionIDs.contains(profileID) else {
            throw BrowserCookieImportError.unavailable
        }
        isImporting = true
        let task = Task { @MainActor in
            let reader = Task.detached(priority: .userInitiated) { try ChromeCookieSource.read(profile) }
            let payload = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            try Task.checkCancellation()
            return try await write(payload, id: profileID)
        }
        operation = task
        defer { operation = nil; isImporting = false }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func cancel() { operation?.cancel() }

    func shutdown() async -> Bool {
        if let operation {
            operation.cancel()
            _ = try? await operation.value
        }
        return !hasUndrainedBrowser
    }

    private func write(_ payload: BrowserCookieImport, id: UUID) async throws -> BrowserCookieImport {
        try EmbeddedBrowserRuntime.shared.start()
        let profile = BrowserProfileRecord(id: id, name: "")
        let initialURL = URL(string: "about:blank#omp-cookie-import-" + id.uuidString.lowercased())!
        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy
        options.profile = .persistent(name: profile.storageName)
        let model = CefWebViewModel(url: initialURL, options: options)
        var created = false
        model.onBrowserCreated = { _ in created = true }
        model.onNavigation = { url in url?.absoluteString == initialURL.absoluteString ? .allow : .cancel }
        let host = CefBrowserHostView(model: model)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        EmbeddedBrowserRuntime.shared.park(host)
        host.layoutSubtreeIfNeeded()
        do {
            let deadline = ContinuousClock.now + .seconds(15)
            while !created {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw BrowserCookieImportError.unavailable }
                try await Task.sleep(for: .milliseconds(25))
            }
            let target = try await EmbeddedBrowserRuntime.shared.identifyPage(initialURL: initialURL)
            guard let endpoint = EmbeddedBrowserRuntime.shared.endpoint else { throw BrowserCookieImportError.unavailable }
            let client = try await BrowserCookieConnection.connect(endpoint: endpoint, targetID: target)
            let imported: BrowserCookieImport
            do {
                imported = try await Self.copyCookies(payload) { method, parameters in
                    try await client.call(method, parameters: parameters)
                }
                await client.close()
            } catch {
                await client.close()
                throw error
            }
            try Task.checkCancellation()
            guard await close(model: model, host: host) else { throw BrowserCookieImportError.unavailable }
            return imported
        } catch {
            _ = await close(model: model, host: host)
            // Only this never-published UUID can be cleaned after a failed import.
            // Cookie values are never staged as plaintext in the GUI library.
            discardUnpublishedProfile(id)
            if error is CancellationError { throw error }
            throw (error as? BrowserCookieImportError) ?? BrowserCookieImportError.unavailable
        }
    }

    /// The caller owns a fresh, unpublished page context, never the active
    /// browser's context or its browser-level CDP endpoint.
    static func copyCookies(_ payload: BrowserCookieImport,
                            call: (String, JSONValue) async throws -> JSONValue) async throws -> BrowserCookieImport {
        func readAll() async throws -> [JSONValue] {
            let response = try await call("Network.getAllCookies", [:])
            guard let cookies = response["cookies"]?.array else { throw BrowserCookieImportError.unavailable }
            guard cookies.count <= BrowserCookieImport.maximumCookies else { throw BrowserCookieImportError.tooLarge }
            return cookies
        }
        func install(_ batch: ArraySlice<BrowserCookieImport.Cookie>) async throws {
            try Task.checkCancellation()
            do {
                _ = try await call("Network.setCookies", ["cookies": .array(batch.map(\.parameters))])
            } catch BrowserCookieWriteError.invalidCookie {
                // Isolate only an explicitly rejected Cookie batch. Transport,
                // authorization and unknown protocol failures still abort.
                guard batch.count > 1 else { return }
                let middle = batch.index(batch.startIndex, offsetBy: batch.count / 2)
                try await install(batch[..<middle])
                try await install(batch[middle...])
            }
        }
        func installBatches(_ cookies: [BrowserCookieImport.Cookie]) async throws {
            for start in stride(from: 0, to: cookies.count, by: 128) {
                try await install(cookies[start..<min(start + 128, cookies.count)])
            }
        }
        guard try await readAll().isEmpty else { throw BrowserCookieImportError.unavailable }
        try await installBatches(payload.cookies)
        var stored = try await readAll()
        var imported = confirmed(payload.cookies, in: stored)
        if !retained(imported, in: stored) {
            // A native engine may normalize/drop a field without an error.
            // Clear only this new page's storage partition and replay the exact
            // verified subset, so skipped/mutated cookies cannot remain behind.
            _ = try await call("Network.clearBrowserCookies", [:])
            try await installBatches(imported)
            stored = try await readAll()
            imported = confirmed(imported, in: stored)
            guard retained(imported, in: stored) else { throw BrowserCookieImportError.rejected }
        }
        try Task.checkCancellation()
        let skipped = payload.skippedCount + payload.cookies.count - imported.count
        guard !imported.isEmpty else { throw BrowserCookieImportError.noImportableCookies(skipped) }
        return BrowserCookieImport(sourceProfileName: payload.sourceProfileName, cookies: imported, skippedCount: skipped)
    }

    private static func nativeIdentity(_ item: JSONValue) -> String? {
        guard let domain = item["domain"]?.string, let path = item["path"]?.string, let name = item["name"]?.string,
              let scheme = item["sourceScheme"]?.string, let port = item["sourcePort"]?.int,
              item["partitionKeyOpaque"]?.bool != true else { return nil }
        return [domain, path, name, item["partitionKey"]?["topLevelSite"]?.string ?? "",
            String(item["partitionKey"]?["hasCrossSiteAncestor"]?.bool ?? false), scheme, String(port)].joined(separator: "\u{0}")
    }

    private static func confirmed(_ expected: [BrowserCookieImport.Cookie], in actual: [JSONValue]) -> [BrowserCookieImport.Cookie] {
        var indexed: [String: JSONValue] = [:], ambiguous = Set<String>()
        for item in actual {
            guard let id = nativeIdentity(item) else { continue }
            if indexed.updateValue(item, forKey: id) != nil { ambiguous.insert(id) }
        }
        return expected.filter { cookie in
            guard !ambiguous.contains(cookie.identity), let item = indexed[cookie.identity] else { return false }
            return retained([cookie], in: [item])
        }
    }

    private func close(model: CefWebViewModel, host: CefBrowserHostView) async -> Bool {
        let browser = model.browser
        browser?.close(force: true)
        host.tearDown(); host.removeFromSuperview()
        model.options.profile = nil
        let deadline = ContinuousClock.now + .seconds(5)
        while browser?.isClosed == false, ContinuousClock.now < deadline {
            // Cleanup must keep yielding even when the import task was canceled.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { continuation.resume() }
            }
        }
        let drained = browser?.isClosed != false
        if !drained { hasUndrainedBrowser = true }
        return drained
    }

    func discardUnpublishedProfile(_ id: UUID) {
        guard !hasUndrainedBrowser, id != BrowserProfileConfiguration.activeProfile.id,
              !BrowserProfileConfiguration.load().profiles.contains(where: { $0.id == id }) else { return }
        let profile = BrowserProfileRecord(id: id, name: "")
        let directory = StoragePaths.directory("browser/profiles").appendingPathComponent("Profile-" + profile.storageName)
        try? FileManager.default.removeItem(at: directory)
    }

    static func retained(_ expected: [BrowserCookieImport.Cookie], in actual: [JSONValue]) -> Bool {
        guard expected.count == actual.count else { return false }
        var indexed: [String: JSONValue] = [:]
        for item in actual {
            guard let identity = nativeIdentity(item) else { return false }
            guard indexed.updateValue(item, forKey: identity) == nil else { return false }
        }
        return expected.allSatisfy { cookie in
                guard let item = indexed[cookie.identity], item["value"]?.string == cookie.value,
                      item["httpOnly"]?.bool == cookie.httpOnly, item["secure"]?.bool == cookie.secure,
                      item["session"]?.bool == cookie.session, item["priority"]?.string == cookie.priority else { return false }
                let sameSite = ["lax": "Lax", "strict": "Strict", "no_restriction": "None"][cookie.sameSite]
                if item["sameSite"]?.string != sameSite { return false }
                if !cookie.session, let expiry = cookie.expirationDate,
                   abs((item["expires"]?.double ?? 0) - expiry) > 1 { return false }
                if let key = cookie.partitionKey {
                    return item["partitionKey"]?["topLevelSite"]?.string == key.topLevelSite
                        && item["partitionKey"]?["hasCrossSiteAncestor"]?.bool == key.hasCrossSiteAncestor
                }
                return item["partitionKey"] == nil
        }
    }
}

enum BrowserCookieWriteError: Error {
    case invalidCookie

    static func isCookieRejection(method: String, error: JSONValue) -> Bool {
        method == "Network.setCookies" && error["code"]?.int == -32602
    }
}

private actor BrowserCookieConnection {
    let session: URLSession
    let socket: URLSessionWebSocketTask
    private var nextID = 0

    private init(session: URLSession, socket: URLSessionWebSocketTask) { self.session = session; self.socket = socket }

    static func connect(endpoint: URL, targetID: String) async throws -> BrowserCookieConnection {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        do {
            let (data, _) = try await session.data(from: endpoint.appendingPathComponent("json/list"))
            guard data.count <= 1_048_576, let targets = JSONValue.parse(data)?.array,
                  let target = targets.first(where: { $0["id"]?.string == targetID }),
                  let address = target["webSocketDebuggerUrl"]?.string, let url = URL(string: address),
                  url.scheme == "ws", url.host == "127.0.0.1", url.port == endpoint.port else { throw BrowserCookieImportError.unavailable }
            let socket = session.webSocketTask(with: url)
            socket.maximumMessageSize = 64 * 1_024 * 1_024
            socket.resume()
            return BrowserCookieConnection(session: session, socket: socket)
        } catch { session.invalidateAndCancel(); throw error }
    }

    func call(_ method: String, parameters: JSONValue = [:]) async throws -> JSONValue {
        nextID += 1
        let id = nextID, socket = socket
        let request: JSONValue = ["id": .int(id), "method": .string(method), "params": parameters]
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask {
                    try await socket.send(.string(request.compactString))
                    for _ in 0..<32 {
                        let message = try await socket.receive()
                        let value: JSONValue?
                        switch message {
                        case .data(let data): value = JSONValue.parse(data)
                        case .string(let text): value = JSONValue.parse(text)
                        @unknown default: value = nil
                        }
                        guard let value else { throw BrowserCookieImportError.unavailable }
                        guard value["id"]?.int == id else { continue }
                        if let error = value["error"] {
                            if BrowserCookieWriteError.isCookieRejection(method: method, error: error) { throw BrowserCookieWriteError.invalidCookie }
                            throw BrowserCookieImportError.unavailable
                        }
                        guard let result = value["result"] else { throw BrowserCookieImportError.unavailable }
                        return result
                    }
                    throw BrowserCookieImportError.unavailable
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    socket.cancel(with: .goingAway, reason: nil)
                    throw BrowserCookieImportError.unavailable
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }

    func close() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
