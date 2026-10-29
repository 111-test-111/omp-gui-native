import AppKit
import SwiftUI

/// Browser login has no modal. Only native challenges and recovery actions stay here.
struct OMPLoginControls: View {
    let provider: OMPLoginProvider
    let flow: OMPNativeLogin
    let useTerminal: () -> Void
    let cancel: () -> Void
    @State private var answer = ""
    @State private var showingSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ChromeRow(title: provider.name, detail: flow.isRunning ? "Complete sign-in in your browser." : nil) {
                if flow.isRunning { ProgressView().controlSize(.small) }
                if flow.error != nil {
                    Button("Continue in OMP terminal") { useTerminal() }.buttonStyle(.glass)
                }
                Button(Chrome.localized(flow.isRunning ? "Cancel" : "Dismiss"), action: cancel).buttonStyle(.glass)
            }
            if flow.isRunning, flow.browserOpenFailed, let link = flow.links.last {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The login page could not be opened.").font(.ui(.subheadline)).foregroundStyle(Chrome.danger)
                    HStack {
                        Button("Open login page") { flow.openLoginPage() }.buttonStyle(.glass)
                        Button("Copy login URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.destination.absoluteString, forType: .string)
                        }.buttonStyle(.glass)
                    }
                }.padding(.horizontal, Chrome.rowHorizontalPadding)
            }
            if flow.isRunning, flow.input != nil || flow.links.last?.instructions?.isEmpty == false {
                DisclosureGroup("Additional sign-in steps", isExpanded: $showingSteps) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let instructions = flow.links.last?.instructions, !instructions.isEmpty {
                            Text(verbatim: instructions).font(.ui(.subheadline)).textSelection(.enabled)
                        }
                        if let request = flow.input, let question = request.questions.first {
                            Text(verbatim: question.prompt).font(.ui(.subheadline)).textSelection(.enabled)
                            HStack {
                                TextField("", text: $answer)
                                    .textFieldStyle(.chromeGlass)
                                    .accessibilityLabel(Text(verbatim: question.prompt))
                                    .onSubmit(submit)
                                Button("Send", action: submit).buttonStyle(.glass).disabled(answer.isEmpty)
                            }
                        }
                    }.padding(.top, 8)
                }
                .padding(.horizontal, Chrome.rowHorizontalPadding)
                .padding(.bottom, 12)
            }
            if let error = flow.error {
                Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger).textSelection(.enabled)
                    .padding(.horizontal, Chrome.rowHorizontalPadding)
                    .padding(.bottom, 12)
            }
        }
        .onChange(of: flow.input?.id, initial: true) { _, id in
            answer = ""
            if id != nil { showingSteps = true }
        }
    }

    private func submit() {
        guard !answer.isEmpty else { return }
        flow.answer(answer)
        answer = ""
    }
}
