import Foundation
@testable import OMPGUI

/// The same model-free stream feeds behavior checks and the opt-in byte/parse
/// comparison. Full frames include both snapshots omitted by native delta mode.
enum EventProjectionFixture {
    struct Corpus {
        var full: [Data]
        var delta: [Data]
        var text: String
        var thinking: String
        var arguments: JSONValue
        var output: String
    }

    static func corpus(chunks: Int, repetitions: Int) -> Corpus {
        let piece = String(repeating: "原生🙂\\\"\n", count: repetitions)
        let argumentPiece = String(repeating: "参数🙂\\\"\n", count: repetitions)
        let thinking = "保留原生思考索引🙂"
        let output = "fixture tool result🙂"
        var text = "", argumentText = ""
        var frames: [JSONValue] = [
            ["type": "message_start", "messageId": "message", "message": ["role": "assistant", "content": []]]
        ]

        func content() -> JSONValue {
            [["type": "text", "text": .string(text)],
             ["type": "thinking", "thinking": .string(thinking)],
             ["type": "toolCall", "id": "tool", "name": "fixture_native_tool", "arguments": ["payload": .string(argumentText)]]]
        }
        func update(_ event: JSONValue) {
            var event = event.object!
            let snapshot: JSONValue = ["role": "assistant", "content": content()]
            event["partial"] = snapshot
            frames.append(["type": "message_update", "messageId": "message", "message": snapshot,
                           "assistantMessageEvent": .object(event)])
        }

        update(["type": "thinking_delta", "contentIndex": 1, "delta": .string(thinking)])
        for _ in 0..<chunks {
            text += piece
            update(["type": "text_delta", "contentIndex": 0, "delta": .string(piece)])
        }
        for _ in 0..<chunks {
            argumentText += argumentPiece
            update(["type": "toolcall_delta", "contentIndex": 2, "delta": .string(argumentPiece)])
        }
        let arguments: JSONValue = ["payload": .string(argumentText)]
        frames.append(["type": "message_end", "messageId": "message", "message": [
            "role": "assistant", "content": content(), "provider": "fixture", "model": "deterministic",
            "usage": ["input": 11, "output": 7, "cacheRead": 3, "cacheWrite": 2, "totalTokens": 23]]])
        frames.append(["type": "tool_execution_start", "toolCallId": "tool", "toolName": "fixture_native_tool", "args": arguments])
        frames.append(["type": "tool_execution_end", "toolCallId": "tool", "toolName": "fixture_native_tool",
                       "result": ["content": [["type": "text", "text": .string(output)]]], "isError": false])
        return Corpus(full: frames.map { $0.data() }, delta: frames.map { frame in
            guard frame["type"]?.string == "message_update", var object = frame.object else { return frame.data() }
            object["message"] = ["role": "assistant"]
            var event = object["assistantMessageEvent"]!.object!
            event.removeValue(forKey: "partial")
            object["assistantMessageEvent"] = .object(event)
            return JSONValue.object(object).data()
        }, text: text, thinking: thinking, arguments: arguments, output: output)
    }

    @MainActor
    static func observed(_ event: ProviderEvent) -> JSONValue {
        switch event {
        case let .messageDelta(id, text): ["event": "message_delta", "id": .string(id), "text": .string(text)]
        case let .messageCompleted(id, text): ["event": "message_completed", "id": .string(id), "text": .string(text)]
        case let .reasoningDelta(id, text): ["event": "reasoning_delta", "id": .string(id), "text": .string(text)]
        case let .reasoningCompleted(id, text): ["event": "reasoning_completed", "id": .string(id), "text": .string(text)]
        case let .toolStarted(id, call):
            ["event": "tool_started", "id": .string(id), "name": .optional(call.toolName),
             "arguments": call.detail.flatMap(JSONValue.parse) ?? .null]
        case let .toolUpdated(id, update):
            ["event": "tool_updated", "id": .string(id), "output": .optional(update.output),
             "status": .optional(update.status?.rawValue)]
        case let .usage(value): ["event": "usage", "tokens": .int(value.usedTokens)]
        case let .tokenSpend(value):
            ["event": "token_spend", "tokens": .int(value.totalTokens), "input": value.inputTokens.map(JSONValue.int) ?? .null,
             "output": value.outputTokens.map(JSONValue.int) ?? .null, "model": .optional(value.model)]
        default: ["event": "unexpected"]
        }
    }

    @MainActor
    static func decode(_ frames: [Data], directory: String) -> [JSONValue] {
        let decoder = OMPEventDecoder(prefix: "projection", directory: directory, capturesSnapshots: false)
        var events: [JSONValue] = []
        decoder.onEvent = { events.append(observed($0)) }
        for data in frames {
            guard let frame = JSONValue.parse(data) else { fatalError("Invalid projection fixture JSON") }
            decoder.handle(frame)
        }
        return events
    }
}
