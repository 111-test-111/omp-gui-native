import Foundation
import AppKit
@testable import OMPGUI

@main
struct OMPP5NativeChecks {
    @MainActor private static var checks: [String] = []
    @MainActor private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        checks.append(message)
        print("PASS \(message)")
    }
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    @MainActor private static func wait(_ session: OMPSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while !session.nativeActivity.canRecycle {
            guard session.isRunning, ContinuousClock.now < deadline else {
                throw Failure(message: "Native session did not settle: \(session.nativeActivity)")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory,
              output.path.contains("/build.noindex/verification/runs/"),
              let executable = ProcessInfo.processInfo.environment["OMP_P5_NATIVE_EXECUTABLE"] else { fatalError("Require fresh isolated native check") }
        _ = NSApplication.shared // AppKit support, no GUI application entry point or windows.
        let root = output.appendingPathComponent("profile")
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("PI_") || key.hasPrefix("OMP_") { environment[key] = nil }
        environment["PI_CONFIG_DIR"] = root.path
        environment["PI_CODING_AGENT_DIR"] = root.appendingPathComponent("agent").path
        environment["OMP_PROFILE"] = "default"
        environment["PI_PROFILE"] = "default"
        var config = SessionConfiguration(provider: .omp, executable: URL(fileURLWithPath: executable), workingDirectory: output,
            environment: environment, resumeID: nil, resumeAt: nil, model: "p5-local/forward", effort: "off",
            runtimeMode: .auto, interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let version = try await OMPCLI.run(["--version"], executable: config.executable!, environment: environment, directory: output)
        let session = OMPSession(configuration: config)
        var delivery: [UUID: OMPSubmissionState] = [:]
        var readies = 0
        session.onEvent = { event in
            if case .ompSubmission(let id, let state, _) = event { delivery[id] = state }
            if case .sessionReady = event { readies += 1 }
        }
        var current: OMPSession = session
        do {
            let identity = try await session.start()
            try expect(!identity.isEmpty && readies == 1, "Production session starts with an isolated native identity")
            try expect(session.capabilities.protocolVersion == 2, "Protocol v2 is negotiated from the actual runtime")
            try await wait(session)
            func send(_ text: String, _ mode: OMPMessageDelivery = .prompt) async throws -> UUID {
                let id = UUID()
                try await session.send(TurnInput(text: text, images: [], model: nil, effort: nil,
                    runtimeMode: .auto, interactionMode: .build, ompDelivery: mode, ompRequestID: id))
                return id
            }
            let first = try await send("P5_FIRST")
            try await wait(session)
            try expect(delivery[first]?.isTerminal == true, "The first new message is consumed once")
            let initial = try await session.nativeHistory()
            try expect(initial.activeUserEntries.map(\.text) == ["P5_FIRST"], "New native entries preserve the exact user payload")
            try expect(initial.entries.contains { $0.message?.role == "assistant" && $0.text.contains("P5_REPLY") }, "Actual native inference decodes the local deterministic provider reply")
            let hold = try await send("P5_HOLD")
            let steer = try await send("P5_STEER", .steer)
            let follow = try await send("P5_FOLLOW", .followUp)
            try expect(!session.nativeActivity.canRecycle, "Native work and queue admission prevent idle recycling")
            try await wait(session)
            try expect([hold, steer, follow].allSatisfy { delivery[$0]?.isTerminal == true }, "Steering and follow-up reach native terminal admission")
            let history = try await session.nativeHistory()
            let texts = history.activeUserEntries.map(\.text)
            try expect(texts == ["P5_FIRST", "P5_HOLD", "P5_STEER", "P5_FOLLOW"], "Actual native queue preserves input order without duplicate execution")
            await session.stopAndWait(timeout: 5)
            try expect(!session.isRunning, "Explicit stop exits the task-owned native process")
            config.resumeID = identity
            let resumed = OMPSession(configuration: config)
            current = resumed
            let resumedIdentity = try await resumed.start()
            try await wait(resumed)
            let reopened = try await resumed.nativeHistory()
            try expect(resumedIdentity == identity && reopened.activeUserEntries.map(\.text) == texts,
                       "Reopening a newly created session reads native history without replaying inputs")
            let branch = try await resumed.branchHistory(entryID: reopened.activeUserEntries.last!.id)
            try expect(!branch.cancelled && branch.sessionFile != identity && branch.editorText == "P5_FOLLOW", "A native branch adopts a fresh identity and restores its editor payload")
            try expect(FileManager.default.fileExists(atPath: identity), "Branching preserves the source journal created by this run")
            if resumed.agentCapabilities.canCancel && resumed.agentCapabilities.canSteer {
                try await resumed.send(TurnInput(text: "P5_WORKER_PARENT", images: [], model: nil, effort: nil,
                    runtimeMode: .auto, interactionMode: .build, ompDelivery: .prompt, ompRequestID: UUID()))
                let workerDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                while resumed.knownAgents.isEmpty && ContinuousClock.now < workerDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard let worker = resumed.knownAgents.first, let metadata = resumed.agentMetadata[worker] else {
                    throw Failure(message: "Actual native task tool did not start a worker")
                }
                try expect(metadata.agentSource == "project" && metadata.sessionFile != nil && metadata.parentSessionFile != nil,
                    "Actual native worker preserves project source and parent/child journal identity")
                try expect(!resumed.nativeActivity.canRecycle, "A working native child prevents parent idle recycling")
                try await resumed.steerAgent(worker, message: "P5_WORKER_STEER")
                var transcript = JSONValue.null
                while ContinuousClock.now < workerDeadline {
                    transcript = try await resumed.rpc.request("get_subagent_messages", fields: ["subagentId": .string(worker)])
                    if transcript["messages"]?.array?.contains(where: { $0["role"]?.string == "user" && $0["content"]?.compactString.contains("P5_WORKER_STEER") == true }) == true { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let steeredUsers = transcript["messages"]?.array?.filter {
                    $0["role"]?.string == "user" && $0["content"]?.compactString.contains("P5_WORKER_STEER") == true
                } ?? []
                try expect(steeredUsers.count == 1, "Real worker steering reaches its native transcript exactly once")
                let cancelled = await resumed.stopAgent(worker)
                try expect(cancelled, "Actual native cancel_subagent confirms cancellation of the working child")
                while resumed.knownAgents.contains(worker) && ContinuousClock.now < workerDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                try expect(!resumed.knownAgents.contains(worker), "Native terminal lifecycle removes the cancelled child from the active roster")
                try await wait(resumed)
            }
            let traceURL = output.appendingPathComponent("large-frame-events.jsonl")
            FileManager.default.createFile(atPath: traceURL.path, contents: nil)
            let trace = try FileHandle(forWritingTo: traceURL)
            defer { try? trace.close() }
            let previousFrame = resumed.rpc.onFrame
            resumed.rpc.onFrame = { frame in
                var metadata: [String: JSONValue] = ["type": frame["type"] ?? .null]
                for key in ["id", "status", "sessionSettled", "agentInvoked"] { metadata[key] = frame[key] }
                metadata["event"] = frame["assistantMessageEvent"]?["type"]
                metadata["deltaBytes"] = .int(frame["assistantMessageEvent"]?["delta"]?.string?.utf8.count ?? 0)
                try? trace.write(contentsOf: JSONValue.object(metadata).data() + Data([10]))
                previousFrame?(frame)
            }
            try await resumed.send(TurnInput(text: "P5_NATIVE_LARGE", images: [], model: nil, effort: nil,
                runtimeMode: .auto, interactionMode: .build, ompDelivery: .prompt, ompRequestID: UUID()))
            try await wait(resumed)
            let largeHistory = try await resumed.nativeHistory()
            let largeReply = try largeHistory.activePath().last { $0.message?.role == "assistant" }
            try expect(largeReply?.message?.text.utf8.count == 1_900_009,
                       "A 1.9 MB Unicode reply survives actual native event and history chunk transport")
            try await resumed.send(TurnInput(text: "P5_DEFERRED_CONTEXT", images: [], model: nil, effort: nil,
                runtimeMode: .auto, interactionMode: .build, ompDelivery: .prompt, ompRequestID: UUID()))
            let deferredDeadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !resumed.nativeActivity.hasOnlyDeferredContext && !resumed.nativeActivity.canRecycle && ContinuousClock.now < deferredDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let parkedState = try await resumed.readState()
            if parkedState["isSettled"]?.bool == true {
                try expect(parkedState["queuedMessageCount"]?.int == 0 && resumed.nativeActivity.canRecycle,
                           "Native settlement excludes an untriggered todo reminder from runnable work")
            } else {
                try expect(parkedState["isSettled"]?.bool == false && parkedState["queuedMessageCount"]?.int == 1
                           && resumed.nativeActivity.hasOnlyDeferredContext && !resumed.nativeActivity.hasWork && !resumed.nativeActivity.canRecycle,
                           "Legacy SDK idle protects deferred context without displaying a false wait")
            }
            let deferredHistory = try await resumed.rpc.request("get_messages")
            try expect(deferredHistory["messages"]?.array?.contains {
                $0["role"]?.string == "toolResult" && $0["toolName"]?.string == "todo" && $0["isError"]?.bool == true
            } == true, "The native regression actually exercised the failed todo tool")
            try await resumed.send(TurnInput(text: "P5_AFTER_DEFERRED_CONTEXT", images: [], model: nil, effort: nil,
                runtimeMode: .auto, interactionMode: .build, ompDelivery: .prompt, ompRequestID: UUID()))
            try await wait(resumed)
            let consumedContext = try await resumed.rpc.request("get_messages")
            try expect(consumedContext["messages"]?.array?.contains { $0["customType"]?.string == "todo-error-reminder" } == true,
                       "The next explicit prompt consumes the preserved native reminder")
            let capabilities = session.capabilities.commands.mapValues(\.rawValue)
            await resumed.stopAndWait(timeout: 5)
            let report: [String: Any] = ["version": version.trimmingCharacters(in: .whitespacesAndNewlines), "status": "passed", "checks": checks,
                "capabilities": capabilities, "scope": "Actual installed runtime + synthetic local OpenAI-compatible provider, new isolated sessions only; no external account or existing conversation access."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
            print("OMP P5 native checks passed: \(checks.count)")
        } catch {
            await current.stopAndWait(timeout: 5)
            let report: [String: Any] = ["version": version.trimmingCharacters(in: .whitespacesAndNewlines), "status": "failed", "checks": checks, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
            throw error
        }
    }
}
