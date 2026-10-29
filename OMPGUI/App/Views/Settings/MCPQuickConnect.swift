import AppKit
import SwiftUI

struct MCPQuickConnectCatalog: View {
    let query: String
    let configured: Set<String>
    let canEdit: Bool
    var dismissDisabled = false
    let select: (MCPCatalogEntry) -> Void
    let presented: (String) -> Binding<Bool>
    let editor: (MCPCatalogEntry) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            Text("Add a server to the active OMP profile. OMP manages connections and sign-in; new conversations use the saved configuration.")
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            ForEach(MCPCatalog.byCategory, id: \.category) { section in
                let entries = section.entries.filter { !configured.contains($0.id) && OMPMCPQuickConnect.matches($0, query: query) }
                if !entries.isEmpty {
                    ChromeSection(title: section.category.title) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 10)], spacing: 10) {
                            ForEach(entries) { entry in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 10) {
                                        MCPGlyph(entry: entry, size: 24).accessibilityHidden(true)
                                        Text(verbatim: entry.name).font(.ui(.body, weight: .semibold))
                                        Spacer(minLength: 0)
                                        Button(entry.isOAuth ? "Sign in" : "Connect") { select(entry) }
                                            .buttonStyle(.glass).controlSize(.small).disabled(!canEdit)
                                            // Anchor to the window, so dismissing the form cannot scroll the grid to restore focus.
                                            .badgePopover(isPresented: presented(entry.id), dismissDisabled: dismissDisabled, usesViewAnchor: true) { editor(entry) }
                                    }
                                    Text(verbatim: Chrome.localized(entry.summary)).font(.ui(.subheadline))
                                        .foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true)
                                    Text(verbatim: entry.sampleTools.prefix(3).joined(separator: " · "))
                                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText.opacity(0.8))
                                        .lineLimit(2)
                                }
                                .padding(14).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                                .background(Chrome.overlay(0.035), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MCPQuickConnectEditor: View {
    let entry: MCPCatalogEntry
    let submit: (JSONValue) async -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePopover) private var closePopover
    @State private var values: [String: String]
    @State private var busy = false
    @State private var error: String?

    init(entry: MCPCatalogEntry, submit: @escaping (JSONValue) async -> String?) {
        self.entry = entry
        self.submit = submit
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: entry.fields.map { ($0.key, $0.defaultValue ?? "") }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                MCPGlyph(entry: entry, size: 28).accessibilityHidden(true)
                Text(verbatim: entry.name).font(.ui(.headline))
                Spacer()
                if let url = URL(string: entry.docsURL) { Link("Documentation", destination: url).font(.ui(.subheadline)) }
            }
            Text(verbatim: Chrome.localized(entry.summary)).font(.ui(.body)).foregroundStyle(Chrome.secondaryText)
            MCPQuickConnectTools(entry: entry, width: 560)
            if !entry.fields.isEmpty {
                ChromeCard {
                    ForEach(Array(entry.fields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { ChromeRowDivider() }
                        ChromeRow(title: field.label, detail: field.help) {
                            let value = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })
                            Group {
                                if field.kind == .secret { SecureField("", text: value) }
                                else { TextField("", text: value) }
                            }
                            .textFieldStyle(.chromeGlass).frame(width: 280).privacySensitive()
                            .accessibilityLabel(Text(verbatim: Chrome.localized(field.label)))
                        }
                    }
                }
                if let raw = entry.keysURL, let url = URL(string: raw) { Link("Get a key or token", destination: url) }
            }
            Text(verbatim: Chrome.localized(entry.isOAuth
                ? "OMP will open your browser to sign in and keep credentials in its native credential store."
                : "Values are saved in OMP's native MCP configuration. Environment references are kept literally; local packages run only when OMP starts a conversation."))
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true)
            if let error { MCPInlineError(text: error, width: 560) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: close).buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button(entry.isOAuth ? "Add and sign in" : "Add server") {
                    Task {
                        do {
                            let definition = try OMPMCPQuickConnect.definition(for: entry, values: values)
                            busy = true
                            error = await submit(definition)
                            busy = false
                            if error == nil { close() }
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.glass).keyboardShortcut(.defaultAction)
            }.disabled(busy)
        }
        .padding(20).frame(width: 600).disabled(busy).interactiveDismissDisabled(busy)
    }

    private func close() {
        if let closePopover { closePopover() } else { dismiss() }
    }
}

/// Uses the card's tool-name styling without its preview count or line limit.
struct MCPQuickConnectTools: View {
    let entry: MCPCatalogEntry
    let width: CGFloat

    var body: some View {
        if !entry.sampleTools.isEmpty {
            PopoverScroll(maxHeight: 120, minHeight: 0, width: width) {
                Text(verbatim: entry.sampleTools.joined(separator: " · "))
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct OMPMCPLoginPopover: View {
    let session: MCPLoginSession
    let context: () -> OMPDiscoveryContext?
    let save: (JSONValue) async -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePopover) private var closePopover
    @State private var login = OMPMCPLogin()
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: String(format: Chrome.localized("Sign in to %@ with OMP"), session.server.id)).font(.ui(.headline))
            Text("OMP manages authorization and credentials. Sign-in does not verify the server's tools or connection.")
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            if let entry = MCPCatalog.entry(matching: session.server.id) {
                MCPQuickConnectTools(entry: entry, width: 440)
            }
            if login.isRunning { ProgressView().controlSize(.small) }
            if let link = login.link {
                Text(verbatim: link.absoluteString).font(.ui(.caption)).textSelection(.enabled).privacySensitive()
                    .lineLimit(4).truncationMode(.middle)
                Button("Open browser") { login.openBrowser() }.buttonStyle(.glass)
            }
            if login.browserOpenFailed { Text("The browser could not be opened. Open the link above manually.").font(.ui(.subheadline)).foregroundStyle(Chrome.warning) }
            if let prompt = login.prompt {
                Text(verbatim: Chrome.localized(prompt)).font(.ui(.subheadline))
                HStack {
                    SecureField("", text: $answer).textFieldStyle(.chromeGlass).accessibilityLabel(Text("Authorization response"))
                        .onSubmit { login.answer(answer); answer = "" }
                    Button("Continue") { login.answer(answer); answer = "" }.buttonStyle(.glass)
                }
            }
            if let error = login.error { MCPInlineError(text: Chrome.localized(error), width: 440) }
            if login.completed { Text("Signed in with OMP. New conversations will use this authorization.").font(.ui(.body)) }
            HStack { Spacer(); Button(login.isRunning ? "Cancel" : "Done") {
                login.stop()
                if let closePopover { closePopover() } else { dismiss() }
            }.buttonStyle(.glass).keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 480)
        .task(id: session.id) { await login.start(server: session.server, snapshot: session.snapshot, currentContext: context, save: save) }
        .onDisappear { login.stop() }
    }
}

struct MCPLoginSession: Identifiable {
    let id = UUID()
    let snapshot: OMPMCPSnapshot
    let server: OMPMCPServer
}

private struct MCPInlineError: View {
    let text: String
    let width: CGFloat
    var body: some View {
        PopoverScroll(maxHeight: 180, width: width) {
            Text(verbatim: text).font(.ui(.subheadline)).foregroundStyle(Chrome.danger)
                .textSelection(.enabled).privacySensitive().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
