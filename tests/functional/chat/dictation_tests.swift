import AppKit
import Foundation
@testable import OMPGUI

@MainActor
private final class SpeechFixture: DictationService {
    var installed = true
    var supported = true
    var microphonePermission: DictationMicrophonePermission = .allowed
    var isRecording = false
    var permissionRequests = 0
    var recordings = 0
    var installs = 0
    var cleanups = 0
    var result = "听写内容"
    var transcription: CheckedContinuation<String, Never>?
    var holdTranscription = false
    var installation: CheckedContinuation<Void, Never>?
    var holdInstallation = false
    var failure: DictationError?

    func supportedLanguages() async -> [String] { supported ? ["zh_CN", "en_US"] : [] }
    func language(_ identifier: String) async throws -> DictationLanguage {
        guard supported else { throw DictationError.unsupportedLanguage }
        return DictationLanguage(identifier: identifier, installed: installed)
    }
    func install(_ identifier: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        installs += 1
        progress(0.5)
        if holdInstallation { await withCheckedContinuation { installation = $0 } }
        if let failure { throw failure }
        installed = true
        progress(1)
    }
    func requestMicrophonePermission() async -> Bool { permissionRequests += 1; microphonePermission = .allowed; return true }
    func startRecording() throws { recordings += 1; isRecording = true }
    func stopRecording() throws -> URL {
        isRecording = false
        if let failure { throw failure }
        return URL(fileURLWithPath: "/unused-dictation-fixture.wav")
    }
    func transcribe(_ url: URL, language: String) async throws -> String {
        if holdTranscription { return await withCheckedContinuation { transcription = $0 } }
        return result
    }
    func cancelCapture() { isRecording = false }
    func cleanUp() async { isRecording = false; cleanups += 1 }
}

