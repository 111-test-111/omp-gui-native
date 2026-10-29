#if DEBUG
import AppKit
import SwiftUI

/// An explicitly requested GUI acceptance run. Uses a fresh library, scratch Git
/// checkout and native OMP session, never the user's running GUI or chat history.
@MainActor
enum OMPWorkflowAcceptanceRun {
    static var enabled: Bool { CaptureRun.isEnabled && CommandLine.arguments.contains("--omp-workflow-acceptance") }
    private static var checks: [String] = []
    private static var phase = "preparing"
    private static var window: NSWindow?
    private static var runtime: ThreadRuntime?
    private static var approvalCount = 0
    private static var answered = Set<String>()
    private static var originalID: UUID?
    private static var report: [String: JSONValue] = [:]
    private static var output: URL { CaptureRun.outputDirectory! }

    private static func argument(_ key: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static func prepare() {
        guard let root = CaptureRun.storageRoot, let defaults = CaptureRun.defaults,
              output.path.contains("/build.noindex/omp-workflow-live/"),
              !FileManager.default.fileExists(atPath: root.path),
              let executable = argument("--omp-executable"), FileManager.default.isExecutableFile(atPath: executable),
              argument("--omp-model") != nil else { fatalError("Require fresh isolated workflow acceptance storage and explicit native runtime/model") }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            for (key, value) in ["notifyWhenFinished": false, "chimeWhenFinished": false,
                                 "hasSeenHydraIntro": true, "sidebarActivityView": false, "antiSlopEnabled": false] {
                defaults.set(value, forKey: key)
            }
            defaults.set("dark", forKey: "appTheme")
            defaults.set("omp", forKey: "defaultProvider")
            defaults.set(["omp": executable], forKey: "providerBinaryPaths")
            defaults.synchronize()
            var library = Library()
            let project = Project(name: "P1/P2 native acceptance", path: output.appendingPathComponent("workspace").path)
            library.projects = [project]
            var chat = ChatThread(projectID: project.id, provider: .omp, model: argument("--omp-model"), effort: "off", runtimeMode: .supervised)
            chat.title = "P1/P2 · Native workflow acceptance"
            chat.hasCustomTitle = true
            chat.hydraEnabled = false
            library.threads = [chat]
            try JSONEncoder.storage.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
            try writePhase("prepared")
        } catch { fatalError("Cannot prepare isolated workflow acceptance: \(error.localizedDescription)") }
    }

