import Foundation

/// Display fields from OMP's public formatApprovalPrompt. Recognition requires
/// the native select method and known approval choices at the dialog boundary.
/// Only leading metadata is split; tool content remains verbatim.
struct OMPToolApproval: Equatable, Sendable {
    let name: String
    let origin: String?
    let reason: String?
    let details: String
    let onceChoice: String

    init?(prompt: String, choices: [String] = ["Approve", "Deny"]) {
        guard let onceChoice = Self.singleCallChoice(choices) else { return nil }
        var remainder = prompt[...]
        let first = Self.takeLine(&remainder)
        guard first.hasPrefix("Allow tool: ") else { return nil }
        let name = String(first.dropFirst("Allow tool: ".count))
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.name = name
        self.onceChoice = onceChoice
        var origin: String?, reason: String?
        if remainder.hasPrefix("Origin: ") { origin = String(Self.takeLine(&remainder).dropFirst("Origin: ".count)) }
        if remainder.hasPrefix("Reason: ") { reason = String(Self.takeLine(&remainder).dropFirst("Reason: ".count)) }
        self.origin = origin
        self.reason = reason
        details = String(remainder)
    }

    /// OMP may offer broader grants before the single-call choice. Keep their
    /// native labels distinct: in cached mode even "Approve" can mean a grant.
    private static func singleCallChoice(_ choices: [String]) -> String? {
        guard (2...7).contains(choices.count), Set(choices).count == choices.count,
              choices.last == "Deny" else { return nil }
        let cached = choices.contains("Approve Once")
        let once = cached ? "Approve Once" : "Approve"
        guard choices.contains(once), choices.allSatisfy({ choice in
            if choice == once || choice == "Deny" { return true }
            if choice.hasPrefix("Approve "), choice.hasSuffix(" for this session"),
               choice.count > "Approve  for this session".count { return true }
            guard cached else { return false }
            if ["Approve", "Always Approve", "Approve File", "Always Approve File"].contains(choice) { return true }
            return ["Approve Directory: ", "Always Approve Directory: "].contains {
                choice.hasPrefix($0) && choice.count > $0.count
            }
        }) else { return nil }
        return once
    }

    var command: String? {
        guard name == "bash", details.hasPrefix("Command: ") else { return nil }
        return String(details.dropFirst("Command: ".count))
    }

    var file: (path: String, content: String)? {
        guard name == "write", details.hasPrefix("Path: ") else { return nil }
        var remainder = details[...]
        let path = String(Self.takeLine(&remainder).dropFirst("Path: ".count))
        guard remainder.hasPrefix("Content:\n") || remainder.hasPrefix("Content:\r\n") else { return nil }
        _ = Self.takeLine(&remainder)
        return (path, String(remainder))
    }

    private static func takeLine(_ text: inout Substring) -> Substring {
        let end = text.firstIndex(where: { $0.isNewline }) ?? text.endIndex
        let line = text[..<end]
        text = end == text.endIndex ? text[end...] : text[text.index(after: end)...]
        return line.last == "\r" ? line.dropLast() : line
    }
}
