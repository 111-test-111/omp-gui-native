import AppKit
import SwiftUI

struct ComposerDictationButton: View {
    let runtime: ThreadRuntime
    @Bindable var dictation: ComposerDictation

    var body: some View {
        Button { dictation.activate(runtime: runtime) } label: {
            Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic")
                .font(Chrome.iconFont)
        }
        .buttonStyle(.chip(active: dictation.isRecording))
        .focusable(false)
        .disabled((dictation.isBusy && !dictation.isRecording) || runtime.isReverting || runtime.isLoadingHistory)
        .help(Text(verbatim: Chrome.localized(dictation.isRecording ? "Stop recording and transcribe" : "Dictate into this draft")))
        .accessibilityLabel(Text(verbatim: Chrome.localized(dictation.isRecording ? "Stop recording and transcribe" : "Dictate into this draft")))
    }
}

struct ComposerDictationStatus: View {
    @Bindable var dictation: ComposerDictation

    var body: some View {
        if dictation.showsComposerStatus {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    if dictation.isBusy && !dictation.isRecording { ProgressView().controlSize(.small) }
                    Text(verbatim: status).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    Spacer(minLength: 4)
                    if dictation.requiresSetup {
                        Button("Open dictation settings") { WindowManager.shared.showSettings(page: .dictation) }
                            .buttonStyle(.glass)
                    }
                    if dictation.isRecording {
                        Button("Stop recording") { dictation.finishRecording() }.buttonStyle(.glass)
                    }
                    Button {
                        if dictation.isBusy { dictation.cancel() } else { dictation.dismissNotice() }
                    } label: {
                        Text(verbatim: Chrome.localized(dictation.isBusy ? "Cancel" : "Dismiss"))
                    }
                    .buttonStyle(.glass).disabled(dictation.phase == .cancelling)
                }
                if let transcript = dictation.recoveredTranscript {
                    ScrollView {
                        Text(verbatim: transcript).font(.ui(.callout)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    Button("Copy transcript") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    }.buttonStyle(.glass)
                }
            }
        }
    }

    private var status: String {
        switch dictation.phase {
        case .idle: dictation.notice ?? ""
        case .checking: ""
        case .downloading: Chrome.localized("Installing dictation language assets…")
        case .requestingPermission: Chrome.localized("Waiting for microphone permission…")
        case .recording: String(format: Chrome.localized("Recording · %ld:%02ld · up to 5 minutes"), dictation.elapsed / 60, dictation.elapsed % 60)
        case .transcribing: Chrome.localized("Transcribing on this Mac…")
        case .cancelling: Chrome.localized("Cancelling dictation…")
        }
    }
}
