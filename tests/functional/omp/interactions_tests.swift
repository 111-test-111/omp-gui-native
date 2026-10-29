import AppKit
import Foundation
import SwiftUI
@testable import OMPGUI

@main
struct OMPInteractionChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func approvalLayout(_ request: ApprovalRequest, output: URL, name: String) throws -> CGSize {
        let content = VStack(spacing: 12) {
            HStack(spacing: 8) {
                ThreadWaitingBadge(status: .approval)
                ThreadWaitingBadge(status: .question)
            }
            ApprovalSheet(request: request, state: .waiting, canSubmit: true) { _ in }
        }
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        expect(size.width == 460 && size.height > 100 && size.height < 460, "The approval sheet keeps its fixed popover width with a bounded height")
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(!descendants(host).contains { ($0 as? NSTextField)?.isEditable == true || ($0 as? NSTextView)?.isEditable == true },
               "Approvals expose direct decisions without an editable question field")
        for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) {
            expect(scroll.frame.height <= 260, "Long native approval details stay in a bounded scroller")
        }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
        }
        return size
    }

    @MainActor static func main() async throws {
        guard let root = CaptureRun.storageRoot, root.path.contains("/build.noindex/verification/runs/"),
              let fixtureIndex = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require isolated fixture storage") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[fixtureIndex + 1])
        let config = SessionConfiguration(provider: .omp, executable: fixture, workingDirectory: root,
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "OMP_FIXTURE_LOG": root.appendingPathComponent("requests.txt").path,
                          "OMP_FIXTURE_SESSION_FILE": root.appendingPathComponent("native.jsonl").path,
                          "OMP_FIXTURE_RESPONSES": root.appendingPathComponent("responses.jsonl").path],
            resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build, apiKey: nil, hydra: nil)
        let app = AppModel()
        let chatA = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        let chatB = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(chatA); app.insertThread(chatB)
        let runtimeA = app.runtime(for: chatA.id), runtimeB = app.runtime(for: chatB.id)
        expect(runtimeA.pendingInteractionStatus == nil && runtimeB.pendingInteractionStatus == nil, "Idle conversations have no waiting label")
        let previousSession = OMPSession(configuration: config)
        runtimeB.observe(previousSession)
        let staleEvent = previousSession.onEvent!
        let currentSession = OMPSession(configuration: config)
        runtimeB.observe(currentSession)
        let ask: JSONValue = ["type": "extension_ui_request", "id": "same-id", "method": "editor", "title": "Edit", "prefill": "initial"]
        let requestA = OMPExtensionDialog.request(ask)!, requestB = OMPExtensionDialog.request(ask)!
        runtimeA.receiveOMPEvent(.question(requestA)); runtimeB.receiveOMPEvent(.question(requestB))
        let itemA = runtimeA.pendingInteraction(for: requestA.instanceID)!, itemB = runtimeB.pendingInteraction(for: requestB.instanceID)!
        expect(itemA !== itemB && runtimeB.pendingInteraction(for: itemA.id) == nil, "Concurrent sessions may use the same native request id without sharing answers")
        expect(runtimeA.pendingInteractionStatus == .question && runtimeB.pendingInteractionStatus == .question, "Each waiting conversation reports an answer label")
        itemA.draft.write("中文 draft A", for: requestA.questions[0])
        app.selectedThreadID = chatB.id
        app.selectedThreadID = chatA.id
        let reopened = runtimeA.pendingInteraction(for: requestA.instanceID)!
        expect(reopened === itemA && reopened.draft.values["same-id"]?.customInput == "中文 draft A", "Reopening the source conversation retains the same question draft")
        expect(itemB.draft.values["same-id"]?.customInput == "initial", "Editing one session never changes another session's draft")
        expect(itemA.beginSubmission() && !itemA.beginSubmission(), "Two windows cannot submit the same request twice")
        itemA.reportDelivery(false)
        expect(itemA.state == .deliveryUnknown && !itemA.canSubmit && itemA.draft.values["same-id"]?.customInput == "中文 draft A", "Unknown delivery retains input and prevents blind resend")
        expect(runtimeA.pendingInteractionStatus == .question, "Uncertain native responses remain visible in their conversation")
        let approval = ApprovalRequest(id: "approval", kind: .tool, title: "Allow tool", options: [.init(id: "allow", title: "Allow", role: .approve)])
        runtimeA.receiveOMPEvent(.approval(approval))
        expect(runtimeA.pendingInteractionStatus == .approval && runtimeB.pendingInteractionStatus == .question, "Approval takes precedence without changing another conversation's waiting label")
        runtimeA.receiveOMPEvent(.ompRequestEnded(instanceID: approval.instanceID, reason: .delivered))
        expect(runtimeA.pendingInteractionStatus == .question, "Resolving an approval restores a remaining answer label")
        runtimeA.receiveOMPEvent(.ompRequestEnded(instanceID: itemA.id, reason: .cancelled))
        expect(itemA.state == .cancelled && !itemA.canSubmit && runtimeA.pendingInteractionStatus == nil, "Native cancellation withdraws the uncertain request and its waiting label")
        staleEvent(.sessionReady(sessionID: "wrong"))
        expect(itemB.identity.sessionID == nil, "Startup identity discovery cannot cross process generations")
        currentSession.onEvent?(.sessionReady(sessionID: "native-startup"))
        expect(itemB.identity.sessionID == "native-startup", "A startup dialog adopts its first confirmed native session identity")
        currentSession.onEvent?(.sessionReady(sessionID: "other-session"))
        expect(itemB.identity.sessionID == "native-startup", "A known native request identity is never rebound to another session")
        staleEvent(.ompRequestEnded(instanceID: itemB.id, reason: .delivered))
        expect(itemB.state == .waiting, "An old process generation cannot resolve a current form")
        itemB.draft.write("retained after timeout", for: requestB.questions[0])
        runtimeB.receiveOMPEvent(.ompRequestEnded(instanceID: itemB.id, reason: .timedOut))
        runtimeB.receiveOMPEvent(.requestResolved(id: requestB.id))
        expect(itemB.state == .timedOut && itemB.draft.values["same-id"]?.customInput == "retained after timeout", "Timeout is distinct from cancellation and retains unsent input")
        expect(runtimeB.questions.isEmpty && runtimeB.pendingInteractionStatus == nil && runtimeB.pendingInteraction(for: itemB.id) == nil, "Timed-out requests leave the source actions and waiting label without a recent-request archive")
        var expired = requestB; expired.instanceID = UUID(); expired.deadline = .now.addingTimeInterval(-1)
        let expiredItem = OMPInteraction(identity: .init(threadID: chatB.id, generation: 0, sessionID: "native", nativeID: expired.id, instanceID: expired.instanceID), question: expired)
        expect(!expiredItem.beginSubmission() && expiredItem.state == .timedOut, "Deadline is checked again at submit time")

        let native = OMPSession(configuration: config)
        native.onEvent = { runtimeA.receiveOMPEvent($0) }
        try native.rpc.start(executable: fixture, arguments: [], directory: root, environment: config.environment)
        let confirmation: JSONValue = ["type": "extension_ui_request", "id": "approval-card", "method": "confirm",
            "title": "Allow this workspace action?", "message": "Run the requested build in the task worktree.", "timeout": 30_000]
        let nativeDialog = OMPExtensionDialog.request(confirmation)!
        let projection = OMPExtensionDialog.approval(for: nativeDialog, frame: confirmation)!
        expect(projection.instanceID == nativeDialog.instanceID && projection.deadline == nativeDialog.deadline,
               "Approval projection preserves the native request instance and deadline")
        expect(projection.title == "Allow this workspace action?" && projection.detail == "Run the requested build in the task worktree.",
               "Approval cards retain native titles and explanatory text separately")
        expect(OMPExtensionDialog.approval(for: requestA, frame: ask) == nil, "Ordinary input never becomes an approval by inspecting its wording")
        var expiredApproval = projection; expiredApproval.deadline = .now.addingTimeInterval(-1)
        let expiredApprovalItem = OMPInteraction(identity: .init(threadID: chatA.id, generation: 0, sessionID: nil,
            nativeID: projection.id, instanceID: projection.instanceID), approval: expiredApproval)
        expect(!expiredApprovalItem.beginSubmission() && expiredApprovalItem.state == .timedOut, "Approval deadlines are checked again before submission")
        expect(projection.decisions.map(\.id) == ["No", "Yes"] && projection.options.count == 2,
               "Confirmation cards expose only denial and single-call allowance")
        for option in ["Yes", "No"] {
            native.rpc.onFrame?(confirmation)
            let approval = runtimeA.approvals.last!
            let item = runtimeA.pendingInteraction(for: approval.instanceID)!
            expect(runtimeA.questions.isEmpty && runtimeA.pendingInteractionStatus == .approval && item.approval != nil,
                   "Native confirm opens a dedicated approval card and approval waiting badge")
            expect(item.beginSubmission(), "An approval allows one live response")
            var delivered: Bool?
            native.resolveApproval(approval.id, optionID: option) { success in
                item.reportDelivery(success)
                delivered = success
            }
            for _ in 0..<100 where delivered == nil { try await Task.sleep(for: .milliseconds(10)) }
            expect(delivered == true && item.state == .delivered && runtimeA.approvals.isEmpty && runtimeA.pendingInteractionStatus == nil,
                   "Each native approval decision retires its own card and waiting badge after the write")
        }
        let prompt = "Allow tool: bash\nReason: This command needs execution approval.\nCommand: make build && printf '中文\\n'\nProvider safety checks:\nKeep this native warning visible."
        let select: JSONValue = ["type": "extension_ui_request", "id": "tool-approval", "method": "select",
            "title": .string(prompt), "options": ["Approve", "Deny"], "timeout": 30_000]
        let toolDialog = OMPExtensionDialog.request(select)!
        let toolCard = OMPExtensionDialog.approval(for: toolDialog, frame: select)!
        expect(toolCard.tool?.name == "bash" && toolCard.tool?.reason == "This command needs execution approval.",
               "Native tool approval exposes the actual tool and leading reason separately")
        expect(toolCard.tool?.command == "make build && printf '中文\\n'\nProvider safety checks:\nKeep this native warning visible.",
               "Command formatting preserves all native command text and appended safety details")
        expect(toolCard.instanceID == toolDialog.instanceID && toolCard.deadline == toolDialog.deadline && toolCard.decisions.map(\.id) == ["Deny", "Approve"],
               "Tool cards preserve native request identity, timeout and exact decision values")
        let filePrompt = "Allow tool: write\nPath: /tmp/配置.json\nContent:\n{\"Reason\": \"content must remain data\", \"enabled\": true}\n"
        let fileInfo = OMPToolApproval(prompt: filePrompt)!
        expect(fileInfo.file?.path == "/tmp/配置.json" && fileInfo.file?.content == "{\"Reason\": \"content must remain data\", \"enabled\": true}\n" && fileInfo.reason == nil,
               "Write previews split the target path without treating file content as metadata")
        let windowsFile = OMPToolApproval(prompt: filePrompt.replacingOccurrences(of: "\n", with: "\r\n"))!
        expect(windowsFile.file?.path == "/tmp/配置.json" && windowsFile.file?.content.hasSuffix("\r\n") == true,
               "Approval metadata recognizes CRLF without normalizing file content")
        let custom = OMPToolApproval(prompt: "Allow tool: mcp__server__custom\nOrigin: MCP server tool\nReason: Confirm the action.\nUnrecognized: preserve this detail.\n")!
        expect(custom.origin == "MCP server tool" && custom.details == "Unrecognized: preserve this detail.\n", "Unknown native tool details remain verbatim")
        expect(OMPToolApproval(prompt: "Allow tool: ") == nil, "Missing tool identity cannot open a tool approval")
        var ordinary = select.object!; ordinary["title"] = "Choose the next action"
        expect(OMPExtensionDialog.request(.object(ordinary))?.toolApproval == nil, "Approve/Deny labels alone cannot reclassify an ordinary select")
        ordinary["title"] = .string(prompt); ordinary["options"] = ["Approve", 42, "Deny"]
        expect(OMPExtensionDialog.request(.object(ordinary))?.toolApproval == nil, "Malformed option lists cannot enter the native approval path")
        ordinary["options"] = ["Approve", "Deny"]; ordinary["method"] = "input"
        expect(OMPExtensionDialog.request(.object(ordinary))?.toolApproval == nil, "Only the native selection method can identify a tool approval")
        for choices: [String] in [
            ["Approve", "Approve bash for this session", "Deny"],
            ["Approve Directory: ~/project", "Approve File", "Always Approve Directory: ~/project", "Always Approve File", "Approve Once", "Deny"],
            ["Approve", "Always Approve", "Approve Once", "Deny"],
        ] {
            var fields = select.object!
            fields["options"] = .array(choices.map(JSONValue.string))
            let frame = JSONValue.object(fields)
            let dialog = OMPExtensionDialog.request(frame)!
            let card = OMPExtensionDialog.approval(for: dialog, frame: frame)!
            let once = choices.contains("Approve Once") ? "Approve Once" : "Approve"
            expect(card.decisions.map(\.id) == ["Deny", once] && card.options.count == 2,
                   "Expanded native approvals retain exactly denial and single-call allowance, never a grant")
            for option in card.decisions {
                native.rpc.onFrame?(frame)
                let current = runtimeA.approvals.last!
                expect(runtimeA.pendingInteractionStatus == .approval && runtimeA.questions.isEmpty,
                       "Expanded approvals retain the approval badge and dedicated card")
                let item = runtimeA.pendingInteraction(for: current.instanceID)!
                if once == "Approve Once" {
                    var accepted = true
                    native.resolveApproval(current.id, optionID: "Approve") { accepted = $0 }
                    expect(!accepted && item.state == .waiting,
                           "A cached grant named Approve cannot bypass the session's single-call decision guard")
                }
                expect(item.beginSubmission(), "Expanded approval admits one live decision")
                native.resolveApproval(current.id, optionID: option.id) { item.reportDelivery($0) }
                for _ in 0..<100 where item.state == .submitting { try await Task.sleep(for: .milliseconds(10)) }
                expect(item.state == .delivered && runtimeA.approvals.isEmpty,
                       "Expanded approval decisions retire only their own live request")
            }
        }
        for choices: [String] in [["Approve Once", "Deny", "Deny"], ["Approve", "Unknown grant", "Deny"],
                                  ["Approve File", "Deny"], ["Always Approve", "Deny"]] {
            var fields = select.object!; fields["options"] = .array(choices.map(JSONValue.string))
            expect(OMPExtensionDialog.request(.object(fields))?.toolApproval == nil,
                   "Ambiguous, duplicate or grant-only options never become single-call approval buttons")
        }
        for option in ["Approve", "Deny"] {
            native.rpc.onFrame?(select)
            let approval = runtimeA.approvals.last!
            let item = runtimeA.pendingInteraction(for: approval.instanceID)!
            expect(runtimeA.questions.isEmpty && runtimeA.pendingInteractionStatus == .approval, "Native select approvals bypass question and Send controls")
            expect(item.beginSubmission(), "Tool approval admits one decision")
            native.resolveApproval(approval.id, optionID: option)
            for _ in 0..<100 where item.state == .submitting { try await Task.sleep(for: .milliseconds(10)) }
            expect(item.state == .delivered && runtimeA.approvals.isEmpty, "The no-callback native approval entry retires the correct tool card")
        }
        _ = try await native.rpc.request("get_state") // Ordered barrier after the native decisions.
        let responses = try String(contentsOf: root.appendingPathComponent("responses.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
        expect(responses.count == 10 && responses[0]["confirmed"]?.bool == true && responses[1]["confirmed"]?.bool == false,
               "Approve and Decline retain native true/false confirmation values")
        expect(responses.suffix(2).map { $0["value"]?.string } == ["Approve", "Deny"] && responses.allSatisfy { $0["cancelled"] == nil },
               "Tool decisions return native selected values instead of booleans or cancellation")
        expect(responses.dropFirst(2).prefix(6).compactMap { $0["value"]?.string }
            == ["Deny", "Approve", "Deny", "Approve Once", "Deny", "Approve Once"],
               "Single-call approval preserves the native label even when Approve itself names a cached grant")
        _ = try approvalLayout(toolCard, output: root, name: "approval-tool")
        var fileFields = select.object!; fileFields["title"] = .string(filePrompt)
        let fileFrame = JSONValue.object(fileFields)
        let fileRequest = OMPExtensionDialog.request(fileFrame)!
        let fileCard = OMPExtensionDialog.approval(for: fileRequest, frame: fileFrame)!
        _ = try approvalLayout(fileCard, output: root, name: "approval-file")
        var longApproval = toolCard
        longApproval.detail = String(repeating: "Read the requested command and its scope before approving. 中文权限说明。\n", count: 80)
        _ = try approvalLayout(longApproval, output: root, name: "approval-long")
        native.rpc.onFrame?(confirmation)
        let cancelledApproval = runtimeA.pendingInteraction(for: runtimeA.approvals.last!.instanceID)!
        native.rpc.onFrame?(["type": "extension_ui_request", "id": "cancel-approval", "method": "cancel", "targetId": "approval-card"])
        expect(cancelledApproval.state == .cancelled && runtimeA.approvals.isEmpty, "Native cancellation withdraws an approval card by its instance")
        native.rpc.onFrame?(ask)
        var invalidApprovalAccepted = true
        native.resolveApproval(requestA.id, optionID: "Yes") { invalidApprovalAccepted = $0 }
        expect(!invalidApprovalAccepted && !runtimeA.questions.isEmpty, "Approval actions cannot answer a reused native ID belonging to a question")
        let sentRequest = runtimeA.questions.last!, sent = runtimeA.pendingInteraction(for: sentRequest.instanceID)!
        sent.draft.write("one response", for: sentRequest.questions[0]); _ = sent.beginSubmission()
        var completed = false
        native.answerQuestion(sentRequest.id, answers: sent.draft.answers(for: sentRequest)) { success in completed = success }
        for _ in 0..<100 where !completed { try await Task.sleep(for: .milliseconds(10)) }
        expect(completed && sent.state == .delivered && sent.draft.values.isEmpty, "Only confirmed transport delivery clears a submitted draft")
        expect(runtimeA.questions.isEmpty && runtimeA.pendingInteractionStatus == nil && runtimeA.pendingInteraction(for: sent.id) == nil, "Delivered native forms and their waiting labels retire from the source conversation")
        native.rpc.onFrame?(ask)
        let beforeReuse = runtimeA.questions.last!, old = runtimeA.pendingInteraction(for: beforeReuse.instanceID)!
        old.draft.write("keep this", for: beforeReuse.questions[0]); _ = old.beginSubmission()
        var oldCallback: Bool?
        native.answerQuestion(beforeReuse.id, answers: old.draft.answers(for: beforeReuse)) { oldCallback = $0 }
        native.rpc.onFrame?(ask) // replace before the queued pipe callback runs
        let replacement = runtimeA.questions.last!, replacementItem = runtimeA.pendingInteraction(for: replacement.instanceID)!
        for _ in 0..<100 where oldCallback == nil { try await Task.sleep(for: .milliseconds(10)) }
        expect(oldCallback == false && old.state == .cancelled, "A delayed write callback cannot mark a replacement native request as delivered")
        expect(replacement.instanceID != beforeReuse.instanceID && replacementItem.state == .waiting && runtimeA.questions.count == 1, "Reused native ids keep the new form actionable")
        native.rpc.onFrame?(["type": "extension_ui_request", "id": "cancel", "method": "cancel", "targetId": .string(replacement.id)])
        expect(replacementItem.state == .cancelled && runtimeA.questions.isEmpty, "Native cancellation targets the current request instance")
        native.rpc.onFrame?(["type": "extension_ui_request", "id": "short", "method": "input", "title": "Short", "timeout": 1])
        let timed = runtimeA.pendingInteraction(for: runtimeA.questions.last!.instanceID)!
        try await Task.sleep(for: .milliseconds(20))
        expect(timed.state == .timedOut && !timed.canSubmit, "The production native deadline withdraws the timed-out question")
        native.rpc.onFrame?(ask)
        let closing = runtimeA.pendingInteraction(for: runtimeA.questions.last!.instanceID)!
        closing.draft.write("retained on exit", for: closing.question!.questions[0])
        await native.stopAndWait(timeout: 2)
        expect(closing.state == .disconnected && closing.draft.values["same-id"]?.customInput == "retained on exit", "Process shutdown withdraws actions and preserves unfinished input")
        let replacementSession = OMPSession(configuration: config)
        runtimeA.observe(replacementSession)
        var staleAccepted = true
        runtimeA.answer(closing.question!, answers: closing.draft.answers(for: closing.question!)) { staleAccepted = $0 }
        expect(!staleAccepted && closing.state == .disconnected, "A stale form cannot be submitted into another observed process")
        var stopRequest = requestA; stopRequest.instanceID = UUID()
        runtimeA.receiveOMPEvent(.question(stopRequest))
        let stopped = runtimeA.pendingInteraction(for: stopRequest.instanceID)!
        runtimeA.stopSession()
        expect(runtimeA.questions.isEmpty && stopped.state == .disconnected, "Explicit session release withdraws source actions even after event handlers are detached")
        expect(runtimeA.pendingInteractionStatus == nil && runtimeA.pendingInteraction(for: stopped.id) == nil, "Session release removes the waiting label and live form storage")
        runtimeA.cancelPersistence(); runtimeB.cancelPersistence()
        print("OMP native interaction checks passed: \(checks)")
    }
}
