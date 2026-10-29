import Foundation

/// One native topic per connection. No history queries, transcript writes or scheduler.
@MainActor
final class OMPSideQuestionController {
    let rpc: OMPRPC
    var onChange: ((OMPSideQuestionSnapshot) -> Void)?
    private(set) var snapshot = OMPSideQuestionSnapshot()
    private var expectedTopic: String?
    private var expectedQuestion: Data?
    private var recordTask: Task<Void, Never>?
    private var queuedRecord: JSONValue?
    private var bufferedDelta = ""
    private var bufferedDeltaBytes = 0
    private var bufferedRecordID: String?
    private var publication: Task<Void, Never>?
    private var recordRevision = 0
    private var persistenceRevision = 0
    private var admissionPersistenceRevision = 0
    private var closed = false

    init(rpc: OMPRPC) { self.rpc = rpc }

    func ask(_ question: String, continuing: Bool, requestID: String, timeout: Duration = .seconds(30)) async throws {
        guard !closed, rpc.isRunning, !rpc.isDraining else { throw ProviderError.notRunning }
        guard rpc.capabilities["btw"] != .unsupported else {
            throw ProviderError.failed(AppText.localized("This OMP process does not support side questions."))
        }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, question.utf8.count <= OMPSideQuestionSnapshot.maximumInputBytes else {
            throw ProviderError.failed(AppText.localized("Enter a side question of at most 128 KiB."))
        }
        guard !snapshot.hasLiveWork, !snapshot.draining, !continuing || snapshot.canFollowUp else {
            throw ProviderError.failed(AppText.localized("Wait for the side question to finish, or start a new topic after its limit."))
        }
        let connection = snapshot.connectionID
        expectedTopic = continuing ? snapshot.recordID : nil
        expectedQuestion = OMPSideQuestionSnapshot.fingerprint(text)
        admissionPersistenceRevision = persistenceRevision
        snapshot.pendingRequestID = requestID
        snapshot.acceptedRequestID = nil
        snapshot.rejectedRequestID = nil
        snapshot.error = nil
        snapshot.outcomeUnknown = false
        publish()
        var fields: [String: JSONValue] = ["question": .string(question)]
        if let expectedTopic { fields["recordId"] = .string(expectedTopic) }
        do {
            let reply = try await rpc.response("btw", fields: fields, id: requestID, timeout: timeout)
            guard connection == snapshot.connectionID, !closed else { throw CancellationError() }
            try await finishAsk(reply, requestID: requestID)
        } catch {
            guard connection == snapshot.connectionID, !closed else { throw error }
            if snapshot.pendingRequestID == requestID {
                // Explicit native rejection already cleared this ID in finishAsk.
                // Every other wait failure leaves possible native work outstanding.
                snapshot.outcomeUnknown = true
                snapshot.error = AppText.localized("OMP has not confirmed the side question. Do not submit it again while its outcome is unknown.")
                publish()
            }
            throw error
        }
    }

    func cancel(timeout: Duration = .seconds(15)) async throws {
        guard !closed, rpc.isRunning, !rpc.isDraining, snapshot.hasLiveWork,
              snapshot.pendingCancellationID == nil else { throw ProviderError.notRunning }
        guard rpc.capabilities["btw_cancel"] != .unsupported else {
            throw ProviderError.failed(AppText.localized("This OMP process cannot cancel side questions."))
        }
        let connection = snapshot.connectionID
        let id = UUID().uuidString
        snapshot.pendingCancellationID = id
        publish()
        var fields: [String: JSONValue] = [:]
        // During initial admission the only cancellable topic belongs to this request.
        if let topic = snapshot.recordID, snapshot.pendingRequestID == nil || expectedTopic == topic {
            fields["recordId"] = .string(topic)
        }
        do {
            let reply = try await rpc.response("btw_cancel", fields: fields, id: id, timeout: timeout)
            guard connection == snapshot.connectionID, !closed else { throw CancellationError() }
            try finishCancellation(reply, id: id)
        } catch {
            guard connection == snapshot.connectionID, !closed else { throw error }
            if snapshot.pendingCancellationID == id {
                snapshot.outcomeUnknown = true
                snapshot.error = OMPSideQuestionSnapshot.suffix(error.localizedDescription, bytes: 8 * 1_024)
                publish()
            }
            throw error
        }
    }

