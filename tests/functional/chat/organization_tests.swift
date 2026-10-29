import AppKit
import Foundation
@testable import OMPGUI

@main
struct OrganizationChecks {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }

    @MainActor static func main() async throws {
        guard CaptureRun.storageRoot != nil, let defaults = CaptureRun.defaults else { fatalError("Isolated capture storage required") }
        defaults.removePersistentDomain(forName: CaptureRun.suiteName)
        defer { defaults.removePersistentDomain(forName: CaptureRun.suiteName) }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: Storage.root, withIntermediateDirectories: true)
        try JSONEncoder.storage.encode(Library()).write(to: Storage.libraryURL)
        do {
            let unloaded = AppModel()
            let task = unloaded.newThread(affiliation: .standalone)!
            let runtime = unloaded.runtime(for: task.id)
            await runtime.ensureLoaded()
            runtime.draft = ComposerDraft(text: "First unsaved input")
            runtime.send()
            runtime.draft = ComposerDraft(text: "Second unsaved input")
            runtime.send()
            for _ in 0..<300 {
                if runtime.followUps.count == 2 && runtime.followUps.allSatisfy({ $0.ompState == .failed }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            expect(runtime.followUps.count == 2 && runtime.followUps.allSatisfy { $0.ompState == .failed && $0.deliveryError != nil },
                   "An unavailable library rejects the first input and releases later admission waiters")
            expect(runtime.draft.text == "Second unsaved input" && runtime.followUps.first?.text == "First unsaved input",
                   "Failed persistence preserves both drafts for editing or retry")
            expect(runtime.turns.isEmpty && unloaded.thread(task.id)?.hasStartedTurn == false,
                   "Failed persistence cannot start a native turn or lock the task's affiliation")
        }
        defaults.set(Data(#"{"modelID":"native/fixed","effort":"high"}"#.utf8), forKey: "newThreadModelSelection")
        let app = AppModel()
        expect(defaults.object(forKey: "newThreadModelSelection") == nil,
               "Loading preferences retires a saved fixed-model override")
        await app.bootstrap()
        let first = app.newThread(affiliation: .standalone)!
        let second = app.newThread(affiliation: .standalone)!
        expect(first.projectID == nil && app.projects.isEmpty, "A task does not create a synthetic saved project")
        let firstDirectory = app.executionProject(for: first)!.path
        expect(firstDirectory != app.executionProject(for: second)!.path, "Each task has a different persistent workspace")
        expect(firstDirectory == StoragePaths.taskWorkspace(first.id).path, "Workspace identity is derived from the persisted task UUID")
        expect(!FileManager.default.fileExists(atPath: firstDirectory), "Queries do not create workspaces")
        expect(app.standaloneTasks.count == 2 && app.sidebarThreads.count == 2, "Tasks participate in sidebar and keyboard navigation")
        expect(app.moveInActivity(first.id, to: second.id, placeAfter: false, among: app.standaloneTasks.map(\.id)), "Tasks can be reordered within their activity group")
        expect(app.sidebarThreads.first?.id == first.id, "Task reorder changes the visible and keyboard order")
        let project = app.addProject(at: Storage.root.appendingPathComponent("project-a"))
        let other = app.addProject(at: Storage.root.appendingPathComponent("project-b"))
        expect(app.moveProject(other.id, to: project.id, placeAfter: false), "Project folders can be reordered")
        expect(app.projects.first?.id == other.id, "Project order is reflected by the model")
        expect(app.moveThread(first.id, to: .project(project.id)), "An unsent task can choose a project")
        expect(app.moveThread(first.id, to: .standalone), "An unsent project chat can become a task")
        app.settings.newThreadLocation = .standalone
        app.updateThread(second.id) { $0.model = "native/recent"; $0.effort = "low" }
        app.selectedThreadID = second.id
        let recentTask = app.newThread()!
        expect(recentTask.projectID == nil && recentTask.model == "native/recent" && recentTask.effort == "low",
               "A new task always inherits the current model and effort after retiring a saved fixed override")
        let explicit = app.newThread(in: project, workspace: .local)!
        expect(explicit.projectID == project.id, "Explicit project creation takes priority over the location default")
        let reread = AppSettings()
        expect(reread.newThreadLocation == .standalone, "The new-chat location default survives preferences reload")
        app.settings.newThreadLocation = .recent
        app.selectedThreadID = explicit.id
        let following = app.newThread(workspace: .local)!
        expect(following.projectID == project.id && following.model == explicit.model && following.effort == explicit.effort,
               "Recent mode inherits the current project, model and reasoning effort")
        expect(app.beginThreadTurn(first.id), "The first-send boundary can be persisted")
        expect(!app.moveThread(first.id, to: .project(other.id)), "A started task cannot silently change its working directory")
        let decoded = try JSONDecoder.storage.decode(Library.self, from: Data(contentsOf: Storage.libraryURL))
        expect(decoded.threads.first { $0.id == first.id }?.hasStartedTurn == true, "The first-send boundary survives restart")
        var missing = explicit
        missing.projectID = UUID()
        expect(app.executionProject(for: missing) == nil, "A missing project never becomes an independent task")
        let roundTrip = try JSONDecoder.storage.decode(ChatThread.self, from: JSONEncoder.storage.encode(second))
        expect(roundTrip.affiliation == .standalone && roundTrip.id == second.id, "Standalone affiliation survives storage round trip")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = Date(timeIntervalSince1970: 1_792_688_400)
        let midnight = calendar.startOfDay(for: now)
        var today = second; today.updatedAt = midnight
        var yesterday = explicit; yesterday.updatedAt = midnight.addingTimeInterval(-1)
        var helper = recentTask; helper.parentThreadID = today.id; helper.updatedAt = now
        expect(ThreadOrganization.activityThreads([yesterday, helper, today]).map(\.id) == [yesterday.id, today.id],
               "Activity retains older conversations and nests helpers under visible parents")
        expect(ThreadOrganization.activityThreads([yesterday, helper]).map(\.id) == [yesterday.id, helper.id],
               "An ordinary helper with no visible parent retains its standalone activity row")
        var pinned = recentTask; pinned.isPinned = true; pinned.updatedAt = now
        var waiting = following; waiting.projectID = nil; waiting.updatedAt = now.addingTimeInterval(-10)
        var settled = first; settled.isSettled = true; settled.settledAt = now
        yesterday.projectID = nil
        let sections = ThreadOrganization.taskSections([yesterday, settled, today, pinned, waiting], attention: [waiting.id], calendar: calendar)
        expect(sections.flatMap(\.threads).map(\.id) == [waiting.id, pinned.id, today.id, yesterday.id, settled.id],
               "Tasks prioritize waiting and pinned inputs, then recent activity and settled chats")
        let pagedProject = app.addProject(at: Storage.root.appendingPathComponent("paged-project"))
        for _ in 0..<11 { app.newThread(in: pagedProject, workspace: .local) }
        for _ in 0..<6 { app.newThread(in: other, workspace: .local) }
        func page() -> AppModel.ProjectThreadPage { app.projectThreadPage(in: pagedProject) }
        let initialPage = page().threads.map(\.id)
        expect(initialPage.count == 5 && page().hasMore && page().totalCount == 11,
               "A project starts with five root conversations and offers another page")
        let parent = initialPage[0]
        let child = app.newThread(in: pagedProject, workspace: .local)!
        app.updateThread(child.id) { $0.parentThreadID = parent }
        expect(page().threads.map(\.id) == initialPage && page().totalCount == 11,
               "A helper does not consume a root conversation's page slot or project count")
        expect(!app.sidebarThreads.contains { $0.id == child.id }, "A folded helper stays out of keyboard navigation without consuming a page slot")
        app.updateThread(parent) { $0.foldsHelpers = false }
        let visible = app.sidebarThreads.filter { $0.projectID == pagedProject.id }
        expect(visible.filter { !$0.isHelper }.map(\.id) == initialPage && visible.contains { $0.id == child.id },
               "Keyboard navigation follows the five visible roots and their expanded helpers")
        app.showMoreProjectThreads(pagedProject.id)
        expect(page().threads.count == 10 && page().hasMore, "Show more adds five root conversations")
        expect(app.projectThreadPage(in: other).threads.count == 5 && app.projectThreadPage(in: other).hasMore,
               "Paging one project leaves other project limits unchanged")
        app.showMoreProjectThreads(pagedProject.id)
        expect(page().threads.count == 11 && !page().hasMore, "The final page shows the remainder and removes Show more")
        app.showMoreProjectThreads(pagedProject.id)
        expect(page().threads.count == 11, "A stale Show more action cannot extend a finished list")
        app.updateProject(pagedProject.id) { $0.isExpanded = false }
        expect(!app.sidebarThreads.contains { $0.projectID == pagedProject.id }, "Folding a project removes all its navigation rows")
        app.showMoreProjectThreads(pagedProject.id)
        app.updateProject(pagedProject.id) { $0.isExpanded = true }
        expect(page().threads.count == 5 && page().hasMore, "Reopening a project resets every prior page to five")
        let settledIDs = app.threads(in: pagedProject).suffix(8).map(\.id)
        app.updateThread(settledIDs[0]) { $0.isSettled = true }
        expect(!page().showsSettledHeader && page().hasMore, "Later settled sections do not interrupt a page of open conversations")
        for id in settledIDs { app.updateThread(id) { $0.isSettled = true } }
        app.settings.settledCollapsed = true
        expect(page().threads.count == 3 && !page().hasMore && page().showsSettledHeader && page().settledCount == 8,
               "Folded settled chats leave no ineffective Show more button and retain their disclosure count")
        expect(!app.sidebarThreads.contains { settledIDs.contains($0.id) }, "Project keyboard navigation skips folded settled conversations")
        app.settings.settledCollapsed = false
        expect(page().threads.count == 5 && page().threads.count(where: \.isSettled) == 2 && page().hasMore,
               "Opening settled conversations shares the five-root limit with open conversations")
        app.updateThread(explicit.id) { $0.updatedAt = midnight.addingTimeInterval(-30 * 86_400) }
        app.settings.projectsCollapsed = true
        app.updateThread(first.id) { $0.isSettled = true }
        app.settings.settledCollapsed = true
        expect(!app.sidebarThreads.contains { $0.id == first.id }, "Keyboard navigation omits folded settled tasks")
        app.settings.settledCollapsed = false
        app.settings.sidebarActivityView = true
        expect(AppSettings().sidebarActivityView, "Activity view retains its persisted preference identity")
        expect(app.sidebarThreads.contains { $0.id == explicit.id }, "Activity includes month-old project conversations even when projects are folded")
        expect(app.sidebarThreads.filter { $0.projectID == pagedProject.id && !$0.isHelper }.count == 11,
               "Activity view includes all project roots independently of folder paging")
        expect(app.sidebarThreads.contains { $0.id == child.id }, "Activity retains helpers under their visible parent")
        app.settings.sidebarActivityView = false
        app.settings.tasksCollapsed = true
        expect(!app.sidebarThreads.contains { $0.projectID == nil }, "Task section collapse also updates keyboard navigation")
        app.settings.projectsCollapsed = true
        expect(app.sidebarThreads.isEmpty, "Both section states are honored")
        app.settings.projectsCollapsed = false
        app.settings.tasksCollapsed = false
        expect(AppSettings().sidebarSectionOrder == .projectsFirst, "Projects lead the sidebar sections by default")
        app.settings.sidebarSectionOrder = .tasksFirst
        expect(app.sidebarThreads.first?.projectID == nil, "Keyboard navigation follows Tasks when they lead the sidebar")
        expect(AppSettings().sidebarSectionOrder == .tasksFirst, "The chosen sidebar section order persists")
        app.settings.sidebarSectionOrder = .projectsFirst
        expect(app.sidebarThreads.first?.projectID != nil, "Keyboard navigation returns to Projects first")
        app.archive(second.id)
        app.archive(recentTask.id)
        app.updateThread(recentTask.id) { $0.title = "Different archived task" }
        var filter = ArchiveFilter()
        filter.query = "Different"
        let matches = filter.apply(to: app.archivedThreads, known: Set(app.projects.map(\.id)))
        expect(matches.map(\.id) == [recentTask.id], "Archive search filters before bulk deletion")
        filter.query = ""; filter.project = .none
        expect(filter.apply(to: app.archivedThreads, known: Set(app.projects.map(\.id))).count == 2, "Archive can isolate chats without a project")
        app.deleteArchivedThreads(ids: Set(matches.map(\.id)))
        expect(app.thread(recentTask.id) == nil && app.thread(second.id) != nil, "Filtered deletion preserves other archived records")
        app.selectedThreadID = nil
        app.settings.remember(model: "native/recent-at-launch", effort: "medium", for: .omp)
        let lastSettings = AppSettings()
        expect(lastSettings.lastModel(for: .omp) == "native/recent-at-launch" && lastSettings.lastEffort(for: .omp) == "medium",
               "Recent model and effort survive preferences reload")
        let withoutCurrent = app.newThread(workspace: .local)!
        expect(withoutCurrent.model == "native/recent-at-launch" && withoutCurrent.effort == "medium",
               "Without a selected chat, new chats use the last remembered model and effort")
        print("Organization checks passed: \(checks)")
    }
}