@main
struct DictationChecks {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }
    @MainActor static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Dictation lifecycle did not settle at line \(line)")
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let defaults = CaptureRun.defaults else { fatalError("Require isolated preferences") }
        _ = NSApplication.shared
        let app = AppModel()
        let thread = app.newThread(affiliation: .standalone)!
        let runtime = app.runtime(for: thread.id)
        await runtime.ensureLoaded()
        let service = SpeechFixture()
        let dictation = ComposerDictation(service: service, defaults: defaults, isAppActive: { true })
        let quote = ReplyQuote(text: "引用")
        runtime.draft = ComposerDraft(text: "已有", quotes: [quote], command: DraftCommand(name: "test", detail: "", isBuiltIn: false))
        let identity = runtime.draft.id
        expect(service.recordings == 0 && service.installs == 0 && service.permissionRequests == 0, "Creating an editor has no audio, permission or download side effect")
        dictation.activate(runtime: runtime)
        expect(dictation.phase == .checking && !dictation.showsComposerStatus, "Microphone preflight never inserts a checking text row")
        try await wait { dictation.isRecording }
        expect(runtime.isDictating && runtime.draft.id == identity, "Recording locks submission without replacing the draft")
        let before = runtime.draft
        runtime.send(); runtime.steerDraft(); runtime.queueDraftAsFollowUp(); runtime.interruptAndSend()
        expect(runtime.draft == before && runtime.followUps.isEmpty && !runtime.isRunning, "Every draft delivery route is blocked while dictating")
        runtime.draft.text += " 编辑"
        dictation.finishRecording()
        try await wait { !dictation.isBusy }
        expect(runtime.draft.text == "已有 编辑 听写内容", "Dictation appends to edits made during capture")
        expect(runtime.draft.quotes == [quote] && runtime.draft.command?.name == "test" && runtime.draft.id == identity,
               "Quotes, slash commands and draft identity survive dictation")
        expect(!runtime.isDictating && service.cleanups == 1 && !runtime.isRunning && runtime.followUps.isEmpty,
               "Success releases capture and never sends text automatically")

        service.microphonePermission = .undetermined
        dictation.activate(runtime: runtime)
        try await wait { !dictation.isBusy }
        expect(service.permissionRequests == 0 && service.recordings == 1 && !runtime.isDictating && dictation.requiresSetup,
               "An unprepared microphone only points to Settings and never opens permission UI")
        let permissionService = SpeechFixture()
        permissionService.microphonePermission = .undetermined
        let setup = ComposerDictation(service: permissionService, defaults: defaults, isAppActive: { true })
        setup.requestPermission()
        try await wait { !setup.isBusy }
        expect(permissionService.permissionRequests == 1 && permissionService.recordings == 0 && setup.microphonePermission == .allowed,
               "Only the explicit Settings permission action requests access and never records")
        service.microphonePermission = .denied
        dictation.activate(runtime: runtime)
        try await wait { !dictation.isBusy }
        expect(service.recordings == 1 && dictation.notice != nil && runtime.draft.id == identity, "Denied permission preserves the draft")

        service.microphonePermission = .allowed
        service.installed = false
        dictation.activate(runtime: runtime)
        try await wait { !dictation.isBusy }
        expect(dictation.requiresSetup && service.installs == 0 && service.recordings == 1,
               "Missing assets only points to Settings without an automatic window, download or capture")
        dictation.download()
        try await wait { !dictation.isBusy }
        expect(service.installs == 1 && dictation.installed && service.recordings == 1, "Explicit installation never starts recording")
        dictation.selectLanguage("zh_CN")
        await dictation.refreshLanguages()
        expect(dictation.installed, "A verified language reports its installed assets")
        dictation.download()
        try await wait { !dictation.isBusy }
        expect(service.installs == 2 && dictation.installed, "Reinstalling installed assets runs the install flow again and stays ready")
        dictation.selectLanguage("en_US")
        expect(dictation.installed, "Switching language keeps the verified asset state instead of flashing the install hint")
        service.installed = false
        await dictation.refreshLanguages()
        expect(!dictation.installed, "A checked language reports its own missing assets")
        dictation.selectLanguage("zh_CN")
        expect(dictation.installed, "Returning to a verified language restores its asset state without another flash")
        dictation.activate(runtime: runtime)
        try await wait { !dictation.isBusy }
        service.holdInstallation = true
        dictation.download()
        try await wait { service.installation != nil }
        dictation.cancel()
        service.installation?.resume(); service.installation = nil
        try await wait { !dictation.isBusy }
        expect(!dictation.installed && service.recordings == 1 && !runtime.isDictating,
               "A download completing after cancellation cannot publish readiness or record")
        service.holdInstallation = false
        dictation.dismissNotice()
        dictation.selectLanguage("zh_CN")
        expect(defaults.string(forKey: "dictationLanguage") == "zh_CN", "Language choice stays in the GUI edition's preferences")

        service.holdTranscription = true
        dictation.activate(runtime: runtime)
        try await wait { dictation.isRecording }
        dictation.finishRecording()
        try await wait { service.transcription != nil }
        let kept = runtime.draft
        dictation.cancel()
        expect(dictation.phase == .cancelling && runtime.isDictating && !service.isRecording,
               "Cancellation stops capture immediately and retains the lock until the in-flight operation drains")
        service.transcription?.resume(returning: "迟到结果"); service.transcription = nil
        try await wait { !dictation.isBusy }
        expect(runtime.draft == kept && !runtime.isDictating && !service.isRecording, "Late transcription after cancellation is discarded and capture cleaned")

        service.holdTranscription = false
        dictation.activate(runtime: runtime)
        try await wait { dictation.isRecording }
        runtime.draft = ComposerDraft(text: kept.text)
        dictation.finishRecording()
        try await wait { !dictation.isBusy }
        expect(runtime.draft.text == kept.text && dictation.recoveredTranscript == service.result,
               "A replaced draft with identical text cannot receive another message's transcript")

        let other = ComposerDictation(service: SpeechFixture(), defaults: defaults, isAppActive: { true })
        dictation.activate(runtime: runtime)
        try await wait { dictation.isRecording }
        other.activate(runtime: runtime)
        expect(!other.isBusy && other.notice != nil && runtime.isDictating, "A second editor cannot take an existing microphone lease")
        dictation.cancel()
        try await wait { !dictation.isBusy }
        other.activate(runtime: runtime)
        try await wait { other.isRecording }
        other.cancel()
        try await wait { !other.isBusy }
        expect(!runtime.isDictating, "Cancellation makes the microphone available to another editor")

        service.failure = .recordingFailed
        dictation.activate(runtime: runtime)
        try await wait { dictation.isRecording }
        dictation.finishRecording()
        try await wait { !dictation.isBusy }
        expect(!runtime.isDictating && !service.isRecording && dictation.notice != nil, "Capture failure still releases the lock and temporary recording")
        service.failure = nil
        service.supported = false
        let captures = service.recordings
        dictation.activate(runtime: runtime)
        try await wait { !dictation.isBusy }
        expect(dictation.requiresSetup && service.recordings == captures, "Unsupported languages do not silently record in English")
        service.supported = true
        let background = ComposerDictation(service: service, defaults: defaults, isAppActive: { false })
        background.activate(runtime: runtime)
        try await wait { !background.isBusy }
        expect(service.recordings == captures && !runtime.isDictating, "A delayed activation cannot start capture in an inactive app")
        print("Dictation checks passed: \(checks)")
    }
}
