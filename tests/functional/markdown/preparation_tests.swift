import AppKit
@testable import OMPGUI

private struct Failure: Error { let message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}

@main private enum PreparationChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var small = ChatMathLoadingState()
        small.enter(dense: false, now: 0)
        try expect(!small.update(pending: 0, historyReady: true, settled: true, now: 0), "Plain chat started waiting")
        try expect(!small.update(pending: 3, historyReady: true, settled: true, now: 2), "A few formulas started waiting")
        try expect(!small.presentation.hidesContent && !small.presentation.showsSpinner, "Small chat was covered")

        var fast = ChatMathLoadingState()
        fast.enter(dense: true, now: 0)
        _ = fast.update(pending: 30, historyReady: false, settled: false, now: 0)
        _ = fast.update(pending: 0, historyReady: true, settled: true, now: 0.1)
        try expect(!fast.presentation.hidesContent && !fast.presentation.showsSpinner, "A fast cached load flashed a spinner")

        var history = ChatMathLoadingState()
        history.enter(dense: true, now: 0)
        _ = history.update(pending: 0, historyReady: false, settled: true, now: 0)
        _ = history.update(pending: 0, historyReady: false, settled: true, now: 0.2)
        try expect(history.presentation.showsSpinner, "Cached math left a blank wait for the delayed history window")
        _ = history.update(pending: 0, historyReady: true, settled: true, now: 0.6)
        try expect(!history.presentation.hidesContent, "Prepared cached history remained covered")

        var warm = ChatMathLoadingState()
        warm.enter(dense: true, now: 0)
        _ = warm.update(pending: 0, historyReady: true, settled: false, now: 0)
        _ = warm.update(pending: 0, historyReady: true, settled: true, now: 0.13)
        try expect(!warm.presentation.hidesContent && !warm.presentation.showsSpinner, "Mounted cached history flashed a spinner")

        var cold = ChatMathLoadingState()
        cold.enter(dense: true, now: 0)
        _ = cold.update(pending: 30, historyReady: false, settled: false, now: 0)
        try expect(cold.presentation.hidesContent && !cold.presentation.showsSpinner, "Initial raw layout was exposed")
        _ = cold.update(pending: 30, historyReady: false, settled: false, now: 0.2)
        try expect(cold.presentation.showsSpinner, "Slow dense math did not show its indicator")
        _ = cold.update(pending: 0, historyReady: false, settled: true, now: 0.3)
        try expect(cold.presentation.hidesContent, "First idle revealed before the delayed history page")
        cold.presented(now: 0.35)
        _ = cold.update(pending: 0, historyReady: true, settled: true, now: 0.4)
        try expect(cold.presentation.showsSpinner, "Indicator disappeared before minimum presence")
        _ = cold.update(pending: 0, historyReady: true, settled: false, now: 0.6)
        try expect(cold.presentation.hidesContent, "Unsettled native layout was revealed")
        _ = cold.update(pending: 0, historyReady: true, settled: true, now: 0.62)
        try expect(cold.presentation.showsSpinner, "Mounting a delayed indicator skipped its minimum visible time")
        try expect(!cold.update(pending: 0, historyReady: true, settled: true, now: 0.7), "Settled chat stayed covered")

        // The same mounted timeline can wait again after a font/scale cache miss.
        _ = cold.update(pending: 30, historyReady: true, settled: false, now: 2)
        try expect(!cold.presentation.hidesContent, "Rerender skipped its grace period")
        _ = cold.update(pending: 30, historyReady: true, settled: false, now: 2.2)
        try expect(cold.presentation.showsSpinner, "A later dense cache miss never showed waiting")
        _ = cold.update(pending: 0, historyReady: true, settled: true, now: 2.6)
        try expect(!cold.presentation.hidesContent, "Later ready content stayed covered")

        var expired = ChatMathLoadingState()
        expired.enter(dense: true, now: 0)
        _ = expired.update(pending: 30, historyReady: false, settled: false, now: 0)
        _ = expired.update(pending: 30, historyReady: false, settled: false, now: 0.2)
        try expect(!expired.update(pending: 30, historyReady: false, settled: false, now: 4.1)
                   && !expired.presentation.hidesContent, "A renderer failure covered the chat indefinitely")
        try expect(!expired.update(pending: 30, historyReady: false, settled: false, now: 4.2), "Expired jobs immediately started another spinner")
        expired.resetSuppression(pending: 0, historyReady: true)
        _ = expired.update(pending: 30, historyReady: true, settled: false, now: 5)
        try expect(!expired.presentation.showsSpinner, "A new episode reused the expired spinner clock")

        var late = ChatMathLoadingState()
        late.enter(dense: true, now: 0)
        _ = late.update(pending: 0, historyReady: true, settled: false, now: 0)
        _ = late.update(pending: 30, historyReady: true, settled: false, now: 3.6)
        _ = late.update(pending: 30, historyReady: true, settled: false, now: 3.8)
        try expect(!late.presentation.showsSpinner, "An indicator flashed just before the deadline")

        let repeated = (0..<20).map { "$x_{\($0)}$" }.joined(separator: " ")
        try expect(ChatMathPreparation.isDense([repeated]) && !ChatMathPreparation.isDense(["Plain body $x$."]), "Density detection lost its small-chat boundary")
        try expect(!ChatMathPreparation.isDense(["```tex\n\(repeated)\n```"]), "Code samples became waiting formulas")
        try scopeChecks()
        try await lifecycleChecks()
        print("Preparation checks passed: dense/fast/small, reentry, minimum presence, history/layout settling, timeout and native scope isolation.")
    }

    @MainActor private static func lifecycleChecks() async throws {
        let scope = ChatMathPreparation()
        scope.activate(dense: true, historyLoading: true)
        try expect(scope.presentation.showsSpinner, "Known dense entry left a blank grace period")
        scope.historyWindowDidPrepare()
        try await Task.sleep(for: .milliseconds(350))
        try expect(scope.presentation.hidesContent, "Worker replay was ignored when images were already cached")
        scope.activate(dense: true, historyLoading: false)
        try await Task.sleep(for: .milliseconds(150))
        try expect(!scope.presentation.hidesContent, "Completed history did not reveal")
        scope.suspend()
        scope.activate(dense: false, historyLoading: false)
        try expect(scope.hasInitialAssessment && !scope.presentation.hidesContent && !scope.presentation.showsSpinner,
                   "Returning to a prepared mounted timeline started another blank/spinner cycle")
        scope.activate(dense: false, historyLoading: true)
        try expect(scope.presentation.showsSpinner, "A real later history replacement exposed partial content")
        scope.activate(dense: false, historyLoading: false)
        scope.suspend()

        let tracking = TimelineScrollTracking()
        tracking.placementToken = UUID()
        let generation = tracking.navigationGeneration
        tracking.notePhase(.tracking)
        try expect(!tracking.allowsLayoutCorrection && tracking.placementToken == nil && tracking.navigationGeneration > generation,
                   "Finger-down input did not cancel placement before the first moving frame")
        tracking.notePhase(.idle)
        try expect(tracking.allowsLayoutCorrection, "Idle layout correction stayed blocked")
        tracking.noteWheelInput()
        try expect(!tracking.allowsLayoutCorrection, "The first phase-less wheel tick allowed a bottom snap")
        try await Task.sleep(for: .milliseconds(180))
        try expect(tracking.allowsLayoutCorrection, "Old wheel input kept layout repair blocked")
        tracking.endActivity()
    }

    @MainActor private static func scopeChecks() throws {
        let local = ChatMathPreparation(), other = ChatMathPreparation()
        let view = LinkTextView(); view.mathPreparation = local
        let text = NSMutableAttributedString()
        // Pending native cells model asynchronous results without running WebKit.
        for i in 0..<20 {
            let formula = MarkdownFormula(source: "$x_\(i)$", latex: "x_\(i)", mode: .inline, complete: true)
            let entry = MathRendering.Entry(formula, size: 15, scale: 2, key: "scope-\(i)" as NSString)
            let attachment = NSTextAttachment()
            attachment.attachmentCell = MathAttachmentCell(entry: entry, source: formula.source, color: .labelColor, attachment: attachment)
            text.append(NSAttributedString(attachment: attachment))
        }
        view.render(text)
        try expect(local.pendingCount == 20 && other.pendingCount == 0, "Another timeline's pending work entered this scope")
        view.mathPreparation = other
        try expect(local.pendingCount == 0 && other.pendingCount == 20, "Rebound cells left a stale wait in the old scope")
        MathRendering.detach(from: view)
        try expect(other.pendingCount == 0 && !MathRendering.isRendering, "Detached cells or synthetic scope checks left work running")
        local.suspend(); other.suspend()
    }
}
