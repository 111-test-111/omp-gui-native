import Foundation

extension OMPSession {
    /// The registered extension command is intercepted by OMP before prompt
    /// admission, including during streaming. It never appends a user message.
    func inspectContext() async throws -> OMPContextLiveInspection? {
        guard contextInspectionAvailable, contextSnapshot.pendingCommand == nil,
              !nativeHistoryTransitionInFlight else { return nil }
        guard isRunning, !isDraining else { throw ProviderError.notRunning }
        let id = UUID().uuidString, file = sessionFile
        contextInspectionRequests.insert(id)
        defer { contextInspectionRequests.remove(id) }
        let result = try await contextInspectionReplies.register(id, timeout: .seconds(5),
            timeoutValue: ["success": false, "error": "timeout"]) {
            rpc.send(["type": "prompt", "id": .string("omp-gui-context-" + id),
                      "message": .string("/omp-gui-context " + JSONValue.object(["requestID": .string(id)]).compactString)]) { [weak self] delivered in
                if !delivered { self?.contextInspectionReplies.fail(id, ProviderError.notRunning) }
            }
        }
        try Task.checkCancellation()
        guard isRunning, sessionFile == file else { throw CancellationError() }
        if result["error"]?.string == "unsupported" { contextInspectionAvailable = false; return nil }
        guard result["success"]?.bool == true, let snapshot = OMPContextLiveInspection(result), snapshot.file == file else {
            throw ProviderError.failed(AppText.localized("Could not read OMP's detailed context snapshot."))
        }
        return snapshot
    }

    func handleContextInspection(_ frame: JSONValue) -> Bool {
        if frame["type"]?.string == "extension_ui_request", frame["method"]?.string == "notify",
           let message = frame["message"]?.string, message.hasPrefix("OMP_GUI_CONTEXT_RESULT:") {
            if let value = JSONValue.parse(String(message.dropFirst("OMP_GUI_CONTEXT_RESULT:".count))),
               let id = value["requestID"]?.string, contextInspectionRequests.contains(id) {
                contextInspectionReplies.resolve(id, value)
            }
            return true
        }
        if let id = frame["id"]?.string, id.hasPrefix("omp-gui-context-") {
            if frame["type"]?.string == "response", frame["success"]?.bool == false {
                contextInspectionReplies.fail(String(id.dropFirst("omp-gui-context-".count)),
                    ProviderError.failed(AppText.localized("Could not read OMP's detailed context snapshot.")))
            }
            return true
        }
        return false
    }
}
