#if os(macOS)
import SwiftUI

enum DiffTextFormatting {
    static func attributed(_ text: String, highlights: [Range<Int>], color: Color) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        var offset = 0
        // Advance through the source once. Expand tabs only after slicing, since
        // highlight offsets refer to original graphemes rather than display columns.
        for range in highlights {
            let start = text.index(cursor, offsetBy: range.lowerBound - offset)
            let end = text.index(start, offsetBy: range.count)
            result += AttributedString(text[cursor..<start].replacingOccurrences(of: "\t", with: "    "))
            var changed = AttributedString(text[start..<end].replacingOccurrences(of: "\t", with: "    "))
            changed.backgroundColor = color.opacity(0.28)
            result += changed
            cursor = end
            offset = range.upperBound
        }
        result += AttributedString(text[cursor...].replacingOccurrences(of: "\t", with: "    "))
        return result
    }
}
#endif
