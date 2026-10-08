import Foundation

/// Each edited file's text from before the tool ran, for the finished edit's diff.
struct EditSnapshots {
    private var contents: [String: String] = [:]

    /// Captures the file's text as the call starts; a missing or huge file reads
    /// as empty, so a write shows as a whole-file addition.
    mutating func capture(_ id: String, path: String) {
        contents[id] = Self.read(path) ?? ""
    }

    mutating func discard(_ id: String) {
        contents.removeValue(forKey: id)
    }

    mutating func removeAll() {
        contents.removeAll()
    }

    func text(_ id: String) -> String {
        contents[id] ?? ""
    }

    /// The finished edit as the file before against after; nil for an id nothing
    /// was captured for, so the row's edits stay as queued.
    mutating func finish(_ id: String, path: String, relativeTo root: String) -> [FileEdit]? {
        guard let before = contents.removeValue(forKey: id) else { return nil }
        let relative = ToolTitles.relativePath(path, to: root)
        let after = Self.read(path) ?? ""
        guard before != after else { return [FileEdit(path: relative)] }
        return [FileEdit(path: relative, old: before, new: after)]
    }

    /// Text files up to 1 MB; anything else (binary, huge, missing) reads as nil.
    private static func read(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

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
