import Foundation

extension AppModel {
    // OMP applies isolated task results itself. The GUI neither creates merge
    // commits nor pushes, opens PRs or races that native integration.
    var isAnyHydraMergeRunning: Bool { false }
    func resumeHydraMerges() async {}
    func autoMergeHydraWork(of leadID: UUID) async {}
}