    /// Native frames have no GUI turn ownership and must never reach its decoder.
    @discardableResult
    func observe(_ frame: JSONValue) -> Bool {
        switch frame["type"]?.string {
        case "btw_record":
            if let record = frame["record"], !closed { enqueue(record) }
            return true
        case "btw_delta":
            guard !closed, let id = frame["recordId"]?.string, let delta = frame["delta"]?.string else { return true }
            if recordTask != nil || snapshot.recordID == id {
                if bufferedRecordID == nil || bufferedRecordID == id {
                    bufferedRecordID = id
                    bufferedDeltaBytes = OMPSideQuestionSnapshot.adding(bufferedDeltaBytes, delta.utf8.count)
                    bufferedDelta = OMPSideQuestionSnapshot.suffix(bufferedDelta + OMPSideQuestionSnapshot.suffix(delta, bytes: OMPSideQuestionSnapshot.maximumDisplayBytes), bytes: OMPSideQuestionSnapshot.maximumDisplayBytes)
                }
                if recordTask == nil { publish(coalesced: true) }
            }
            return true
        case "notice" where frame["source"]?.string == "btw-history":
            guard snapshot.recordID != nil || snapshot.pendingRequestID != nil else { return true }
            snapshot.persistenceError = OMPSideQuestionSnapshot.suffix(frame["message"]?.string ?? AppText.localized("OMP could not save the side question."), bytes: 8 * 1_024)
            persistenceRevision += 1
            snapshot.persistencePending = true
            publish()
            return true
        case "rpc_frame_error" where snapshot.hasLiveWork:
            snapshot.outcomeUnknown = true
            snapshot.error = AppText.localized("OMP did not provide a complete side-question result. Its outcome is unknown.")
            publish()
            return true
        case "response":
            if frame["command"]?.string == "btw", let id = snapshot.pendingRequestID, frame["id"]?.string == id {
                // Only late responses reach onFrame; the RPC waiter owns normal replies.
                let connection = snapshot.connectionID
                Task { [weak self] in
                    guard let self, snapshot.connectionID == connection else { return }
                    do { try await finishAsk(frame, requestID: id) } catch { }
                }
                return true
            }
            if frame["command"]?.string == "btw_cancel", let id = snapshot.pendingCancellationID, frame["id"]?.string == id {
                try? finishCancellation(frame, id: id)
                return true
            }
            return false
        default: return false
        }
    }

    private func finishAsk(_ reply: JSONValue, requestID: String) async throws {
        guard snapshot.pendingRequestID == requestID, !closed else { throw CancellationError() }
        if reply["success"]?.bool == false {
            let error = ProviderError.failed(OMPSideQuestionSnapshot.suffix(reply["error"]?.string ?? AppText.localized("OMP rejected the side question."), bytes: 8 * 1_024))
            snapshot.pendingRequestID = nil
            snapshot.rejectedRequestID = requestID
            snapshot.outcomeUnknown = false
            snapshot.error = error.localizedDescription
            expectedQuestion = nil
            publish()
            throw error
        }
        guard reply["success"]?.bool == true else {
            snapshot.outcomeUnknown = true
            snapshot.error = AppText.localized("OMP returned an unrecognized side-question record. Its outcome is unknown.")
            publish()
            throw ProviderError.failed(snapshot.error!)
        }
        let connection = snapshot.connectionID
        // Started/terminal frames can arrive before the caller resumes. Reduce
        // their bounded projections first, keeping admission from rewinding them.
        while let task = recordTask {
            await task.value
            guard snapshot.connectionID == connection, snapshot.pendingRequestID == requestID, !closed else { throw CancellationError() }
        }
        guard snapshot.connectionID == connection, snapshot.pendingRequestID == requestID, !closed else { throw CancellationError() }
        let record = if let raw = reply["data"]?["record"] { await Self.parse(raw) } else { nil as OMPSideQuestionRecord? }
        // An old parser's result cannot turn a replacement connection unknown.
        guard snapshot.connectionID == connection, snapshot.pendingRequestID == requestID, !closed else { throw CancellationError() }
        guard let record, matches(record) else {
            snapshot.outcomeUnknown = true
            snapshot.error = AppText.localized("OMP returned an unrecognized side-question record. Its outcome is unknown.")
            publish()
            throw ProviderError.failed(snapshot.error!)
        }
        snapshot.apply(record)
        snapshot.pendingRequestID = nil
        snapshot.acceptedRequestID = requestID
        snapshot.outcomeUnknown = snapshot.pendingCancellationID != nil && snapshot.outcomeUnknown
        if !snapshot.outcomeUnknown { snapshot.error = nil }
        // A successful new admission awaited all prior checkpoint writes. Its own
        // terminal checkpoint will still need native EOF/session-change draining.
        if admissionPersistenceRevision == persistenceRevision { snapshot.persistenceError = nil }
        expectedTopic = nil
        expectedQuestion = nil
        publish()
    }

