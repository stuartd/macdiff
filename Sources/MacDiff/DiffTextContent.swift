#if os(macOS)
import AppKit
import DiffCore

/// The selectable display has one paragraph per diff row. Synthetic paragraphs
/// align insertions/deletions; the mapping keeps them out of copied source text.
struct DiffTextContent {
    struct Segment {
        let display: NSRange
        let source: NSRange
    }

    let text: String
    let source: NSString
    let rowRanges: [NSRange]
    let segments: [Segment]

    init(rows: [DiffRow], source: String, onLeft: Bool) {
        self.source = source as NSString
        let lines = Self.sourceLines(source)
        var text = ""
        var ranges: [NSRange] = []
        var segments: [Segment] = []
        var offset = 0
        for row in rows {
            let value = (onLeft ? row.oldText : row.newText) ?? ""
            let length = value.utf16.count
            if let number = onLeft ? row.oldNumber : row.newNumber, lines.indices.contains(number - 1) {
                let line = lines[number - 1]
                if length > 0 {
                    segments.append(Segment(display: NSRange(location: offset, length: length),
                                            source: NSRange(location: line.location, length: length)))
                }
                if line.length > length {
                    segments.append(Segment(display: NSRange(location: offset + length, length: 1),
                                            source: NSRange(location: line.location + length, length: line.length - length)))
                }
            }
            text += value + "\n"
            ranges.append(NSRange(location: offset, length: length + 1))
            offset += length + 1
        }
        self.text = text
        self.rowRanges = ranges
        self.segments = segments
    }

    func copiedText(in selection: NSRange) -> String {
        var result = ""
        for segment in segments {
            let overlap = NSIntersectionRange(selection, segment.display)
            guard overlap.length > 0 else { continue }
            // One display newline can represent an original CRLF pair.
            let range = segment.display.length == segment.source.length
                ? NSRange(location: segment.source.location + overlap.location - segment.display.location,
                          length: overlap.length)
                : segment.source
            result += source.substring(with: range)
        }
        return result
    }

    private static func sourceLines(_ text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let units = Array(text.utf16)
        var lines: [NSRange] = []
        var start = 0
        var index = 0
        while index < units.count {
            let unit = units[index]
            index += 1
            if unit == 13 || unit == 10 {
                if unit == 13, index < units.count, units[index] == 10 { index += 1 }
                lines.append(NSRange(location: start, length: index - start))
                start = index
            }
        }
        lines.append(NSRange(location: start, length: units.count - start))
        return lines
    }
}
#endif
