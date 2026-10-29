import AppKit

enum MarkdownParagraphLayout {
    // Share the same small increase across SwiftUI text and native TextKit prose.
    static let lineSpacing: CGFloat = 3
    static let hardBreakSpacing: CGFloat = 2
    static let blockSpacing: CGFloat = 14
    static let listSpacing: CGFloat = 8
    static let containedBlockSpacing: CGFloat = 12
    static let listLineEndSpacing: CGFloat = 0
    static let listItemBoundary = NSAttributedString.Key("OMPGUIListItemBoundary")

    @MainActor static let layoutDelegate = LineSpacingDelegate()

    /// TextKit includes spacing after a paragraph's last line, while a standalone
    /// SwiftUI text host omits it. Treat explicit breaks separately so list rows
    /// and joined prose share the smaller gap without changing automatic wraps.
    @MainActor final class LineSpacingDelegate: NSObject, NSLayoutManagerDelegate {
        nonisolated func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat {
            guard let storage = layoutManager.textStorage else { return 0 }
            let character = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard character < storage.length else { return 0 }
            let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle ?? .default
            // AppKit reports the last visible glyph, omitting the break control.
            // Use its full character range so ligatures and Unicode stay intact.
            let characters = layoutManager.characterRange(forGlyphRange: NSRange(location: glyphIndex, length: 1), actualGlyphRange: nil)
            for index in [character, NSMaxRange(characters)] where index < storage.length {
                switch storage.mutableString.character(at: index) {
                case 0x0A, 0x0D, 0x2028, 0x2029:
                    let boundary = storage.attribute(listItemBoundary, at: max(character, NSMaxRange(characters) - 1), effectiveRange: nil) as? Bool == true
                    return min(style.lineSpacing, boundary ? listLineEndSpacing : hardBreakSpacing)
                default:
                    break
                }
            }
            // Standalone text has no following line. Preserve AppKit's omitted
            // terminal spacing instead of enlarging a SwiftUI list row's frame.
            if NSMaxRange(characters) >= storage.length { return 0 }
            return style.lineSpacing
        }

        nonisolated func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
            guard let textContainer else { return }
            InlineCodeStyle.restoreClampedOrigins(in: layoutManager, container: textContainer)
        }
    }

    static func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }

    /// Hard breaks stay inside the Markdown paragraph: no inter-block spacing or
    /// repeated first-line indent. Keep actual newlines for native selection/copy.
    static func apply(_ style: NSParagraphStyle, to text: NSMutableAttributedString) {
        let string = text.string as NSString
        var start = 0
        while start < string.length {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: string.length - start))
            let end = newline.location == NSNotFound ? string.length : NSMaxRange(newline)
            let paragraph = style.mutableCopy() as! NSMutableParagraphStyle
            if start > 0 {
                paragraph.firstLineHeadIndent = style.headIndent
                paragraph.paragraphSpacingBefore = 0
            }
            if newline.location != NSNotFound { paragraph.paragraphSpacing = 0 }
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: end - start))
            start = end
        }
    }
}
