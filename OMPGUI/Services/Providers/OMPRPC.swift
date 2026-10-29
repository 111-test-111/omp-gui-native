import Foundation

/// OMP's public NDJSON protocol. RPC replies are correlated before sending and
/// failures, cancellation and process exit always settle their waiting callers.
@MainActor
final class OMPRPC {
    private(set) var isDraining = false
    var onFrame: ((JSONValue) -> Void)?
    var onExit: ((String?) -> Void)?
    var onCapabilitiesChanged: ((OMPCapabilities) -> Void)?
    private(set) var capabilities = OMPCapabilities()
    private var controlProbes: Set<String> = []
    private(set) var process: StdioProcess?
    private var reader: Task<Void, Never>?
    private let pending = PendingReplies<JSONValue>()
    private var stopped = false
    private var exitError: String?

    var isRunning: Bool { !stopped && process?.isRunning == true }

    func confirmQueueBridge() {
        let previous = capabilities
        capabilities.confirmQueueBridge()
        if capabilities != previous { onCapabilitiesChanged?(capabilities) }
    }

    func start(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
        isDraining = false
        exitError = nil
        stopped = false
        capabilities = OMPCapabilities()
        controlProbes.removeAll()
        // Every GUI RPC process, including account/model discovery helpers,
        // starts with memory off. The opt-in SDK host overrides it in memory
        // only after repository scope and lifecycle support are established.
        let memoryOverlay = FileManager.default.temporaryDirectory.appendingPathComponent("omp-gui-memory-\(UUID().uuidString).json")
        try Data("{\"memory\":{\"backend\":\"off\"}}".utf8).write(to: memoryOverlay, options: .atomic)
        let child = StdioProcess(executable: executable, arguments: arguments + ["--config", memoryOverlay.path], directory: directory, environment: environment, reassemblesOMPChunks: true)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: memoryOverlay.path)
            try child.start()
        }
        catch { try? FileManager.default.removeItem(at: memoryOverlay); throw error }
        process = child
        let messages = child.messages
        reader = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: memoryOverlay) }
            for await frame in messages { self?.receive(frame) }
            let status = await child.waitForExit()
            guard let self else { return }
            let error = stopped || (isDraining && status == 0 && child.failureReason == nil) ? nil : child.failureReason ?? TextCleanup.lastLines(child.errorTail)
                ?? String(format: AppText.localized("OMP exited with status %lld."), Int64(status))
            pending.failAll(ProviderError.failed(error ?? AppText.localized("OMP connection closed.")))
            exitError = error
            onExit?(error)
        }
    }

    func request(_ type: String, fields: [String: JSONValue] = [:], id: String = UUID().uuidString, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let reply = try await response(type, fields: fields, id: id, timeout: timeout)
        guard reply["success"]?.bool == true else {
            throw ProviderError.failed(reply["error"]?.string ?? AppText.localized("OMP rejected the request."))
        }
        return reply["data"] ?? .null
    }

    /// Retains native validation failures for harmless capability probes.
    func response(_ type: String, fields: [String: JSONValue] = [:], id: String = UUID().uuidString, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard isRunning, !isDraining, let process else { throw ProviderError.notRunning }
        let span = RuntimeMetrics.begin(.rpcRequest)
        defer { RuntimeMetrics.end(span) }
        var command = fields
        command["type"] = .string(type)
        command["id"] = .string(id)
        let reply = try await pending.register(id, timeout: timeout) { process.send(.object(command)) }
        guard reply["command"]?.string == type else {
            throw ProviderError.failed(AppText.localized("OMP returned a response for a different command."))
        }
        // Only a reply to this process's outstanding request is evidence.
        // Late, unsolicited or mismatched replies must not change capabilities.
        let previous = capabilities
        capabilities.observe(reply)
        if capabilities != previous { onCapabilitiesChanged?(capabilities) }
        return reply
    }

    /// Only these empty requests are known to be non-mutating: neither can
    /// address a worker. Cache even an inconclusive probe for this process.
    func probeSubagentControl(_ command: String) async -> OMPCapabilities.Support {
        guard ["cancel_subagent", "steer_subagent"].contains(command) else { return .unknown }
        guard capabilities[command] == .unknown, controlProbes.insert(command).inserted else { return capabilities[command] }
        _ = try? await response(command, timeout: .seconds(5))
        return capabilities[command]
    }

    func send(_ frame: JSONValue, delivered: (@MainActor (Bool) -> Void)? = nil) {
        guard isRunning, !isDraining, let process else { delivered?(false); return }
        process.send(frame) { accepted in
            Task { @MainActor in delivered?(accepted) }
        }
    }

    /// Keep reading until native disposal and its output writer actually finish.
    /// There is deliberately no timeout that turns this into an implicit SIGTERM.
    func beginDrain() -> Bool {
        guard isRunning, let process else { return false }
        if !isDraining { isDraining = true; process.closeInput() }
        return true
    }

    func drainAndWait() async throws {
        guard beginDrain() else { throw ProviderError.notRunning }
        await reader?.value
        guard !stopped else { throw CancellationError() }
        if let exitError { throw ProviderError.failed(exitError) }
    }

    func stop() {
        stopped = true
        pending.failAll(CancellationError())
        process?.terminate()
    }

    func stopAndWait(timeout: TimeInterval) async {
        let span = RuntimeMetrics.begin(.processShutdown)
        defer { RuntimeMetrics.end(span) }
        stop()
        await process?.terminateAndWait(timeout: timeout)
    }

    private func receive(_ frame: JSONValue) {
        if frame["type"]?.string == "response", let id = frame["id"]?.string {
            if pending.resolve(id, frame) { return }
        }
        onFrame?(frame)
    }
}
