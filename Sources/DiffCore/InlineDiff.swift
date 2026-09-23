import Foundation

/// Word alignment followed by grapheme-level refinement inside changed words.
/// Ranges refer to Character offsets in the original, unexpanded source text.
enum InlineDiff {
    struct Highlights {
        var old: [Range<Int>] = []
        var new: [Range<Int>] = []
    }

    private struct Unit {
        let value: Character
        var source: Range<Int>
    }

    private struct Token {
        let value: String
        let units: Range<Int>
    }

    static func compare(_ old: String, _ new: String, ignoringWhitespace: Bool,
                        remainingWork: inout Int) -> Highlights {
        // Long lines retain their whole-line shading. Also cap total work across
        // the document so thousands of modified lines cannot multiply the budget.
        let byteCount = old.utf8.count + new.utf8.count
        guard byteCount <= 16_384, remainingWork >= byteCount, !Task.isCancelled else { return Highlights() }
        remainingWork -= byteCount
        let lhs = units(old, ignoringWhitespace: ignoringWhitespace)
        let rhs = units(new, ignoringWhitespace: ignoringWhitespace)
        let oldTokens = tokens(lhs)
        let newTokens = tokens(rhs)
        var lineWork = min(65_536, remainingWork)
        let initialWork = lineWork
        defer { remainingWork -= initialWork - lineWork }

        // Prefer retaining a word over aligning a few repeated spaces around it.
        let wordWeights = oldTokens.map { token in
            token.value.allSatisfy(\.isWhitespace) ? 1 : max(2, token.value.count)
        }
        let wordMatches = matches(oldTokens.map(\.value), newTokens.map(\.value), weights: wordWeights, work: &lineWork)
        var result = Highlights()
        var oldStart = 0
        var newStart = 0
        for (oldIndex, newIndex) in wordMatches + [(oldTokens.count, newTokens.count)] {
            if Task.isCancelled { return Highlights() }
            let oldEnd = oldIndex < oldTokens.count ? oldTokens[oldIndex].units.lowerBound : lhs.count
            let newEnd = newIndex < newTokens.count ? newTokens[newIndex].units.lowerBound : rhs.count
            let oldBlock = Array(lhs[oldStart..<oldEnd])
            let newBlock = Array(rhs[newStart..<newEnd])
            let characterMatches = matches(oldBlock.map(\.value), newBlock.map(\.value), work: &lineWork)
            var oldCursor = 0
            var newCursor = 0
            for (i, j) in characterMatches + [(oldBlock.count, newBlock.count)] {
                append(oldBlock, from: oldCursor, to: i, into: &result.old)
                append(newBlock, from: newCursor, to: j, into: &result.new)
                oldCursor = i + 1
                newCursor = j + 1
            }
            oldStart = oldIndex < oldTokens.count ? oldTokens[oldIndex].units.upperBound : lhs.count
            newStart = newIndex < newTokens.count ? newTokens[newIndex].units.upperBound : rhs.count
        }
        return result
    }

    private static func units(_ text: String, ignoringWhitespace: Bool) -> [Unit] {
        var result: [Unit] = []
        for (offset, character) in text.enumerated() {
            if ignoringWhitespace && character.isWhitespace {
                // Trim leading whitespace and collapse interior runs, preserving
                // the original ranges so tabs and Unicode remain correctly mapped.
                guard !result.isEmpty else { continue }
                if result.last?.value == " " {
                    result[result.count - 1].source = result[result.count - 1].source.lowerBound..<(offset + 1)
                } else {
                    result.append(Unit(value: " ", source: offset..<(offset + 1)))
                }
            } else {
                result.append(Unit(value: character, source: offset..<(offset + 1)))
            }
        }
        if ignoringWhitespace && result.last?.value == " " { result.removeLast() }
        return result
    }

    private static func tokens(_ units: [Unit]) -> [Token] {
        func category(_ character: Character) -> Int {
            if character.isWhitespace { return 0 }
            if character.isLetter || character.isNumber || character == "_" { return 1 }
            return 2
        }
        var result: [Token] = []
        var start = 0
        while start < units.count {
            let kind = category(units[start].value)
            var end = start + 1
            if kind != 2 {
                while end < units.count && category(units[end].value) == kind { end += 1 }
            }
            result.append(Token(value: String(units[start..<end].map(\.value)), units: start..<end))
            start = end
        }
        return result
    }

    private static func append(_ units: [Unit], from start: Int, to end: Int, into ranges: inout [Range<Int>]) {
        guard start < end else { return }
        let range = units[start].source.lowerBound..<units[end - 1].source.upperBound
        if let last = ranges.last, last.upperBound == range.lowerBound {
            ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
        } else {
            ranges.append(range)
        }
    }

    /// Bounded LCS for small spans. When the budget is exhausted, matching prefix
    /// and suffix remain useful and the middle is conservatively highlighted.
    private static func matches<T: Equatable>(_ lhs: [T], _ rhs: [T], weights: [Int]? = nil,
                                               work: inout Int) -> [(Int, Int)] {
        var prefix = 0
        while prefix < min(lhs.count, rhs.count), lhs[prefix] == rhs[prefix] { prefix += 1 }
        var oldEnd = lhs.count
        var newEnd = rhs.count
        while oldEnd > prefix, newEnd > prefix, lhs[oldEnd - 1] == rhs[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        var result = (0..<prefix).map { ($0, $0) }
        let n = oldEnd - prefix
        let m = newEnd - prefix
        let cells = (n + 1) * (m + 1)
        if n > 0, m > 0, cells <= work {
            work -= cells
            let stride = m + 1
            var lengths = Array(repeating: 0, count: cells)
            for i in (0..<n).reversed() {
                if Task.isCancelled { return [] }
                for j in (0..<m).reversed() {
                    lengths[i * stride + j] = lhs[prefix + i] == rhs[prefix + j]
                        ? (weights?[prefix + i] ?? 1) + lengths[(i + 1) * stride + j + 1]
                        : max(lengths[(i + 1) * stride + j], lengths[i * stride + j + 1])
                }
            }
            var i = 0
            var j = 0
            while i < n, j < m {
                if lhs[prefix + i] == rhs[prefix + j] {
                    result.append((prefix + i, prefix + j))
                    i += 1
                    j += 1
                } else if lengths[(i + 1) * stride + j] >= lengths[i * stride + j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        result.append(contentsOf: (0..<(lhs.count - oldEnd)).map { (oldEnd + $0, newEnd + $0) })
        return result
    }
}
