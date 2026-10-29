import AppKit
import SwiftUI

struct DictationSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DictationSetupContent(dictation: model.dictationSettings)
    }
}

struct DictationSetupContent: View {
    @Bindable var dictation: ComposerDictation

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ChromeSection(title: "Local dictation") {
                ChromeCard {
                    ChromeRow(title: "Dictation language", detail: "Speech is transcribed on this Mac into the current draft.") {
                        Picker("Dictation language", selection: Binding(get: { dictation.selectedLanguage }, set: dictation.selectLanguage)) {
                            if !dictation.languages.contains(dictation.selectedLanguage) {
                                Text(verbatim: languageName(dictation.selectedLanguage)).tag(dictation.selectedLanguage)
                            }
                            ForEach(dictation.languages, id: \.self) { identifier in
                                Text(verbatim: languageName(identifier)).tag(identifier)
                            }
                        }
                        .labelsHidden().frame(width: 240, alignment: .trailing).disabled(dictation.isBusy)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Language assets", detail: dictation.installed ? "Language assets installed" : "Install Apple's on-device speech assets for the selected language.") {
                        if dictation.phase == .downloading {
                            ProgressView(value: dictation.progress).frame(width: 100)
                            Button("Cancel") { dictation.cancel() }.buttonStyle(.glass)
                        } else if dictation.installed {
                            Button("Reinstall language assets") { dictation.download() }.buttonStyle(.glass)
                                .disabled(dictation.isBusy || dictation.languages.isEmpty)
                        } else {
                            Button("Install language assets") { dictation.download() }.buttonStyle(.glass)
                                .disabled(dictation.isBusy || dictation.languages.isEmpty)
                        }
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Microphone", detail: permissionText) {
                        switch dictation.microphonePermission {
                        case .undetermined:
                            Button("Allow microphone access") { dictation.requestPermission() }.buttonStyle(.glass).disabled(dictation.isBusy)
                        case .denied:
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }.buttonStyle(.glass)
                        case .allowed:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Chrome.success)
                                .accessibilityLabel(Text("Microphone access is enabled."))
                        }
                    }
                }
                if dictation.hasCheckedLanguages && dictation.languages.isEmpty {
                    Text("On-device dictation is unavailable for this Mac or language. Choose a supported language.")
                        .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                }
                if let notice = dictation.notice {
                    Text(verbatim: notice).font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                }
            }
        }
        .task(id: dictation.selectedLanguage) { await dictation.refreshLanguages() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await dictation.refreshLanguages() }
        }
        .onDisappear { dictation.cancel() }
    }

    private var permissionText: String {
        switch dictation.microphonePermission {
        case .allowed: "Microphone access is enabled."
        case .undetermined: "Allow microphone access here before using dictation."
        case .denied: "Microphone access is off. Enable OMP GUI in System Settings → Privacy & Security → Microphone."
        }
    }

    private func languageName(_ identifier: String) -> String { Locale.current.localizedString(forIdentifier: identifier) ?? identifier }
}