    private func finishCancellation(_ reply: JSONValue, id: String) throws {
        guard snapshot.pendingCancellationID == id else { return }
        if reply["success"]?.bool == false {
            snapshot.pendingCancellationID = nil
            snapshot.outcomeUnknown = snapshot.pendingRequestID != nil && snapshot.outcomeUnknown
            snapshot.error = OMPSideQuestionSnapshot.suffix(reply["error"]?.string ?? AppText.localized("OMP did not confirm side-question cancellation."), bytes: 8 * 1_024)
            publish()
            throw ProviderError.failed(snapshot.error!)
        }
        guard reply["success"]?.bool == true, let cancelled = reply["data"]?["cancelled"]?.bool else {
            snapshot.outcomeUnknown = true
            snapshot.error = AppText.localized("OMP did not confirm side-question cancellation.")
            publish()
            throw ProviderError.failed(snapshot.error!)
        }
        snapshot.pendingCancellationID = nil
        snapshot.outcomeUnknown = snapshot.pendingRequestID != nil && snapshot.outcomeUnknown
        if !snapshot.outcomeUnknown { snapshot.error = nil }
        if !cancelled, snapshot.isRunning {
            snapshot.error = AppText.localized("OMP did not cancel this side question. Waiting for its native state.")
        }
        // Cancellation acceptance is not its lifecycle or durability confirmation.
        publish()
    }

    private func matches(_ record: OMPSideQuestionRecord) -> Bool {
        if let expectedTopic, record.id != expectedTopic { return false }
        if let expectedQuestion, record.latestQuestionFingerprint != expectedQuestion { return false }
        return true
    }

    private func enqueue(_ raw: JSONValue) {
        recordRevision += 1
        bufferedDelta = ""; bufferedDeltaBytes = 0; bufferedRecordID = nil
        if recordTask != nil { queuedRecord = raw; return }
        parseRecord(raw)
    }

    private func parseRecord(_ raw: JSONValue) {
        let connection = snapshot.connectionID
        let revision = recordRevision
        recordTask = Task { [weak self] in
            let record = await Self.parse(raw)
            guard let self, snapshot.connectionID == connection, !closed else { return }
            if let record, snapshot.pendingRequestID != nil ? matches(record) : snapshot.recordID == record.id {
                snapshot.apply(record)
                if revision == recordRevision, bufferedRecordID == record.id {
                    snapshot.appendDelta(bufferedDelta, nativeBytes: bufferedDeltaBytes)
                    bufferedDelta = ""; bufferedDeltaBytes = 0; bufferedRecordID = nil
                }
                publish()
            } else if record == nil, snapshot.hasLiveWork {
                snapshot.outcomeUnknown = true
                snapshot.error = AppText.localized("OMP returned an unrecognized side-question record. Its outcome is unknown.")
                publish()
            }
            recordTask = nil
            if let next = queuedRecord { queuedRecord = nil; parseRecord(next) }
        }
    }

    private nonisolated static func parse(_ raw: JSONValue) async -> OMPSideQuestionRecord? {
        await Task.detached(priority: .userInitiated) { OMPSideQuestionRecord(raw) }.value
    }

    func beginDrain() -> Bool {
        guard !snapshot.hasLiveWork, snapshot.persistenceError == nil, rpc.isRunning else { return false }
        guard rpc.beginDrain() else { return false }
        snapshot.draining = true
        publish()
        return true
    }

    func exited(cleanDrain: Bool) {
        closed = true
        recordTask?.cancel(); recordTask = nil; queuedRecord = nil
        publication?.cancel(); publication = nil
        bufferedDelta = ""; bufferedDeltaBytes = 0
        if cleanDrain, snapshot.persistenceError == nil { snapshot.persistencePending = false }
        snapshot.disconnect()
        publish()
    }

    func finishExit(cleanDrain: Bool) async {
        // stdout may close while the bounded terminal projection is still being
        // prepared. Publish that result before the provider's exit detaches it.
        while let task = recordTask { await task.value }
        exited(cleanDrain: cleanDrain)
    }

    func reset() {
        recordTask?.cancel(); recordTask = nil; queuedRecord = nil
        publication?.cancel(); publication = nil
        bufferedDelta = ""; bufferedDeltaBytes = 0; bufferedRecordID = nil
        expectedTopic = nil; expectedQuestion = nil
        persistenceRevision = 0; admissionPersistenceRevision = 0
        closed = false
        snapshot = OMPSideQuestionSnapshot()
        publish()
    }

    private func publish(coalesced: Bool = false) {
        if coalesced {
            guard publication == nil else { return }
            publication = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                publication = nil
                flushDelta()
                onChange?(snapshot)
            }
        } else {
            publication?.cancel(); publication = nil
            flushDelta()
            onChange?(snapshot)
        }
    }

    private func flushDelta() {
        guard recordTask == nil, bufferedRecordID == snapshot.recordID, bufferedDeltaBytes > 0 else { return }
        snapshot.appendDelta(bufferedDelta, nativeBytes: bufferedDeltaBytes)
        bufferedDelta = ""; bufferedDeltaBytes = 0; bufferedRecordID = nil
    }
}
