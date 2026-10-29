import Foundation
import AppKit
@testable import OMPGUI

@main
struct OMPP5Checks {
    @MainActor private static var count = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        count += 1
        print("PASS \(message)")
    }
    @MainActor private static func until(_ test: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !test() {
            guard ContinuousClock.now < end else { fatalError("Event deadline exceeded") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private static func chunk(_ data: Data, index: Int = 0, count: Int = 1, size: Int? = nil, id: String = "a") -> JSONValue {
        .object(["type": "rpc_chunk", "chunkId": .string(id), "index": .int(index), "count": .int(count),
                 "byteLength": .int(size ?? data.count), "data": .string(data.base64EncodedString())])
    }
    @MainActor private static func checkEventProjection(root: URL, fixture: URL) async throws {
        let corpus = EventProjectionFixture.corpus(chunks: 3, repetitions: 2)
        let full = EventProjectionFixture.decode(corpus.full, directory: root.path)
        let delta = EventProjectionFixture.decode(corpus.delta, directory: root.path)
        expect(full == delta, "Full and delta streams produce identical text, reasoning, tools and usage")
        expect(!delta.contains { $0["event"]?.string == "unexpected" }, "Projection emits only the expected production event kinds")
        expect(delta.filter { $0["event"]?.string == "message_delta" }.compactMap { $0["text"]?.string }.joined() == corpus.text,
               "Delta text retains Unicode, escapes and every incremental fragment")
        expect(delta.contains { $0["event"]?.string == "reasoning_completed" && $0["id"]?.string == "projection-r-message-1"
            && $0["text"]?.string == corpus.thinking }, "Complete message_end preserves thinking content indices")
        expect(delta.contains { $0["event"]?.string == "tool_started" && $0["id"]?.string == "projection-tool"
            && $0["arguments"] == corpus.arguments }, "Complete tool arguments do not depend on partial snapshots")
        expect(delta.contains { $0["event"]?.string == "tool_updated" && $0["output"]?.string == corpus.output
            && $0["status"]?.string == "completed" }, "Tool completion and output survive delta projection")
        expect(delta.contains { $0["event"]?.string == "token_spend" && $0["tokens"]?.int == 23
            && $0["input"]?.int == 16 && $0["output"]?.int == 7 }, "Complete message_end retains disjoint usage buckets")

        let finalFrames = corpus.delta.filter { JSONValue.parse($0)?["type"]?.string != "message_update" }
        let final = EventProjectionFixture.decode(finalFrames, directory: root.path)
        expect(final.contains { $0["event"]?.string == "message_completed" && $0["text"]?.string == corpus.text },
               "Complete message_end supplies final text even without interim updates")
        let mixed = corpus.full.enumerated().map { $0.offset.isMultiple(of: 2) ? $0.element : corpus.delta[$0.offset] }
        expect(EventProjectionFixture.decode(mixed, directory: root.path) == full,
               "In-flight full and delta shapes may interleave without duplicate or missing output")
        let endFrame = corpus.delta.first { JSONValue.parse($0)?["type"]?.string == "message_end" }!
        var reassembly = OMPChunkAssembler()
        let split = endFrame.count / 2
        _ = try reassembly.append(chunk(Data(endFrame.prefix(split)), index: 0, count: 2, size: endFrame.count, id: "projection-end"))
        let end = try reassembly.append(chunk(Data(endFrame.suffix(endFrame.count - split)), index: 1, count: 2,
                                             size: endFrame.count, id: "projection-end"))
        expect(end?.value == JSONValue.parse(endFrame), "Delta mode keeps a complete chunked terminal message")

        let fields: [String: JSONValue] = ["events": .null, "messageUpdates": "delta"]
        func peer(_ mode: String) throws -> OMPRPC {
            let rpc = OMPRPC()
            try rpc.start(executable: fixture, arguments: [], directory: root, environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "OMP_FIXTURE_PROJECTION": mode])
            return rpc
        }
        for mode in ["delta", "full", "legacy", "malformed", "future", "unsupported", "mismatch", "late"] {
            let rpc = try peer(mode)
            expect(rpc.capabilities.messageUpdates == .full, "A fresh \(mode) peer begins in full projection")
            _ = try await rpc.request("fixture_unsolicited_projection")
            expect(rpc.capabilities.messageUpdates == .full, "Foreign projection echoes cannot confirm \(mode) capability")
            do {
                _ = try await rpc.request("set_event_filter", fields: fields,
                                          timeout: mode == "late" ? .milliseconds(10) : .seconds(2))
                expect(!["unsupported", "mismatch", "late"].contains(mode), "Only a matched successful projection request resolves")
            } catch {
                expect(["unsupported", "mismatch", "late"].contains(mode), "Projection rejection, mismatched command or timeout remains explicit")
            }
            _ = try await rpc.request("ping") // Flushes the late reply before inspecting evidence.
            expect(rpc.capabilities.messageUpdates == (mode == "delta" ? .delta : .full),
                   "Only a matched valid delta echo enables delta for \(mode)")
            if mode == "unsupported" {
                expect(rpc.capabilities["set_event_filter"] == .unsupported, "Legacy unknown-command records only negative command evidence")
            } else if ["mismatch", "late"].contains(mode) {
                expect(rpc.capabilities["set_event_filter"] == .unknown, "Invalid or late projection replies remain unknown")
            }
            if mode == "delta" {
                _ = try await rpc.request("fixture_set_projection", fields: ["projection": "unsupported"])
                _ = try? await rpc.request("set_event_filter", fields: fields)
                expect(rpc.capabilities.messageUpdates == .delta, "A rejected setting retains the last confirmed projection")
                _ = try await rpc.request("fixture_set_projection", fields: ["projection": "legacy"])
                _ = try await rpc.request("set_event_filter", fields: fields)
                expect(rpc.capabilities.messageUpdates == .full, "A successful missing echo falls back from delta to full")
            }
            await rpc.stopAndWait(timeout: 5)
        }

        let log = root.appendingPathComponent("projection-startup.jsonl")
        let config = SessionConfiguration(provider: .omp, executable: fixture, workingDirectory: root, environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "OMP_FIXTURE_PROJECTION": "legacy", "OMP_FIXTURE_PROJECTION_LOG": log.path], resumeID: nil,
            resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build,
            apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: config)
        _ = try await session.start()
        let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        let projection = requests.filter { $0["type"]?.string == "set_event_filter" }
        expect(projection.count == 1 && projection[0]["events"] == .null && projection[0]["messageUpdates"]?.string == "delta",
               "Production session startup requests delta once while preserving every event type")
        expect(requests.firstIndex { $0["type"]?.string == "negotiate_protocol" }!
            < requests.firstIndex { $0["type"]?.string == "set_event_filter" }!, "Projection follows native protocol negotiation")
        expect(session.isRunning && session.capabilities.messageUpdates == .full,
               "Legacy success without a projection echo keeps ordinary session startup usable")
        await session.stopAndWait(timeout: 5)
    }
    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let root = CaptureRun.outputDirectory,
              root.path.contains("/build.noindex/verification/runs/"),
              let index = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require fresh isolated output") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try await checkEventProjection(root: root, fixture: fixture)
        let replies = PendingReplies<Int>()
        var sent = false
        let first = Task { try await replies.register("reused", timeout: .milliseconds(80)) { sent = true } }
        try await until { sent }
        expect(replies.resolve("reused", 1), "Initial request resolves")
        expect(try await first.value == 1, "Initial result retained")
        sent = false
        let second = Task { try await replies.register("reused", timeout: .seconds(2)) { sent = true } }
        try await until { sent }
        try await Task.sleep(for: .milliseconds(130))
        expect(replies.resolve("reused", 2), "Old timeout cannot cancel a reused ID")
        expect(try await second.value == 2, "Reused request receives only its own result")

        sent = false
        let pending = Task { try await replies.register("collision", timeout: .seconds(2)) { sent = true } }
        try await until { sent }
        var duplicateSent = false
        do {
            _ = try await replies.register("collision") { duplicateSent = true }
            fatalError("Duplicate ID accepted")
        } catch is PendingReplies<Int>.RegistrationError { }
        expect(!duplicateSent, "Duplicate request is rejected before transport writes")
        expect(replies.resolve("collision", 3), "Duplicate registration preserves the original caller")
        expect(try await pending.value == 3, "Original caller completes after duplicate rejection")

        sent = false
        let cancelled = Task { try await replies.register("cancelled", timeout: .seconds(2)) { sent = true } }
        try await until { sent }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation lost") } catch is CancellationError { }
        expect(!replies.resolve("cancelled", 4), "Cancelled request discards late replies")
        let alreadyCancelled = Task { () throws -> Int in
            try Task.checkCancellation()
            return 0
        }
        alreadyCancelled.cancel()
        _ = await alreadyCancelled.result
        weak var released: PendingReplies<Int>?
        func completedOwner() async throws {
            let owner = PendingReplies<Int>()
            released = owner
            _ = try await owner.register("done", timeout: .seconds(3_600)) { owner.resolve("done", 1) }
        }
        try await completedOwner()
        await Task.yield()
        expect(released == nil, "Completed requests release timer owners immediately")

        var assembler = OMPChunkAssembler()
        let value: JSONValue = ["type": "future_event", "text": "中文🙂"]
        expect(try assembler.append(value)?.value == value, "Unknown native events pass through unchanged")
        let data = value.data()
        let cut = data.count / 2
        expect(try assembler.append(chunk(Data(data.prefix(cut)), index: 0, count: 2, size: data.count))?.value == nil,
               "Incomplete chunk is held off the actor")
        expect(try assembler.append(["type": "heartbeat"])?.value["type"]?.string == "heartbeat", "Interleaved ordinary events retain delivery")
        let completed = try assembler.append(chunk(Data(data.suffix(data.count - cut)), index: 1, count: 2, size: data.count))
        expect(completed?.value == value && completed?.byteCount == data.count, "UTF-8 fragments reassemble exactly and charge their full size")
        for invalid in [chunk(data, index: -1), chunk(data, count: 0), chunk(data, count: 1_025),
                        chunk(data, size: 64 * 1_024 * 1_024 + 1), chunk(data, size: 1),
                        chunk(Data()), chunk(Data("not JSON".utf8)), chunk(JSONValue.object(["type": "rpc_chunk"]).data())] {
            var parser = OMPChunkAssembler()
            do { _ = try parser.append(invalid); fatalError("Invalid frame accepted") } catch is OMPChunkAssembler.FrameError { }
            count += 1
        }
        print("PASS 8 malformed frame boundaries")

        func rpc() throws -> OMPRPC {
            let native = OMPRPC()
            try native.start(executable: fixture, arguments: [], directory: root,
                             environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"])
            return native
        }
        let native = try rpc()
        var unknownFrames = 0
        native.onFrame = { _ in unknownFrames += 1 }
        let unknown = try await native.request("unknown-events")
        expect(unknown["alive"]?.bool == true && unknownFrames == 2, "Unknown events and unsolicited replies do not interrupt a valid request")
        expect(native.capabilities["future-command"] == .unknown, "Unsolicited replies are not capability evidence")
        do { _ = try await native.request("mismatch"); fatalError("Mismatched command accepted") } catch { }
        expect(native.capabilities["mismatch"] == .unknown && native.capabilities["another-command"] == .unknown,
               "A matching ID cannot validate a reply for another command")
        expect(try await native.request("ping")["alive"]?.bool == true, "Protocol mismatch leaves unrelated requests usable")
        var ticks = 0
        var maxGap = 0.0
        var lastTick = ContinuousClock.now
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let elapsed = lastTick.duration(to: .now)
                maxGap = max(maxGap, Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
                lastTick = .now
                ticks += 1
            }
        }
        let large = try await native.request("large", timeout: .seconds(20))
        heartbeat.cancel()
        expect(large["text"]?.string?.utf8.count == 10_000_000, "A 10 MB Unicode frame survives production stdio and RPC")
        expect(ticks > 5, "The main actor keeps running throughout chunk transport")
        await native.stopAndWait(timeout: 5)
        let interrupted = try rpc()
        var largeStarted = false
        interrupted.onFrame = { frame in if frame["type"]?.string == "large-started" { largeStarted = true } }
        let unfinished = Task { try await interrupted.request("large", timeout: .seconds(20)) }
        try await until { largeStarted }
        let stopStart = ContinuousClock.now
        interrupted.stop()
        let stopTime = stopStart.duration(to: .now).components
        let stopMilliseconds = Double(stopTime.seconds) * 1_000 + Double(stopTime.attoseconds) / 1e15
        expect(stopMilliseconds < 100, "Stopping a large transfer returns to the main actor within 100 ms")
        do { _ = try await unfinished.value; fatalError("Stopped transfer completed") } catch { }
        expect(!interrupted.isRunning, "Stop fails the incomplete request without replaying it")
        await interrupted.stopAndWait(timeout: 5)
        for kind in ["overlap", "out-of-order", "truncated", "exit"] {
            let broken = try rpc()
            var exits = 0
            broken.onExit = { _ in exits += 1 }
            do { _ = try await broken.request(kind, timeout: .seconds(5)); fatalError("Fault accepted") } catch { }
            try await until { exits == 1 }
            expect(exits == 1, "\(kind) fails pending work and reports one exit")
            await broken.stopAndWait(timeout: 5)
        }
        let reopened = try rpc()
        expect(try await reopened.request("ping")["alive"]?.bool == true, "A fresh connection recovers after transport failures")
        await reopened.stopAndWait(timeout: 5)

        _ = NSApplication.shared // Framework support only, no GUI app entry point or windows.
        let app = AppModel()
        app.settings.chimeWhenFinished = false
        app.settings.notifyWhenFinished = false
        let project = app.addProject(at: root)
        let broken = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(broken)
        let corruptBytes = Data("{fresh-corruption-fixture".utf8)
        try corruptBytes.write(to: Storage.threadURL(broken.id))
        let recovery = Storage.threadsDirectory.appendingPathComponent("Unreadable")
        try Data("Block backup creation in this fresh test store".utf8).write(to: recovery)
        let runtime = app.runtime(for: broken.id)
        await runtime.ensureLoaded()
        expect(runtime.historyRecoveryBlocked, "Backup failure blocks mutations of a newly damaged session")
        runtime.draft = ComposerDraft(text: "Retain this new draft")
        runtime.send()
        runtime.steerDraft()
        runtime.saveNow()
        DiskWriter.shared.waitForQueuedWrites()
        expect(try Data(contentsOf: Storage.threadURL(broken.id)) == corruptBytes, "Failed preservation never overwrites original file bytes")
        expect(runtime.draft.text == "Retain this new draft" && runtime.unsavedSnapshot() == nil,
               "Send and quit-save leave the retained draft and damaged source untouched")
        expect(!runtime.holdsOnlyPersistedState && !runtime.canBranchConversation, "Recovery-blocked state cannot be silently recycled or branched")
        runtime.cancelPersistence()
        try FileManager.default.removeItem(at: recovery) // Only the blocker created just above.
        let recoveredApp = AppModel()
        recoveredApp.insertThread(broken)
        let recovered = recoveredApp.runtime(for: broken.id)
        await recovered.ensureLoaded()
        expect(!recovered.historyRecoveryBlocked, "Reopen retries preservation after its storage obstruction is repaired")
        let backups = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
        let kept = backups.first!.appendingPathComponent(Storage.threadURL(broken.id).lastPathComponent)
        expect(try Data(contentsOf: kept) == corruptBytes, "Successful recovery retains the exact damaged source in its backup")
        recovered.cancelPersistence()

        try FileManager.default.moveItem(at: recovery, to: recovery.deletingLastPathComponent().appendingPathComponent("KeptBackups"))
        try Data("Block partial backup in this new fixture".utf8).write(to: recovery)
        let partial = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        var head = ThreadDocument(threadID: partial.id)
        head.turnIndex = []
        var stored: [UUID: StoredTurn] = [:]
        for offset in 0..<8 {
            var turn = TurnRecord(index: offset, status: .completed)
            turn.completedAt = turn.startedAt
            let user = TimelineItem(id: "partial-user-\(offset)", turnID: turn.id, content: .user(UserMessage(text: "New row \(offset)")))
            turn.userItemID = user.id
            stored[turn.id] = StoredTurn(turn: turn, items: [user], itemPositions: [user.id: Double(offset)])
            head.turnIndex?.append(ThreadTurnReference(id: turn.id, revision: 1))
        }
        expect(DiskWriter.shared.writeThreadSynchronously(ThreadSave(head: head, dirtyTurns: stored)), "Create fresh segmented corruption fixture")
        let damagedTurn = Storage.turnURL(partial.id, head.turnIndex![0].id)
        try corruptBytes.write(to: damagedTurn)
        let originalHead = try Data(contentsOf: Storage.threadURL(partial.id))
        app.insertThread(partial)
        let partialRuntime = app.runtime(for: partial.id)
        await partialRuntime.ensureLoaded()
        expect(partialRuntime.historyRecoveryBlocked && partialRuntime.turns.count == 6,
               "Unreadable older segment keeps the recent six turns readable when backup fails")
        partialRuntime.saveNow()
        DiskWriter.shared.waitForQueuedWrites()
        expect(try Data(contentsOf: Storage.threadURL(partial.id)) == originalHead && Data(contentsOf: damagedTurn) == corruptBytes,
               "A partial recovery cannot prune damaged segments before preserving them")
        partialRuntime.cancelPersistence()
        try FileManager.default.removeItem(at: recovery)
        let interruptedBackup = UUID()
        try corruptBytes.write(to: Storage.threadURL(interruptedBackup))
        let lockedTurns = Storage.turnsURL(interruptedBackup)
        try FileManager.default.createDirectory(at: lockedTurns, withIntermediateDirectories: true)
        try Data("Unreadable new turn".utf8).write(to: lockedTurns.appendingPathComponent("fixture.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedTurns.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedTurns.path) }
        let incompleteBackup = Storage.setAside(interruptedBackup, moving: true)
        expect(incompleteBackup == nil, "Unreadable turn directory rejects an incomplete multi-file backup")
        expect(try Data(contentsOf: Storage.threadURL(interruptedBackup)) == corruptBytes
            && FileManager.default.fileExists(atPath: lockedTurns.path),
               "Partial backup failure leaves both original head and turn directory in place")
        let report: [String: Any] = ["checks": count, "unicode_frame_bytes": 10_000_000,
            "main_actor_ticks": ticks, "maximum_heartbeat_gap_ms": maxGap,
            "stop_during_transfer_ms": stopMilliseconds,
            "measurement_scope": "Headless production transport; heartbeat is not a displayed-frame measurement."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("summary.json"))
        print("OMP P5 checks passed: \(count); maximum actor gap \(maxGap) ms")
    }
}
