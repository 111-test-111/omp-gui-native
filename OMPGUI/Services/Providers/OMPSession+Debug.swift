import Foundation

extension OMPSession {
    func connectDebugObservation() async {
        guard let hello = try? await debugControl("hello"), hello["protocolVersion"]?.int == 1 else { return }
        debugSnapshot.supported = true
        debugSnapshot.connected = true
        debugSnapshot.sessionFile = sessionFile
        onEvent?(.ompDebug(debugSnapshot))
    }

    func inspectDebug(_ operation: String, snapshot: OMPDebugSnapshot, fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard ["stack", "scopes", "variables"].contains(operation), snapshot.canInspect,
              debugSnapshot.canInspect, snapshot.sessionFile == sessionFile,
              snapshot.stopToken == debugSnapshot.stopToken, let token = snapshot.stopToken,
              let sessionID = snapshot.session?.id else { throw CancellationError() }
        var fields = fields
        fields["stopToken"] = .string(token)
        fields["dapSessionID"] = .string(sessionID)
        let result = try await debugControl(operation, fields: fields)
        guard debugSnapshot.canInspect, debugSnapshot.stopToken == token,
              result["stopToken"]?.string == token, let data = result["data"] else { throw CancellationError() }
        if debugSnapshot.captureInspection(operation, fields: fields, data: data, expected: snapshot) {
            onEvent?(.ompDebug(debugSnapshot))
        }
        return data
    }

    private func debugControl(_ operation: String, fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard isRunning, !isDraining else { throw ProviderError.notRunning }
        let id = UUID().uuidString, file = sessionFile
        var payload = fields
        payload["requestID"] = .string(id); payload["operation"] = .string(operation)
        debugRequests[id] = operation
        defer { debugRequests[id] = nil }
        let result = try await withTaskCancellationHandler {
            try await debugReplies.register(id, timeout: .seconds(8),
                timeoutValue: ["success": false, "error": "inspection_failed"]) {
                rpc.send(["type": "prompt", "id": .string("omp-gui-debug-" + id),
                          "message": .string("/omp-gui-debug " + JSONValue.object(payload).compactString)]) { [weak self] delivered in
                    if !delivered { self?.debugReplies.fail(id, ProviderError.notRunning) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, isRunning, sessionFile == file else { return }
                let cancelID = UUID().uuidString
                let request: JSONValue = ["requestID": .string(cancelID), "operation": "cancel", "targetRequestID": .string(id)]
                rpc.send(["type": "prompt", "id": .string("omp-gui-debug-" + cancelID),
                          "message": .string("/omp-gui-debug " + request.compactString)])
            }
        }
        try Task.checkCancellation()
        guard isRunning, sessionFile == file else { throw CancellationError() }
        guard result["success"]?.bool == true else {
            if result["error"]?.string == "stale" { throw CancellationError() }
            throw ProviderError.failed(AppText.localized("Could not inspect this debug stop."))
        }
        return result
    }

    func handleDebugControl(_ frame: JSONValue) -> Bool {
        if frame["type"]?.string == "omp_gui_debug" {
            acceptDebugObservation(frame)
            return true
        }
        if frame["type"]?.string == "extension_ui_request", frame["method"]?.string == "notify", let message = frame["message"]?.string {
            if message.hasPrefix("OMP_GUI_DEBUG_RESULT:") {
                guard let result = JSONValue.parse(String(message.dropFirst("OMP_GUI_DEBUG_RESULT:".count))),
                      let id = result["requestID"]?.string, debugRequests[id] == result["operation"]?.string else { return true }
                debugReplies.resolve(id, result)
                return true
            }
            if message.hasPrefix("OMP_GUI_DEBUG_OBSERVATION:") {
                if let observation = JSONValue.parse(String(message.dropFirst("OMP_GUI_DEBUG_OBSERVATION:".count))) {
                    acceptDebugObservation(observation)
                }
                return true
            }
        }
        if let id = frame["id"]?.string, id.hasPrefix("omp-gui-debug-") {
            if frame["type"]?.string == "response", frame["success"]?.bool == false {
                debugReplies.fail(String(id.dropFirst("omp-gui-debug-".count)),
                    ProviderError.failed(AppText.localized("Could not inspect this debug stop.")))
            }
            return true
        }
        return false
    }

    private func acceptDebugObservation(_ frame: JSONValue) {
        guard !stopped, frame["sessionFile"]?.string == sessionFile, !sessionFile.isEmpty else { return }
        let previous = debugSnapshot
        debugSnapshot.observe(frame)
        if debugSnapshot != previous {
            onEvent?(.ompDebug(debugSnapshot))
            publishActivity()
        }
    }

    func disconnectDebugObservation() {
        debugReplies.failAll(ProviderError.notRunning)
        debugSnapshot.disconnect()
        onEvent?(.ompDebug(debugSnapshot))
    }
}
