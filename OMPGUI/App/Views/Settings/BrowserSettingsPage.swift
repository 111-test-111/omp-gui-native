import SwiftUI

struct BrowserSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var showsNewProfile = false
    @State private var profileName = ""
    @State private var showsCookieImport = false
    @State private var importMessage: String?
    @State private var importFailed = false
    @State private var importPermissionDenied = false
    @State private var pendingProfileDeletion: BrowserProfileRecord?
    @State private var profileDeletionMessage: String?

    var body: some View {
        @Bindable var settings = model.settings
        ChromeSection(title: "Browser profiles") {
            ChromeCard {
                ChromeRow(title: "Browser profile", detail: "All conversations share this profile. Restart OMP GUI to apply changes.") {
                    Picker("Browser profile", selection: Binding(
                        get: { settings.browserProfiles.selectedID },
                        set: { settings.browserProfiles.select($0) }
                    )) {
                        ForEach(settings.browserProfiles.profiles) { profile in
                            Text(verbatim: profileTitle(profile)).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("Browser profile"))
                    .accessibilityIdentifier("browserProfile")
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                if settings.browserProfiles.selectedID != BrowserProfileConfiguration.activeProfile.id {
                    Text(verbatim: String(format: Chrome.localized("Current profile: %@. Restart OMP GUI to switch."),
                        profileTitle(BrowserProfileConfiguration.activeProfile)))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 11)
                }
                ChromeRowDivider()
                ChromeRow(title: "New blank profile", detail: "Starts with no cookies or signed-in accounts.") {
                    Button("Add profile…") { profileName = ""; showsNewProfile = true }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("addBrowserProfile")
                        .chromePopover(isPresented: $showsNewProfile, arrowEdge: .bottom) {
                            ChromeTextInputPopover(title: "New blank profile", prompt: "Profile name", submitTitle: "Create profile",
                                text: $profileName, onSubmit: {
                                    if settings.browserProfiles.add(named: profileName) != nil { showsNewProfile = false }
                                }, onCancel: { showsNewProfile = false },
                                validationMessage: settings.browserProfiles.containsName(profileName)
                                    ? "A browser profile with this name already exists." : nil)
                        }
                }
                ChromeRowDivider()
                ChromeRow(title: "Delete selected profile", detail: "Cookies and site data are deleted after restart. The default profile is kept.") {
                    Button("Delete profile…", role: .destructive) { pendingProfileDeletion = settings.browserProfiles.selected }
                        .buttonStyle(.glass)
                        .disabled(settings.browserProfiles.selected.isDefault || BrowserCookieImporter.shared.isImporting)
                        .accessibilityIdentifier("deleteBrowserProfile")
                        .confirmationDialog(
                            pendingProfileDeletion.map { String(format: Chrome.localized("Delete browser profile “%@”?"), $0.name) }
                                ?? Chrome.localized("Delete browser profile?"),
                            isPresented: Binding(get: { pendingProfileDeletion != nil }, set: { if !$0 { pendingProfileDeletion = nil } }),
                            titleVisibility: .visible, presenting: pendingProfileDeletion
                        ) { profile in
                            Button("Delete profile", role: .destructive) {
                                if let removed = settings.deleteBrowserProfile(profile.id) {
                                    profileDeletionMessage = String(format: Chrome.localized("Removed %@. Restart OMP GUI to delete its cookies and site data."), removed.name)
                                }
                                pendingProfileDeletion = nil
                            }
                            Button("Cancel", role: .cancel) { pendingProfileDeletion = nil }
                        } message: { _ in
                            Text("The default profile will be selected. Cookies and site data in this OMP GUI profile will be deleted after restarting the app.")
                        }
                }
                if let message = profileDeletionMessage
                    ?? (settings.browserProfiles.pendingDeletionIDs.isEmpty ? nil : Chrome.localized("Some removed profile data remains. Restart OMP GUI to retry cleanup.")) {
                    Text(verbatim: message)
                        .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 11)
                        .accessibilityIdentifier("browserProfileDeletionStatus")
                }
            }
        }
        ChromeSection(title: "Import from Chrome") {
            ChromeCard {
                ChromeRow(title: "Chrome cookies", detail: "Import saved cookies to a new profile; restart to use it.") {
                    if BrowserCookieImporter.shared.isImporting {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { BrowserCookieImporter.shared.cancel() }.buttonStyle(.glass)
                    }
                    Button("Import from Chrome…") { showsCookieImport = true }
                        .buttonStyle(.glass)
                        .disabled(BrowserCookieImporter.shared.isImporting)
                        .accessibilityIdentifier("importChromeCookies")
                        .chromePopover(isPresented: $showsCookieImport, arrowEdge: .bottom) {
                            ChromeCookieImportPicker { source in
                                showsCookieImport = false
                                importFromChrome(source)
                            } onCancel: { showsCookieImport = false }
                        }
                }
                if let importMessage {
                    Text(verbatim: importMessage)
                        .font(.ui(.subheadline))
                        .foregroundStyle(importFailed ? Chrome.danger : Chrome.secondaryText)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 11)
                        .accessibilityIdentifier("chromeCookieImportStatus")
                    if importPermissionDenied {
                        Button("Open Privacy Settings", action: openChromeImportPrivacySettings)
                            .buttonStyle(.glass).padding(.horizontal, 16).padding(.bottom, 11)
                    }
                }
            }
        }
        ChromeSection(title: "Web links") {
            ChromeCard {
                ChromeRow(title: "Open web links", detail: "Applies to conversations, file previews, and other app content.") {
                    Picker("Open web links", selection: $settings.webLinkDestination) {
                        ForEach(WebLinkDestination.allCases) { destination in
                            Text(verbatim: Chrome.localized(destination.title)).tag(destination)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("Open web links"))
                    .accessibilityIdentifier("webLinkDestination")
                }
            }
        }
        ChromeSection(title: "Language") {
            ChromeCard {
                ChromeRow(title: "Browser interface language", detail: "Restart OMP GUI to apply. English and Simplified Chinese are included; no download is needed.") {
                    Picker("Browser interface language", selection: $settings.browserInterfaceLanguage) {
                        ForEach(BrowserInterfaceLanguage.allCases) { language in
                            Text(verbatim: Chrome.localized(language.title)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("Browser interface language"))
                    .accessibilityIdentifier("browserInterfaceLanguage")
                }
            }
        }
        ChromeSection(title: "Search") {
            ChromeCard {
                ChromeRow(title: "Search engine", detail: "Used for searches from new browser tabs.") {
                    Picker("Search engine", selection: $settings.browserSearchEngine) {
                        ForEach(BrowserSearchEngine.allCases) { engine in
                            Text(verbatim: Chrome.localized(engine.title)).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("Search engine"))
                    .accessibilityIdentifier("browserSearchEngine")
                }
            }
        }
    }

    private func profileTitle(_ profile: BrowserProfileRecord) -> String {
        profile.isDefault ? Chrome.localized("Default profile") : profile.name
    }

    private func importFromChrome(_ source: ChromeCookieProfile) {
        importMessage = nil
        importPermissionDenied = false
        Task { @MainActor in
            do {
                let result = try await model.settings.importBrowserCookies(from: source)
                importFailed = false
                importMessage = result.message
            } catch is CancellationError {
                importFailed = false
                importMessage = Chrome.localized("Cookie import canceled. No profile was added.")
            } catch { showImportError(error) }
        }
    }

    private func showImportError(_ error: Error) {
        importFailed = true
        let failure = (error as? BrowserCookieImportError) ?? .unavailable
        importMessage = failure.localizedDescription
        if case .permissionDenied = failure { importPermissionDenied = true }
    }

}

private struct ChromeCookieImportPicker: View {
    let onImport: (ChromeCookieProfile) -> Void
    let onCancel: () -> Void
    @State private var profiles: [ChromeCookieProfile] = []
    @State private var selectedID: String?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var permissionDenied = false

    var body: some View {
        ChromeCookieImportForm(
            introduction: Chrome.localized(ChromeCookieImportForm.introductionKey),
            storageNotice: Chrome.localized(ChromeCookieImportForm.storageNoticeKey),
            profiles: profiles, selectedID: $selectedID, loading: loading, errorMessage: errorMessage,
            permissionDenied: permissionDenied,
            availableWidth: max(240, ((NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1_200) - 64),
            onImport: onImport, onCancel: onCancel
        ).task {
            let task = Task.detached(priority: .userInitiated) { try ChromeCookieSource.profiles() }
            do {
                let discovered = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                profiles = discovered; selectedID = discovered.first?.id
            } catch is CancellationError { return }
            catch {
                let failure = (error as? BrowserCookieImportError) ?? .unavailable
                errorMessage = failure.localizedDescription
                if case .permissionDenied = failure { permissionDenied = true }
            }
            loading = false
        }
    }
}

/// Keep presentation independent of discovery so layout never needs to access
/// Chrome or Keychain. Text may wrap on small screens, but must never truncate.
struct ChromeCookieImportForm: View {
    static let introductionKey = "Select a Chrome profile. macOS may ask for permission to read Chrome data and its Keychain item."
    static let storageNoticeKey = "Only saved cookies are imported. Passwords and other site storage are excluded. Some sites may still ask you to sign in."
    let introduction: String
    let storageNotice: String
    let profiles: [ChromeCookieProfile]
    @Binding var selectedID: String?
    let loading: Bool
    let errorMessage: String?
    let permissionDenied: Bool
    let availableWidth: CGFloat
    let onImport: (ChromeCookieProfile) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Chrome cookies").font(.ui(.body, weight: .semibold))
            Text(verbatim: introduction)
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if loading { ProgressView().controlSize(.small) }
            if !profiles.isEmpty {
                Picker("Chrome profile", selection: $selectedID) {
                    ForEach(profiles) { profile in
                        Text(verbatim: profile.name + " · " + profile.directoryName).lineLimit(1).tag(Optional(profile.id))
                    }
                }.accessibilityIdentifier("chromeImportProfile")
            }
            if let errorMessage {
                Text(verbatim: errorMessage).foregroundStyle(Chrome.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if permissionDenied {
                    Button("Open Privacy Settings", action: openChromeImportPrivacySettings).buttonStyle(.glass)
                }
            }
            Text(verbatim: storageNotice)
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.glass)
                Button("Import to new profile") {
                    if let source = profiles.first(where: { $0.id == selectedID }) { onImport(source) }
                }.buttonStyle(.glassProminent).disabled(loading || selectedID == nil)
                    .accessibilityIdentifier("confirmChromeCookieImport")
            }
        }.font(.ui(.body)).lineLimit(nil).padding(16)
            .frame(width: preferredWidth).fixedSize(horizontal: false, vertical: true).presentedChrome()
    }

    private var preferredWidth: CGFloat {
        let body = NSFont.systemFont(ofSize: TypeScale.shared.ui(TypeScale.stockPointSize(.body)))
        let detail = NSFont.systemFont(ofSize: TypeScale.shared.ui(TypeScale.stockPointSize(.subheadline)))
        let widths = [(introduction, body), (storageNotice, detail)].map { text, font in
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        // Long errors use two lines rather than stretching the entire popover.
        let errorWidth = ((errorMessage ?? "") as NSString).size(withAttributes: [.font: body]).width / 2
        return min(max(240, availableWidth), min(640, max(440, ceil(max(widths.max() ?? 0, errorWidth) + 40))))
    }
}

@MainActor private func openChromeImportPrivacySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
}
