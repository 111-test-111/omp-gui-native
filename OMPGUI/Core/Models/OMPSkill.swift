import Foundation

struct OMPGlobalSkill: Identifiable, Hashable, Sendable {
    var name: String
    var description: String
    var filePath: String
    var source: String

    var id: String { filePath }
    var url: URL { URL(fileURLWithPath: filePath) }
}