    static func run(model: AppModel) async {
        do {
            await model.bootstrap()
            guard let chat = model.threads.first else { throw Failure("Missing isolated conversation") }
            model.selectedThreadID = chat.id
            let current = model.runtime(for: chat.id)
            runtime = current
            await current.ensureLoaded()
            window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1320, height: 860), threadControls: true)
            window?.title = "OMP P1/P2 Acceptance"
            try writePhase("native-prompt-and-approval")
            current.draft = ComposerDraft(text: "This is an acceptance test in an isolated scratch checkout. Use only read and bash; do not delegate. First read Acceptance.txt. Then run exactly this bash command: sleep 4; printf 'native-changed\\n' > Acceptance.txt; printf 'ACCEPT_TOOL_DONE\\n'. After the tool completes, reply exactly ACCEPT_BASE_FINAL. Do not change any other file.")
            current.send()
            try await wait("native approval", seconds: 240, answerApprovals: false) {
                !current.questions.isEmpty || !current.approvals.isEmpty
            }
            // Additional inputs go through the same composer actions used by the UI.
            current.draft = ComposerDraft(text: "Supplement this same task: retain the requested file operation, then include ACCEPT_STEER_FINAL in your reply.")
            current.steerDraft()
            current.draft = ComposerDraft(text: "After the current task, inspect the attached image and reply exactly ACCEPT_FOLLOW_FINAL. Do not use tools or modify files.", attachments: [Attachment(name: "acceptance.png", path: output.appendingPathComponent("image.png").path, mimeType: "image/png")])
            current.queueDraftAsFollowUp()
            try await wait("native admission during approval", seconds: 60, answerApprovals: false) {
                current.followUps.count == 3 && current.followUps.allSatisfy {
                    $0.ompState == .accepted || $0.ompState == .consumed || $0.ompState == .finished
                }
            }
            try require(!current.questions.isEmpty || !current.approvals.isEmpty,
                "Both additional messages are admitted while native approval is still pending")
            try await wait("all native queued inputs", seconds: 360) {
                current.phase == .idle && current.ompActivity?.canRecycle == true && current.followUps.count == 3 && current.followUps.allSatisfy { $0.ompState?.isTerminal == true }
            }
            try require(current.draft.isEmpty, "Admitted drafts clear after native confirmation")
            let history = try await current.loadNativeHistory()
            try require(history.activeUserEntries.count == 3, "Native history contains each of the three submitted inputs exactly once")
            try require(history.activeUserEntries.last?.message?.images.count == 1, "Native follow-up preserves its image")
            try require(current.turns.allSatisfy { $0.status != .running }, "Every native input group finishes")
            try require(approvalCount > 0, "Additional inputs survive a real native approval wait")
            try require(current.entries.contains { if case .assistant(let answer) = $0.item.content { return answer.text.contains("ACCEPT_FOLLOW_FINAL") }; return false }, "Real model follow-up produces the expected final answer")
            report["native_session_file"] = .string(history.sessionFile)
            report["native_user_entries"] = .array(history.activeUserEntries.map { .string($0.id) })
            try writePhase("history-and-export")
            let export = try await current.exportContextHTML(to: output.appendingPathComponent("native-export.html").path)
            try require(FileManager.default.fileExists(atPath: export), "Native HTML export exists")
            try await current.setAutoCompaction(false)
            try require(current.ompContext.autoCompactionEnabled == false, "Native automatic compaction override is reflected")
            try await current.setAutoCompaction(true)
            try await current.refreshOMPContext()
            report["context_tokens"] = current.ompContext.usedTokens.map(JSONValue.int) ?? .null

