import AppKit
import SwiftUI

/// What a thread shows before its first message: a question about the project.
/// The project name opens a popover to move the empty thread to another project.
struct NewThreadPrompt: View {
    @Environment(AppModel.self) private var model
    let threadID: UUID
    let projectName: String?
    var fillsAvailableSpace = true

    @State private var isChoosingProject = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 26) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                question
            }
            question
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableSpace ? .infinity : nil)
    }

    private var question: some View {
        HStack(spacing: 0) {
            if let projectName, !projectName.isEmpty {
                let question = Chrome.localizedAround("What should we build in %@?")
                Text(verbatim: question.before)
                Button {
                    isChoosingProject.toggle()
                } label: {
                    Text(verbatim: projectName)
                        .foregroundStyle(Chrome.accent)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Choose another project")
                .chromePopover(isPresented: $isChoosingProject, arrowEdge: .bottom) {
                    projectChoices
                }
                Text(verbatim: question.after)
            } else {
                Button("What should we build?") { isChoosingProject.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Chrome.accent)
                    .help("Choose a project or task")
                    .chromePopover(isPresented: $isChoosingProject, arrowEdge: .bottom) { projectChoices }
            }
        }
        .font(AppFont.swiftUI(size: 28, weight: .regular))
        .foregroundStyle(Chrome.primaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var projectChoices: some View {
        let current = model.thread(threadID)?.projectID
        return PopoverMenu {
            PopoverItem("Independent task", symbol: "tray", isChecked: current == nil) {
                isChoosingProject = false
                withAnimation(Chrome.panelSlide) { _ = model.moveThread(threadID, to: .standalone) }
            }
            PopoverDivider()
            PopoverSectionHeader("Projects")
            ForEach(model.projects) { project in
                PopoverItem(project.name, leading: AnyView(ProjectIconMark(icon: project.icon, size: 12)), isChecked: project.id == current) {
                    move(to: project)
                }
            }
            PopoverDivider()
            PopoverItem("Add project…", symbol: "plus") {
                guard let added = model.addProjectsFromPanel() else { return }
                move(to: added)
            }
            PopoverItem("Clone from GitHub…", leading: AnyView(Image("mcp-github").resizable().scaledToFit().frame(width: 12, height: 12))) {
                isChoosingProject = false
                GitHubClonePanel.shared.present(model: model) { project in
                    move(to: project)
                }
            }
        }
    }

    private func move(to project: Project) {
        guard let thread = model.thread(threadID), thread.projectID != project.id else { return }
        isChoosingProject = false
        withAnimation(Chrome.panelSlide) {
            _ = model.moveThread(threadID, to: .project(project.id))
        }
    }
}
