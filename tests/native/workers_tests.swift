import Foundation
@testable import OMPGUI

@main
struct NativeWorkerOverlayExport {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(output.path.contains("/build.noindex/verification/runs/"))
        // Export the actual production overlay, rather than copying its JSON in JS.
        try OMPSession.delegationConfiguration(nil).data().write(to: output.appendingPathComponent("worker-overlay.json"))
    }
}
