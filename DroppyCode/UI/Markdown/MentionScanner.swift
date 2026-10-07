import Foundation

/// The word-bounded mention scan shared by every prose path.
enum MentionScanner {
    /// Longest name first, so 'Hank 2' beats 'Hank'; a name inside a longer word or beside
    /// a digit doesn't count.
    nonisolated static func matches<Value>(in text: String, candidates: [Value], name: (Value) -> String) -> [(range: Range<String.Index>, value: Value)] {
        let ordered = candidates.sorted { name($0).count > name($1).count }
        var out: [(range: Range<String.Index>, value: Value)] = []
        var i = text.startIndex
        while i < text.endIndex {
            var hit: Value?
            for candidate in ordered {
                let candidateName = name(candidate)
                guard text[i...].hasPrefix(candidateName) else { continue }
                let after = text.index(i, offsetBy: candidateName.count, limitedBy: text.endIndex) ?? text.endIndex
                let beforeOK: Bool
                if i == text.startIndex { beforeOK = true } else { let c = text[text.index(before: i)]; beforeOK = !c.isLetter && !c.isNumber }
                let afterOK: Bool
                if after == text.endIndex { afterOK = true } else { let c = text[after]; afterOK = !c.isLetter && !c.isNumber }
                if beforeOK && afterOK { hit = candidate; break }
            }
            if let hit {
                let end = text.index(i, offsetBy: name(hit).count)
                out.append((i..<end, hit))
                i = end
            } else {
                i = text.index(after: i)
            }
        }
        return out
    }
}