            // Inspect the actual multi-turn UI before any history mutation.
            try writePhase("inspection-multi-turn")
            try await waitForMarker("continue")
            try writePhase("native-branch-and-files")
            current.draft = ComposerDraft(text: "Preserved unrelated acceptance draft")
            let previousIDs = Set(model.threads.map(\.id))
            let first = current.turns.first { $0.userItemID != nil }!
            let restored = try await current.revert(to: first.id, restoreFiles: true)
            try require(restored, "Native branch and independently checked file restoration succeed")
            try require(current.turns.isEmpty, "Branch before the first user input retains no later turns")
            let restoredText = try String(contentsOf: output.appendingPathComponent("workspace/Acceptance.txt"), encoding: .utf8)
            try require(restoredText == "native-original\n", "File restoration returns only the test checkout to its initial content")
            let original = model.threads.first { !previousIDs.contains($0.id) }!
            originalID = original.id
            try require(model.runtime(for: original.id).draft.text == "Preserved unrelated acceptance draft", "Original conversation retains the unrelated composer draft")
            try require(original.providerSessionID == history.sessionFile, "Original native session identity remains resumable")
            try require(model.thread(chat.id)?.providerSessionID != history.sessionFile, "Branch adopts OMP's newly returned native session identity")
            try require(model.thread(chat.id)?.model == chat.model, "Branch retains the native model")
            current.draft = ComposerDraft(text: "Reply exactly ACCEPT_BRANCH_FINAL. Do not use tools.")
            current.send()
            try await wait("branched native reply", seconds: 240) { current.phase == .idle && current.ompActivity?.canRecycle == true && current.followUps.allSatisfy { $0.ompState?.isTerminal == true } }
            try require(current.entries.contains { if case .assistant(let answer) = $0.item.content { return answer.text.contains("ACCEPT_BRANCH_FINAL") }; return false }, "Branched session remains usable with the actual model")
            try writePhase("native-compaction-and-handoff")
            try await current.compactContext(customInstructions: "Preserve the acceptance markers and the scratch file path.")
            try require(current.ompContext.lastResult != nil, "Custom compaction returns the native summary")
            // Native handoff correctly declines an unchanged compacted leaf.
            // Add new conversation content before asking it to summarize again.
            current.draft = ComposerDraft(text: "The scratch acceptance file was restored, the original conversation and draft were retained, and this branched session was compacted. Reply exactly ACCEPT_AFTER_COMPACT_FINAL. Do not use tools.")
            current.send()
            try await wait("post-compaction native reply", seconds: 240) {
                current.phase == .idle && current.ompActivity?.canRecycle == true && current.followUps.allSatisfy { $0.ompState?.isTerminal == true }
            }
            try require(current.entries.contains { if case .assistant(let answer) = $0.item.content { return answer.text.contains("ACCEPT_AFTER_COMPACT_FINAL") }; return false }, "Compacted session accepts a new native turn")
            let handoff = try await current.handoffContext(customInstructions: "Record only this scratch acceptance test and its markers.")
            try require(handoff.completed, "Native handoff confirms completion")
            report["handoff_path"] = handoff.savedPath.map(JSONValue.string) ?? .null
            try await current.refreshOMPContext()
            try writePhase("inspection-final")
            try await waitForMarker("finish")
            current.stopSession()
            current.saveNow()
            for thread in model.threads { model.existingRuntime(for: thread.id)?.cancelPersistence() }
            try writeReport(status: "completed")
            try writePhase("completed")
            NSApp.terminate(nil)
        } catch {
            runtime?.stopSession()
            try? writeReport(status: "failed", error: error.localizedDescription)
            try? writePhase("failed", error: error.localizedDescription)
            // The isolated window remains available for inspection of a failure.
        }
    }

    private static func wait(_ label: String, seconds: Int, answerApprovals: Bool = true, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate() {
            try Task.checkCancellation()
            if answerApprovals { try answerScratchApprovals() }
            guard ContinuousClock.now < deadline else { throw Failure("Timed out waiting for \(label)") }
            if let runtime, runtime.phase == .idle, runtime.followUps.contains(where: { $0.ompState == .failed || $0.ompState == .unknown }) {
                throw Failure("Native submission failed or became uncertain during \(label)")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        if answerApprovals { try answerScratchApprovals() }
    }

    private static func answerScratchApprovals() throws {
        guard let runtime else { return }
        for request in runtime.approvals where answered.insert(request.id).inserted {
            guard let option = request.options.first(where: { $0.role == .approve }) else { throw Failure("No one-time approval available") }
            runtime.resolve(request, option: option)
            approvalCount += 1
        }
        for request in runtime.questions where answered.insert(request.id).inserted {
            var answers: [String: QuestionAnswer] = [:]
            for question in request.questions {
                guard let choice = question.choices.first(where: { ["yes", "allow once", "allow", "approve", "run once"].contains($0.label.lowercased()) }) else {
                    throw Failure("Unexpected native question in scratch acceptance")
                }
                answers[question.id] = QuestionAnswer(selectedOptions: [choice.label])
            }
            runtime.answer(request, answers: answers)
            approvalCount += 1
        }
    }

    private static func waitForMarker(_ name: String) async throws {
        try await wait("explicit GUI inspection \(name)", seconds: 600) { FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path) }
    }

    private static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(label) }
        checks.append(label)
    }

    private static func writePhase(_ value: String, error: String? = nil) throws {
        phase = value
        let value: JSONValue = ["phase": .string(value), "gui_pid": .int(Int(ProcessInfo.processInfo.processIdentifier)), "error": error.map(JSONValue.string) ?? .null]
        try value.data().write(to: output.appendingPathComponent("phase.json"), options: .atomic)
    }

    private static func writeReport(status: String, error: String? = nil) throws {
        report["status"] = .string(status)
        report["phase"] = .string(phase)
        report["checks"] = .array(checks.map(JSONValue.string))
        report["approval_count"] = .int(approvalCount)
        report["model"] = argument("--omp-model").map(JSONValue.string) ?? .null
        report["error"] = error.map(JSONValue.string) ?? .null
        report["scope"] = "Actual GUI + installed native OMP/model in an isolated scratch checkout. Active profile is read by OMP; not copied or modified by the GUI. P0 resource attribution and cross-version P5 acceptance are separate."
        try JSONValue.object(report).data().write(to: output.appendingPathComponent("report.json"), options: .atomic)
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { message }
        let message: String
        init(_ message: String) { self.message = message }
    }
}
#endif
