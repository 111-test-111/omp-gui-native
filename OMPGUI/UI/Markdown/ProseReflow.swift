import Foundation

/// Unwraps prose that the model hard-wrapped at a fixed column before the text
/// reaches the pasteboard. Anything that could be code is left untouched.
enum ProseReflow {
    static func reflowed(_ text: String) -> String {
        let protected = MarkdownMath.protect(text)
        return protected.restored(reflowMarkup(protected.text))
    }

    private static func reflowMarkup(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var paragraph: [String] = []
        var fenceOpen = false
        var fenceLanguage = ""

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let trimmed = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }
            let canReflow = trimmed.count >= 2
                && fenceLanguage.isEmpty
                && zip(paragraph, trimmed).allSatisfy { raw, trimmedLine in
                    !trimmedLine.isEmpty && raw.first?.isWhitespace != true
                }
                && trimmed.allSatisfy { line in
                    guard let first = line.first else { return false }
                    if "#>-*+|".contains(first) { return false }
                    if let d = first.wholeNumberValue, d >= 0, line.count > 1,
                       line[line.index(after: line.startIndex)] == "." || line[line.index(after: line.startIndex)] == ")" {
                        return false
                    }
                    return true
                }
                && trimmed.dropLast().allSatisfy { $0.count >= 45 }
                && trimmed.dropLast().allSatisfy { line in
                    if let last1 = line.last {
                        if "{};:=([\\|".contains(last1) { return false }
                        if line.hasSuffix("->") || line.hasSuffix("=>") { return false }
                    }
                    return true
                }
                && trimmed.allSatisfy { !$0.contains("  ") && !$0.contains("\t") }
                && trimmed.joined(separator: " ").range(of: #"[.!?] "#, options: .regularExpression) != nil
            if canReflow {
                output.append(trimmed.joined(separator: " "))
            } else {
                output.append(contentsOf: paragraph)
            }
            paragraph = []
        }

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                flushParagraph()
                output.append(line)
                if fenceOpen {
                    fenceOpen = false
                    fenceLanguage = ""
                } else {
                    fenceOpen = true
                    fenceLanguage = String(trimmedLine.dropFirst(3)).lowercased()
                }
            } else if trimmedLine.isEmpty {
                flushParagraph()
                output.append(line)
            } else if fenceOpen {
                flushParagraph()
                output.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return output.joined(separator: "\n")
    }
}
