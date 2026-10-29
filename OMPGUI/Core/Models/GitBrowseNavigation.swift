import Foundation
import Observation

/// Only lightweight navigation survives an unmounted Git page. Processes,
/// watches, commit bodies and diff buffers belong to the visible page's store.
@MainActor @Observable
final class GitBrowseNavigation {
    var mode = GitBrowseMode.changes
    var group = GitChangeGroup.all
    var historyReference: String?
    var routes: [GitBrowseRoute] = []
    var selectedParent: String?
    var query = ""
    var historyAnchor: String?
    var graphOffset: CGFloat = 0
    var showsSearch = false
    var historyCount = 100
    var repositoryKey: String?
    // Drafts and operation outcomes survive tab switches. A submitted Git write
    // finishes independently of view lifetime; hiding never means rollback.
    var commitMessage = ""
    var commitReview: GitCommitReview?
    var isWriting = false
    var writeError: String?
    var writeNotice: String?
    var needsCommitInspection = false
    var lastCommit: GitCommitReceipt?
}
