import AppKit
import SwiftUI

/// Wall-clock policy, separate from rendering and native layout. Known dense
/// entry can show immediately; later jobs have a grace period to avoid flashing.
struct ChatMathLoadingState {
    static let denseCount = 16
    static let appearanceDelay = 0.18
    static let minimumPresence = 0.28
    static let maximumWait = 4.0
    struct Presentation: Equatable {
        var hidesContent = false
        var showsSpinner = false
    }
    private(set) var presentation = Presentation()
    private(set) var suppressed = false
    private var beganAt: Double?
    private var waitingSince: Double?
    private var shownAt: Double?
    private var initial = false

    mutating func enter(dense: Bool, immediately: Bool = false, now: Double) {
        self = Self()
        if dense {
            initial = true; beganAt = now
            presentation = Presentation(hidesContent: true, showsSpinner: immediately)
            shownAt = immediately ? now : nil
        }
    }
    mutating func resetSuppression(pending: Int, historyReady: Bool) {
        if pending == 0 && historyReady { suppressed = false }
    }
    mutating func presented(now: Double) {
        if presentation.showsSpinner { shownAt = now }
    }
    /// Returns whether another bounded readiness check is needed.
    mutating func update(pending: Int, historyReady: Bool, settled: Bool, now: Double) -> Bool {
        guard !suppressed else { return false }
        if beganAt == nil {
            guard pending >= Self.denseCount else { return false }
            beganAt = now
        }
        let minimumElapsed = shownAt.map { now - $0 >= Self.minimumPresence } ?? true
        if now - beganAt! >= Self.maximumWait && minimumElapsed {
            let stillWaiting = pending > 0 || !historyReady
            self = Self(); suppressed = stillWaiting
            return false
        }
        // Delayed history pages are part of the same initial preparation, even
        // if the image queue briefly drains between the two mounted windows.
        if pending == 0 && (!initial || historyReady) { waitingSince = nil }
        else if waitingSince == nil { waitingSince = now }
        if pending == 0 && (!initial || historyReady) && settled && minimumElapsed {
            presentation = Presentation(); beganAt = nil; shownAt = nil; initial = false
            return false
        }
        if let waitingSince, now - waitingSince >= Self.appearanceDelay, !presentation.showsSpinner,
           now + Self.minimumPresence <= beganAt! + Self.maximumWait {
            presentation = Presentation(hidesContent: true, showsSpinner: true); shownAt = now
        }
        return true
    }
}

/// One timeline owns one scope. Hidden/prebuilt columns record their cells but
/// do not run a timer. Native views keep laying out underneath the presentation.
@MainActor @Observable final class ChatMathPreparation {
    private(set) var presentation = ChatMathLoadingState.Presentation()
    private(set) var hasInitialAssessment = false
    private(set) var isActive = false
    private(set) var isDenseChat = false
    private(set) var isHistoryLoading = false
    @ObservationIgnored private var state = ChatMathLoadingState()
    @ObservationIgnored private let entries = NSHashTable<MathRendering.Entry>.weakObjects()
    @ObservationIgnored private var historyReady = false
    @ObservationIgnored private var lastGeometry = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private static let settleDelay = 0.12
    private static let densityCache = NSCache<NSString, NSNumber>()

    /// Bounded preflight only decides whether to hide a dense initial frame.
    /// Live scoped pending cells decide whether a spinner is actually needed.
    static func isDense(_ sources: some Sequence<String>) -> Bool {
        var count = 0
        for source in sources.prefix(4) {
            let sample = String(source.prefix(32_768)) as NSString
            let amount: Int
            if let cached = densityCache.object(forKey: sample) { amount = cached.intValue }
            else {
                amount = min(ChatMathLoadingState.denseCount, MarkdownMath.spans(in: sample as String).filter { $0.formula.complete }.count)
                densityCache.countLimit = 48
                densityCache.setObject(NSNumber(value: amount), forKey: sample)
            }
            count += amount
            if count >= ChatMathLoadingState.denseCount { return true }
        }
        return false
    }
    var pendingCount: Int {
        entries.allObjects.filter { entry in
            guard case .pending = entry.result else { return false }
            return entry.cells.allObjects.contains { $0.preparation === self }
        }.count
    }
    func activate(dense: Bool, historyLoading: Bool) {
        let returning = !isActive
        let replacingHistory = historyLoading && !isHistoryLoading
        isActive = true
        isHistoryLoading = historyLoading
        if dense && !isDenseChat { isDenseChat = true }
        guard !historyLoading || isDenseChat || hasInitialAssessment else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !hasInitialAssessment || (replacingHistory && isDenseChat) {
            hasInitialAssessment = true
            state.enter(dense: isDenseChat, immediately: true, now: now)
        } else if returning && (presentation.hidesContent || pendingCount >= ChatMathLoadingState.denseCount) {
            let waiting = pendingCount > 0 || !historyReady || historyLoading || now - lastGeometry < Self.settleDelay
            state.enter(dense: isDenseChat && waiting, immediately: true, now: now)
        }
        state.resetSuppression(pending: pendingCount, historyReady: historyReady && !isHistoryLoading)
        publish(); startMonitor()
    }
    func suspend() {
        generation &+= 1; monitor?.cancel(); monitor = nil
        // Cached columns retain completed preparation and mounted native views.
        // Reentry resumes only unfinished work, not another initial layout cycle.
        isActive = false
    }
    func observe(_ entry: MathRendering.Entry) {
        if !entries.contains(entry) { entries.add(entry); noteGeometryChange() }
        if case .pending = entry.result { startMonitor() }
    }
    func noteGeometryChange() {
        lastGeometry = ProcessInfo.processInfo.systemUptime
        if state.suppressed { state.resetSuppression(pending: pendingCount, historyReady: historyReady && !isHistoryLoading) }
    }
    func historyWindowDidPrepare() {
        historyReady = true; noteGeometryChange()
        if presentation.hidesContent { startMonitor() }
    }
    func spinnerDidAppear() { state.presented(now: ProcessInfo.processInfo.systemUptime) }
    private func publish() {
        if presentation != state.presentation { presentation = state.presentation }
    }
    private func startMonitor() {
        guard isActive, hasInitialAssessment, !state.suppressed, monitor == nil else { return }
        let token = generation
        monitor = Task { @MainActor [weak self] in
            await Task.yield()
            while !Task.isCancelled {
                guard let self, self.generation == token, self.isActive else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let again = self.state.update(pending: self.pendingCount, historyReady: self.historyReady && !self.isHistoryLoading,
                                              settled: now - self.lastGeometry >= Self.settleDelay, now: now)
                self.publish()
                if !again { self.monitor = nil; return }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
    }
}

private struct ChatMathPreparationKey: EnvironmentKey {
    static let defaultValue: ChatMathPreparation? = nil
}
extension EnvironmentValues {
    var chatMathPreparation: ChatMathPreparation? {
        get { self[ChatMathPreparationKey.self] }
        set { self[ChatMathPreparationKey.self] = newValue }
    }
}
