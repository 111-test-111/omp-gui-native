import Foundation

/// A capture run: the app launched with `--website-captures <folder>` or
/// `--tour-captures <folder>` to render stills of itself. The run keeps to its
/// own storage folder and defaults suite under that folder and never reads the Keychain,
/// so the store, the settings and the provider adapters ask here before touching the
/// real ones. `WebsiteCaptures` and `TourCaptures` in the app layer drive the run.
enum CaptureRun {
    /// The folder the captures are written to, from the launch arguments; nil in a normal launch.
    nonisolated static let outputDirectory: URL? = {
        #if DEBUG
        let arguments = CommandLine.arguments
        for flag in ["--website-captures", "--tour-captures"] {
            if let index = arguments.firstIndex(of: flag),
               arguments.indices.contains(index + 1) {
                return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            }
        }
        #endif
        return nil
    }()

    // The legacy website flag is a compatibility alias for the tour run.
    nonisolated static var isTourRun: Bool { isEnabled }

    nonisolated static var isEnabled: Bool { outputDirectory != nil }

    /// The library and thread files the run reads, under the output folder.
    nonisolated static var storageRoot: URL? {
        outputDirectory?.appendingPathComponent("storage", isDirectory: true)
    }

    /// The defaults the run reads and writes instead of the app's own.
    nonisolated static var defaults: UserDefaults? {
        isEnabled ? UserDefaults(suiteName: suiteName) : nil
    }

    /// The defaults suite the run owns; a run starts by wiping it.
    nonisolated static let suiteName = "dev.tivano.Tivano.tour-captures"
}
