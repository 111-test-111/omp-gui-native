// On-device dictation adapted from Droppy Code by Jordy Spruit (Droppy),
// https://getdroppycode.app, e7dd8dcb (2026-10-09). Modified for OMP GUI.
import AVFoundation
import Foundation
import Speech

struct DictationLanguage: Sendable, Equatable {
    let identifier: String
    let installed: Bool
}

enum DictationMicrophonePermission: Equatable, Sendable { case allowed, undetermined, denied }

/// The capture boundary is replaceable so lifecycle checks never open a microphone,
/// request permission, install system assets or invoke speech recognition.
@MainActor
protocol DictationService: AnyObject {
    func supportedLanguages() async -> [String]
    func language(_ identifier: String) async throws -> DictationLanguage
    func install(_ identifier: String, progress: @escaping @Sendable (Double) -> Void) async throws
    var microphonePermission: DictationMicrophonePermission { get }
    func requestMicrophonePermission() async -> Bool
    var isRecording: Bool { get }
    func startRecording() throws
    func stopRecording() throws -> URL
    func cancelCapture()
    func transcribe(_ url: URL, language: String) async throws -> String
    func cleanUp() async
}

@MainActor
final class LocalDictationService: DictationService {
    private let engine = LocalDictationEngine()
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    func supportedLanguages() async -> [String] { await engine.supportedLanguages() }
    func language(_ identifier: String) async throws -> DictationLanguage { try await engine.language(identifier) }
    func install(_ identifier: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await engine.install(identifier, progress: progress)
    }

    var microphonePermission: DictationMicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    func requestMicrophonePermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }
    var isRecording: Bool { recorder?.isRecording == true }

    func startRecording() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omp-gui-dictation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("recording.wav")
        recordingURL = url
        do {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            guard recorder.prepareToRecord(), recorder.record(forDuration: 300) else { throw DictationError.recordingFailed }
            self.recorder = recorder
        } catch {
            removeRecording()
            throw DictationError.recordingFailed
        }
    }

    func stopRecording() throws -> URL {
        recorder?.stop()
        recorder = nil
        guard let recordingURL else { throw DictationError.recordingFailed }
        let file = try AVAudioFile(forReading: recordingURL)
        guard file.processingFormat.sampleRate > 0,
              Double(file.length) / file.processingFormat.sampleRate > 0.3 else { throw DictationError.noSpeech }
        return recordingURL
    }

    func transcribe(_ url: URL, language: String) async throws -> String {
        try await engine.transcribe(url, identifier: language)
    }

    func cancelCapture() {
        recorder?.stop()
        recorder = nil
        removeRecording()
    }

    func cleanUp() async {
        cancelCapture()
        await engine.release()
    }

    private func removeRecording() {
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL.deletingLastPathComponent()) }
        recordingURL = nil
    }
}

private actor LocalDictationEngine {
    private var analyzer: SpeechAnalyzer?

    func supportedLanguages() async -> [String] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
    }

    private func transcriber(_ identifier: String) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw DictationError.unsupportedLanguage
        }
        try Task.checkCancellation()
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    func language(_ identifier: String) async throws -> DictationLanguage {
        let module = try await transcriber(identifier)
        return await DictationLanguage(identifier: module.selectedLocales.first?.identifier ?? identifier,
                                       installed: AssetInventory.status(forModules: [module]) == .installed)
    }

    func install(_ identifier: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let module = try await transcriber(identifier)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let download = request.progress
            let observation = download.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
                progress(value.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await request.downloadAndInstall()
            } onCancel: { download.cancel() }
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw DictationError.assetsMissing }
        progress(1)
    }

    func transcribe(_ url: URL, identifier: String) async throws -> String {
        let module = try await transcriber(identifier)
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw DictationError.assetsMissing }
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        defer { self.analyzer = nil }
        return try await withTaskCancellationHandler {
            let results = Task {
                var text = ""
                for try await result in module.results {
                    try Task.checkCancellation()
                    if result.isFinal { text += String(result.text.characters) }
                    guard text.utf8.count <= 128 * 1_024 else { throw DictationError.transcriptTooLong }
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            do {
                let file = try AVAudioFile(forReading: url)
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
                let text = try await results.value
                try Task.checkCancellation()
                return text
            } catch {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                _ = try? await results.value
                throw error
            }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }

    func release() async { if let analyzer { await analyzer.cancelAndFinishNow() } }
}

enum DictationError: Error {
    case unsupportedLanguage, assetsMissing, microphoneDenied, recordingFailed, noSpeech, transcriptTooLong
}
