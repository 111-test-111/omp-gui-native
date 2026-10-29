// Dictation lifecycle adapted from Droppy Code by Jordy Spruit (Droppy),
// https://getdroppycode.app, e7dd8dcb (2026-10-09). Modified for OMP GUI.
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ComposerDictation {
    enum Phase { case idle, checking, downloading, requestingPermission, recording, transcribing, cancelling }
    private(set) var phase: Phase = .idle
    private(set) var languages: [String] = []
    private(set) var selectedLanguage: String
    private(set) var installed = false
    private(set) var hasCheckedLanguages = false
    private(set) var progress = 0.0
    private(set) var elapsed = 0
    private(set) var notice: String?
    private(set) var recoveredTranscript: String?
    private(set) var requiresSetup = false
    private(set) var microphonePermission: DictationMicrophonePermission = .undetermined

    @ObservationIgnored private let service: any DictationService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isAppActive: () -> Bool
    private static var owner: UUID?
    @ObservationIgnored private let id = UUID()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private weak var target: ThreadRuntime?
    @ObservationIgnored private var draftID: UUID?
    /// Asset status from completed checks, so revisiting a language never flashes a guessed hint.
    @ObservationIgnored private var verifiedAssets: [String: Bool] = [:]

    init(service: any DictationService = LocalDictationService(),
         defaults: UserDefaults = CaptureRun.defaults ?? .standard,
         isAppActive: @escaping () -> Bool = { NSApp?.isActive == true }) {
        self.service = service
        self.defaults = defaults
        self.isAppActive = isAppActive
        selectedLanguage = defaults.string(forKey: "dictationLanguage") ?? Locale.current.identifier
    }

    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }
    var showsComposerStatus: Bool { (isBusy && phase != .checking) || notice != nil }

    func refreshLanguages() async {
        if !isBusy {
            selectedLanguage = defaults.string(forKey: "dictationLanguage") ?? Locale.current.identifier
            microphonePermission = service.microphonePermission
        }
        let requested = selectedLanguage
        let values = await service.supportedLanguages()
        guard !Task.isCancelled else { return }
        languages = values
        hasCheckedLanguages = true
        guard !isBusy else { return }
        let language = try? await service.language(requested)
        guard !Task.isCancelled, !isBusy, selectedLanguage == requested else { return }
        if let language {
            selectedLanguage = language.identifier
            setInstalled(language.installed, for: language.identifier)
            verifiedAssets[requested] = language.installed
        } else {
            installed = false
            verifiedAssets.removeValue(forKey: requested)
        }
    }

    func selectLanguage(_ identifier: String) {
        guard !isBusy else { return }
        selectedLanguage = identifier
        defaults.set(identifier, forKey: "dictationLanguage")
        // Show only a verified status until the new language's check returns; clearing it here
        // flashed the install hint under an installed language on every switch.
        if let verified = verifiedAssets[identifier] { installed = verified }
        notice = nil
    }

    private func setInstalled(_ value: Bool, for identifier: String) {
        installed = value
        verifiedAssets[identifier] = value
    }

    func activate(runtime: ThreadRuntime) {
        if isRecording { finishRecording(); return }
        guard !runtime.isReverting, !runtime.isLoadingHistory, !isBusy else { return }
        selectedLanguage = defaults.string(forKey: "dictationLanguage") ?? Locale.current.identifier
        microphonePermission = service.microphonePermission
        guard microphonePermission == .allowed else {
            requiresSetup = true
            notice = Chrome.localized("Complete dictation setup in Settings → Dictation before recording.")
            return
        }
        guard claim() else { return }
        target = runtime
        draftID = runtime.draft.id
        runtime.isDictating = true
        notice = nil
        requiresSetup = false
        recoveredTranscript = nil
        // This preflight is silent: the microphone never presents setup or permission UI.
        phase = .checking
        let token = generation
        operation = Task {
            do {
                let language = try await service.language(selectedLanguage)
                try validate(token)
                selectedLanguage = language.identifier
                setInstalled(language.installed, for: language.identifier)
                guard installed else { throw DictationError.assetsMissing }
                guard isAppActive() else { await finish(); return }
                try service.startRecording()
                phase = .recording
                elapsed = 0
                operation = nil
                startTimer()
            } catch { await failed(error, token: token) }
        }
    }

    /// Permission requests are an explicit Settings action, never a microphone side effect.
    func requestPermission() {
        guard claim() else { return }
        phase = .requestingPermission
        notice = nil
        requiresSetup = false
        let token = generation
        operation = Task {
            do {
                guard isAppActive() else { await finish(); return }
                let granted = await service.requestMicrophonePermission()
                try validate(token)
                microphonePermission = service.microphonePermission
                guard granted else { throw DictationError.microphoneDenied }
                notice = Chrome.localized("Microphone access is enabled.")
                await finish()
            } catch { await failed(error, token: token) }
        }
    }

    func download() {
        guard claim() else { return }
        notice = nil
        requiresSetup = false
        phase = .downloading
        progress = 0
        let token = generation
        let language = selectedLanguage
        operation = Task { [self] in
            do {
                try await service.install(language) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.phase == .downloading else { return }
                        self.progress = min(1, max(0, value))
                    }
                }
                try validate(token)
                setInstalled(true, for: language)
                notice = Chrome.localized("Dictation is ready. Click the microphone to record.")
                await finish()
            } catch { await failed(error, token: token) }
        }
    }

    func finishRecording() {
        guard isRecording else { return }
        timer?.cancel()
        timer = nil
        phase = .transcribing
        let token = generation
        operation = Task {
            do {
                let url = try service.stopRecording()
                let text = try await service.transcribe(url, language: selectedLanguage)
                try validate(token)
                guard !text.isEmpty else { throw DictationError.noSpeech }
                guard text.utf8.count <= 128 * 1_024 else { throw DictationError.transcriptTooLong }
                if let target, target.draft.id == draftID {
                    let separator = target.draft.text.isEmpty || target.draft.text.last?.isWhitespace == true ? "" : " "
                    target.draft.text += separator + text
                } else {
                    recoveredTranscript = text
                    notice = Chrome.localized("The draft was replaced. Copy the transcript below to keep it.")
                }
                await finish()
            } catch { await failed(error, token: token) }
        }
    }

    func cancel() {
        guard isBusy, phase != .cancelling else { return }
        generation = UUID()
        phase = .cancelling
        timer?.cancel()
        timer = nil
        service.cancelCapture()
        if let operation { operation.cancel() }
        else { operation = Task { await finish() } }
    }

    func dismissNotice() { notice = nil; requiresSetup = false; recoveredTranscript = nil }

    private func claim() -> Bool {
        guard !isBusy, Self.owner == nil else {
            notice = Chrome.localized("Dictation is active in another editor. Stop or cancel it there first.")
            return false
        }
        Self.owner = id
        generation = UUID()
        return true
    }

    private func validate(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func failed(_ error: Error, token: UUID) async {
        if token == generation, !(error is CancellationError) {
            notice = Chrome.localized(Self.message(for: error))
            switch error {
            case DictationError.assetsMissing, DictationError.unsupportedLanguage, DictationError.microphoneDenied:
                installed = false
                verifiedAssets.removeValue(forKey: selectedLanguage)
                requiresSetup = true
                notice = Chrome.localized("Complete dictation setup in Settings → Dictation before recording.")
            default: break
            }
        }
        await finish()
    }

    private func finish() async {
        await service.cleanUp()
        target?.isDictating = false
        target = nil
        draftID = nil
        if Self.owner == id { Self.owner = nil }
        operation = nil
        phase = .idle
    }

    private func startTimer() {
        let started = Date()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, isRecording else { return }
                elapsed = Int(Date().timeIntervalSince(started))
                if elapsed >= 300 || !service.isRecording { finishRecording(); return }
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DictationError.unsupportedLanguage: "On-device dictation is unavailable for this Mac or language. Choose a supported language."
        case DictationError.assetsMissing: "Dictation language assets are missing. Install them before recording."
        case DictationError.microphoneDenied: "Microphone access is off. Enable OMP GUI in System Settings → Privacy & Security → Microphone."
        case DictationError.recordingFailed: "Recording failed. Check your microphone in System Settings → Sound and try again."
        case DictationError.noSpeech: "No speech was recognized. Try recording again."
        case DictationError.transcriptTooLong: "The transcript exceeds 128 KiB. Record a shorter message."
        default: "Local dictation failed. Your draft has been kept. Check language assets and try again."
        }
    }
}
