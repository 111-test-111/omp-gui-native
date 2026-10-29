import CryptoKit
import Foundation

/// A bounded, connection-local projection. OMP owns the complete sidecar record.
struct OMPSideQuestionSnapshot: Equatable, Sendable {
    static let maximumInputBytes = 128 * 1_024
    static let maximumDisplayBytes = 64 * 1_024
    static let maximumNativeBodyBytes = 1_024 * 1_024
    static let maximumTurns = 16

    enum Status: String, Sendable { case running, complete, cancelled, error, interrupted }
    struct Turn: Equatable, Identifiable, Sendable {
        var id: Int
        var question: String
        var answer: String
        var status: Status
        var error: String?
    }
    var connectionID = UUID()
    var recordID: String?
    var turns: [Turn] = []
    var turnCount = 0
    var nativeBodyBytes = 0
    var updatedAt: Double = 0
    var omitted = false
    var pendingRequestID: String?
    var pendingCancellationID: String?
    var acceptedRequestID: String?
    var rejectedRequestID: String?
    var outcomeUnknown = false
    var error: String?
    /// The protocol has no successful terminal-checkpoint acknowledgement.
    var persistencePending = false
    var persistenceError: String?
    var draining = false
    var disconnected = false

    var isRunning: Bool { turns.last?.status == .running }
    var hasLiveWork: Bool { !disconnected && (pendingRequestID != nil || pendingCancellationID != nil || isRunning || outcomeUnknown) }
    var blocksRecycling: Bool { hasLiveWork || outcomeUnknown || persistencePending || persistenceError != nil || draining }
    var canFollowUp: Bool {
        recordID != nil && !hasLiveWork && !draining && !disconnected
            && turnCount < Self.maximumTurns && nativeBodyBytes < Self.maximumNativeBodyBytes
    }
    var displayBytes: Int { turns.reduce(0) { $0 + $1.question.utf8.count + $1.answer.utf8.count + ($1.error?.utf8.count ?? 0) } }

    mutating func apply(_ record: OMPSideQuestionRecord) {
        if recordID == record.id {
            guard record.turnCount >= turnCount, record.updatedAt >= updatedAt else { return }
            // The admission response can be resumed after the terminal frame.
            if record.turnCount == turnCount, !isRunning, record.turns.last?.status == .running { return }
            if record.turnCount == turnCount, isRunning, record.turns.last?.status == .running,
               record.updatedAt == updatedAt, record.nativeBodyBytes < nativeBodyBytes { return }
        }
        recordID = record.id
        turns = record.turns
        turnCount = record.turnCount
        nativeBodyBytes = record.nativeBodyBytes
        updatedAt = record.updatedAt
        omitted = record.omitted
        persistencePending = true
        disconnected = false
        if !isRunning, pendingRequestID == nil, pendingCancellationID == nil {
            outcomeUnknown = false
            error = nil
        }
    }

    mutating func appendDelta(_ delta: String, nativeBytes: Int? = nil) {
        guard isRunning, let index = turns.indices.last else { return }
        nativeBodyBytes = Self.adding(nativeBodyBytes, nativeBytes ?? delta.utf8.count)
        if (nativeBytes ?? delta.utf8.count) > Self.maximumDisplayBytes { omitted = true }
        turns[index].answer += Self.suffix(delta, bytes: Self.maximumDisplayBytes)
        trimDisplay()
    }

    mutating func trimDisplay() {
        while turns.count > Self.maximumTurns { turns.removeFirst(); omitted = true }
        var excess = displayBytes - Self.maximumDisplayBytes
        for index in turns.indices where excess > 0 {
            for field in 0..<3 where excess > 0 {
                let text = field == 0 ? turns[index].question : field == 1 ? turns[index].answer : turns[index].error ?? ""
                let size = text.utf8.count
                let kept = Self.suffix(text, bytes: max(0, size - excess))
                excess -= size - kept.utf8.count
                switch field {
                case 0: turns[index].question = kept
                case 1: turns[index].answer = kept
                default: turns[index].error = kept.nilIfEmpty
                }
                omitted = true
            }
        }
        while turns.count > 1, turns[0].question.isEmpty && turns[0].answer.isEmpty { turns.removeFirst() }
    }

    mutating func disconnect() {
        if isRunning, let index = turns.indices.last { turns[index].status = .interrupted }
        if pendingRequestID != nil || pendingCancellationID != nil { outcomeUnknown = true }
        pendingRequestID = nil
        pendingCancellationID = nil
        draining = false
        disconnected = true
    }

    static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let value = lhs.addingReportingOverflow(rhs)
        return value.overflow ? Int.max : value.partialValue
    }

    /// Keep complete Unicode scalars while enforcing a UTF-8 byte budget.
    static func suffix(_ value: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        guard value.utf8.count > bytes else { return value }
        var data = Array(value.utf8.suffix(bytes))
        while let byte = data.first, byte & 0xC0 == 0x80 { data.removeFirst() }
        return String(decoding: data, as: UTF8.self)
    }

    static func fingerprint(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
}

/// Parsed away from the main actor; never retains the full native record.
struct OMPSideQuestionRecord: Sendable {
    var id: String
    var turns: [OMPSideQuestionSnapshot.Turn]
    var turnCount: Int
    var nativeBodyBytes: Int
    var updatedAt: Double
    var omitted: Bool
    var latestQuestionFingerprint: Data

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              value["followUps"] == nil || value["followUps"]?.array != nil else { return nil }
        let nativeTurns = [value] + (value["followUps"]?.array ?? [])
        var snapshot = OMPSideQuestionSnapshot()
        var lastTimestamp: Double = 0
        var fingerprint = Data()
        for (index, turn) in nativeTurns.enumerated() {
            guard let question = turn["question"]?.string, let answer = turn["answer"]?.string,
                  let raw = turn["status"]?.string, let status = OMPSideQuestionSnapshot.Status(rawValue: raw),
                  let timestamp = turn["updatedAt"]?.double, timestamp.isFinite, timestamp >= 0,
                  timestamp <= 8_640_000_000_000_000 else { return nil }
            snapshot.nativeBodyBytes = OMPSideQuestionSnapshot.adding(snapshot.nativeBodyBytes,
                OMPSideQuestionSnapshot.adding(question.utf8.count, answer.utf8.count))
            if index >= nativeTurns.count - OMPSideQuestionSnapshot.maximumTurns {
                snapshot.turns.append(.init(id: index,
                    question: OMPSideQuestionSnapshot.suffix(question, bytes: OMPSideQuestionSnapshot.maximumDisplayBytes),
                    answer: OMPSideQuestionSnapshot.suffix(answer, bytes: OMPSideQuestionSnapshot.maximumDisplayBytes),
                    status: status, error: turn["error"]?.string.map { OMPSideQuestionSnapshot.suffix($0, bytes: 8 * 1_024) }))
                snapshot.omitted = snapshot.omitted || question.utf8.count + answer.utf8.count > OMPSideQuestionSnapshot.maximumDisplayBytes
                snapshot.trimDisplay()
            }
            lastTimestamp = timestamp
            if index == nativeTurns.count - 1 { fingerprint = OMPSideQuestionSnapshot.fingerprint(question) }
        }
        self.id = id
        turns = snapshot.turns
        turnCount = nativeTurns.count
        nativeBodyBytes = snapshot.nativeBodyBytes
        updatedAt = lastTimestamp
        omitted = snapshot.omitted || nativeTurns.count > OMPSideQuestionSnapshot.maximumTurns
        latestQuestionFingerprint = fingerprint
    }
}
