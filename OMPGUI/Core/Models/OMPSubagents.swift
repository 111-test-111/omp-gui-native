import Foundation

/// Negotiated per process, rather than inferred from a version or protocol number.
struct OMPSubagentCapabilities: Equatable, Sendable {
    var canCancel = false
    var canSteer = false

    /// An empty probe cannot address a worker. Only the native argument-validation
    /// response proves that this particular command exists and is available.
    static func recognizesControl(_ response: JSONValue) -> Bool {
        response["success"]?.bool == false
            && response["error"]?.string == "`subagentId` must be a non-empty string."
    }

    static func confirmedCancellation(_ response: JSONValue) -> Bool {
        response["cancelled"]?.bool == true
    }
}

/// Observations only: completion never implies that isolated changes were applied.
struct OMPAgentResult: Codable, Hashable, Sendable {
    var agentSource: String?
    var parentSessionFile: String?
    var sessionFile: String?
    var parentToolCallID: String?
    var model: String?
    var effort: String?
    var workingDirectory: String?
    var isolated: Bool?
    var changesApplied: Bool?
    var files: [String] = []
    var outputPath: String?
    var patchPath: String?
    var branchName: String?
    var nestedPatchPaths: [String] = []
    var error: String?
    /// OMP's tool/delivery report, including integration details absent from its
    /// structured result in older releases. Display it without interpreting prose.
    var nativeReport: String?

    init() {}

    init(native value: JSONValue) {
        model = value["resolvedModelIdentity"]?.string
        effort = value["resolvedThinkingLevel"]?.string
        workingDirectory = value["workingDirectory"]?.string ?? value["cwd"]?.string
        isolated = value["isolated"]?.bool
        changesApplied = value["changesApplied"]?.bool
        files = value["files"]?.array?.compactMap { $0.string ?? $0["path"]?.string } ?? []
        outputPath = value["outputPath"]?.string
        patchPath = value["patchPath"]?.string
        branchName = value["branchName"]?.string
        nestedPatchPaths = value["nestedPatchPaths"]?.array?.compactMap(\.string) ?? []
        error = value["error"]?.string ?? value["abortReason"]?.string
    }

    mutating func merge(_ other: Self) {
        agentSource = other.agentSource ?? agentSource
        parentSessionFile = other.parentSessionFile ?? parentSessionFile
        sessionFile = other.sessionFile ?? sessionFile
        parentToolCallID = other.parentToolCallID ?? parentToolCallID
        model = other.model ?? model
        effort = other.effort ?? effort
        workingDirectory = other.workingDirectory ?? workingDirectory
        isolated = other.isolated ?? isolated
        changesApplied = other.changesApplied ?? changesApplied
        files = Array(Set(files + other.files)).sorted()
        outputPath = other.outputPath ?? outputPath
        patchPath = other.patchPath ?? patchPath
        branchName = other.branchName ?? branchName
        nestedPatchPaths = Array(Set(nestedPatchPaths + other.nestedPatchPaths)).sorted()
        error = other.error ?? error
        nativeReport = other.nativeReport ?? nativeReport
    }
}
