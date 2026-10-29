import Foundation

extension OMPSession {
    func inspectMemory() async throws -> OMPMemoryInspection {
        OMPMemoryInspection(try await memoryControl("inspect"))
    }

    func previewMemory(_ file: OMPMemoryFile) async throws -> OMPMemoryPreview {
        let value = try await memoryControl("preview", fields: ["bank": .string(file.bank), "path": .string(file.path)])
        guard value["bank"]?.string == file.bank, value["path"]?.string == file.path else {
            throw ProviderError.failed(AppText.localized("This memory file is no longer available for the selected conversation."))
        }
        return OMPMemoryPreview(value)
    }

    func memoryControl(_ operation: String, fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard isRunning, !isDraining, memoryBridgeAvailable else {
            throw ProviderError.failed(AppText.localized("Memory requires an OMP installation with the Mnemopi SDK and Bun."))
        }
        let id = UUID().uuidString
        let file = sessionFile
        var payload = fields
        payload["requestID"] = .string(id)
        payload["operation"] = .string(operation)
        memoryRequests[id] = operation
        defer { memoryRequests[id] = nil }
        let result = try await memoryReplies.register(id, timeout: .seconds(30)) {
            rpc.send(["type": "prompt", "id": .string("omp-gui-memory-" + id),
                      "message": .string("/omp-gui-memory " + JSONValue.object(payload).compactString)]) { [weak self] delivered in
                if !delivered { self?.memoryReplies.fail(id, ProviderError.notRunning) }
            }
        }
        guard isRunning, sessionFile == file else { throw CancellationError() }
        guard result["success"]?.bool == true, let data = result["data"] else {
            throw ProviderError.failed(AppText.localized(result["error"]?.string ?? "OMP could not inspect memory."))
        }
        return data
    }

    func handleMemoryControl(_ frame: JSONValue) -> Bool {
        if frame["type"]?.string == "extension_ui_request", frame["method"]?.string == "notify",
           let message = frame["message"]?.string, message.hasPrefix("OMP_GUI_MEMORY_RESULT:") {
            guard let result = JSONValue.parse(String(message.dropFirst("OMP_GUI_MEMORY_RESULT:".count))),
                  let id = result["requestID"]?.string, memoryRequests[id] == result["operation"]?.string else { return true }
            memoryReplies.resolve(id, result)
            return true
        }
        if let id = frame["id"]?.string, id.hasPrefix("omp-gui-memory-") {
            if frame["type"]?.string == "response", frame["success"]?.bool == false {
                memoryReplies.fail(String(id.dropFirst("omp-gui-memory-".count)),
                    ProviderError.failed(frame["error"]?.string ?? AppText.localized("OMP could not inspect memory.")))
            }
            return true
        }
        return false
    }
}
