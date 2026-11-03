import Foundation

/// Message and thinking ids for one streamed turn, starting a new id when a delta
/// arrives without one.
struct StreamedTextTracker {
    private let messageID: (Int) -> String
    private let thinkingID: (Int) -> String
    private var messageCounter = 0
    private var thinkingCounter = 0
    private(set) var currentMessageID: String?
    private(set) var currentThinkingID: String?
    private(set) var messageText = ""
    private(set) var thinkingText = ""
    private(set) var streamedText = false

    init(messageID: @escaping (Int) -> String, thinkingID: @escaping (Int) -> String) {
        self.messageID = messageID
        self.thinkingID = thinkingID
    }

    /// A `message_start`: a fresh reply, its text buffer empty.
    mutating func startMessage() {
        messageCounter += 1
        currentMessageID = messageID(messageCounter)
        messageText = ""
        streamedText = false
    }

    /// Unlike `startMessage`, starting a reply here keeps the text buffer.
    mutating func appendMessage(_ delta: String) -> String {
        if currentMessageID == nil {
            messageCounter += 1
            currentMessageID = messageID(messageCounter)
        }
        streamedText = true
        messageText += delta
        return currentMessageID ?? ""
    }

    mutating func startThinking() {
        thinkingCounter += 1
        currentThinkingID = thinkingID(thinkingCounter)
        thinkingText = ""
    }

    /// The id a thinking delta belongs to. `resetsText` follows the provider's
    /// fallback: Pi empties the buffer, Command Code keeps it across a block.
    mutating func appendThinking(_ delta: String, resetsText: Bool = true) -> String {
        if currentThinkingID == nil {
            if resetsText {
                startThinking()
            } else {
                thinkingCounter += 1
                currentThinkingID = thinkingID(thinkingCounter)
            }
        }
        thinkingText += delta
        return currentThinkingID ?? ""
    }

    mutating func endThinking() {
        currentThinkingID = nil
    }

    mutating func endMessage() {
        currentMessageID = nil
    }

    /// A `message_start` that also drops the reasoning block it interrupted.
    mutating func resetThinking() {
        currentThinkingID = nil
        thinkingText = ""
    }

    /// The turn's text flag, cleared before each turn.
    mutating func resetForTurn() {
        streamedText = false
    }

    mutating func resetIDs() {
        currentMessageID = nil
        currentThinkingID = nil
    }
}

struct SessionDeadlineError: LocalizedError {
    let provider: String
    let operation: String
    let seconds: Int

    var errorDescription: String? {
        String(format: AppText.localized("%@ didn't answer %@ within %lld seconds"), provider, operation, seconds)
    }
}

@MainActor
func withDeadline<Value: Sendable>(
    seconds: Int,
    provider: String,
    operation: String,
    body: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SessionDeadlineError(provider: provider, operation: operation, seconds: seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
