#if os(macOS)
import AppKit

enum DiffTextFormatting {
    static func highlight(_ text: String, ranges: [Range<Int>], color: NSColor,
                          in result: NSMutableAttributedString, offset: Int = 0) {
        var cursor = text.startIndex
        var characterOffset = 0
        // Advance once through graphemes, converting to TextKit's UTF-16 ranges.
        // Tabs remain source characters and are laid out by the text container.
        for range in ranges {
            let start = text.index(cursor, offsetBy: range.lowerBound - characterOffset)
            let end = text.index(start, offsetBy: range.count)
            var utf16Range = NSRange(start..<end, in: text)
            utf16Range.location += offset
            result.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.28), range: utf16Range)
            cursor = end
            characterOffset = range.upperBound
        }
    }
}
#endif
