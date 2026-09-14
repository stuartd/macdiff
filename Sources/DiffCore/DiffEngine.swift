import Foundation

public enum DiffKind: Sendable, Equatable {
    case unchanged
    case removed
    case added
    case modified
}

public struct DiffRow: Identifiable, Sendable, Equatable {
    public let id: Int
    public let oldNumber: Int?
    public let oldText: String?
    public let newNumber: Int?
    public let newText: String?
    public let kind: DiffKind

    public init(id: Int, oldNumber: Int?, oldText: String?, newNumber: Int?, newText: String?, kind: DiffKind) {
        self.id = id
        self.oldNumber = oldNumber
        self.oldText = oldText
        self.newNumber = newNumber
        self.newText = newText
        self.kind = kind
    }
}

public enum DiffEngine {
    private enum Edit {
        case same(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    private enum Pending {
        case compare(Range<Int>, Range<Int>)
        case same(Int, Int, Int)
    }

    /// Compares lines, treating LF, CRLF, and CR as equivalent separators. A final
    /// separator produces an empty last line, so changes to the final newline are visible.
    /// Whitespace comparison trims edges and collapses runs; returned text is unaltered.
    ///
    /// Alignment uses linear memory and a bounded search. Very different, large regions
    /// may be shown as a replacement block instead of a minimal edit script. A cancelled
    /// task returns no rows; callers must discard results from cancelled comparisons.
    public static func compare(_ old: String, _ new: String, ignoringWhitespace: Bool = false) -> [DiffRow] {
        guard !Task.isCancelled,
              let oldLines = lines(in: old), let newLines = lines(in: new) else { return [] }

        // Intern the comparison text once: repeated lines and long lines then cost the
        // same amount to compare during alignment. Keep the original strings for display.
        var symbols: [String: Int] = [:]
        func tokens(for lines: [String]) -> [Int]? {
            var result: [Int] = []
            result.reserveCapacity(lines.count)
            for (index, line) in lines.enumerated() {
                if index.isMultiple(of: 1024), Task.isCancelled { return nil }
                let key = ignoringWhitespace
                    ? line.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
                    : line
                if let symbol = symbols[key] {
                    result.append(symbol)
                } else {
                    let symbol = symbols.count
                    symbols[key] = symbol
                    result.append(symbol)
                }
            }
            return result
        }
        guard let lhs = tokens(for: oldLines), let rhs = tokens(for: newLines),
              let edits = editScript(lhs, rhs) else { return [] }

        var rows: [DiffRow] = []
        rows.reserveCapacity(max(oldLines.count, newLines.count))
        var index = 0
        while index < edits.count {
            if Task.isCancelled { return [] }
            switch edits[index] {
            case let .same(i, j):
                rows.append(DiffRow(id: rows.count, oldNumber: i + 1, oldText: oldLines[i], newNumber: j + 1, newText: newLines[j], kind: .unchanged))
                index += 1
            case .delete, .insert:
                var deletes: [Int] = []
                var inserts: [Int] = []
                changeBlock: while index < edits.count {
                    if index.isMultiple(of: 1024), Task.isCancelled { return [] }
                    switch edits[index] {
                    case let .delete(i): deletes.append(i)
                    case let .insert(j): inserts.append(j)
                    case .same: break changeBlock
                    }
                    index += 1
                }
                for offset in 0..<max(deletes.count, inserts.count) {
                    if offset.isMultiple(of: 1024), Task.isCancelled { return [] }
                    let left = offset < deletes.count ? deletes[offset] : nil
                    let right = offset < inserts.count ? inserts[offset] : nil
                    let kind: DiffKind = left != nil && right != nil ? .modified : (left != nil ? .removed : .added)
                    rows.append(DiffRow(
                        id: rows.count,
                        oldNumber: left.map { $0 + 1 }, oldText: left.map { oldLines[$0] },
                        newNumber: right.map { $0 + 1 }, newText: right.map { newLines[$0] }, kind: kind
                    ))
                }
            }
        }
        return Task.isCancelled ? [] : rows
    }

    private static func lines(in text: String) -> [String]? {
        guard !text.isEmpty else { return [] }
        // CRLF is one extended grapheme cluster in Swift, so splitting on the Character
        // "\n" alone does not split Windows text. Walk scalars to recognize all three forms.
        let scalars = text.unicodeScalars
        var result: [String] = []
        var start = scalars.startIndex
        var index = start
        var visited = 0
        while index < scalars.endIndex {
            if visited.isMultiple(of: 1024), Task.isCancelled { return nil }
            visited += 1
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            if scalar == "\r" || scalar == "\n" {
                result.append(String(text[start..<index]))
                index = scalar == "\r" && next < scalars.endIndex && scalars[next] == "\n"
                    ? scalars.index(after: next) : next
                start = index
            } else {
                index = next
            }
        }
        result.append(String(text[start..<scalars.endIndex]))
        return result
    }

    private static func editScript(_ lhs: [Int], _ rhs: [Int]) -> [Edit]? {
        var edits: [Edit] = []
        edits.reserveCapacity(lhs.count + rhs.count)
        // Myers' bidirectional search needs O(N + M) memory. A shared work budget
        // also bounds its quadratic worst case for heavily changed/repetitive inputs.
        var remainingWork = 8_000_000
        var pending: [Pending] = [.compare(lhs.indices, rhs.indices)]
        while let next = pending.popLast() {
            if Task.isCancelled { return nil }
            switch next {
            case let .same(oldStart, newStart, count):
                for offset in 0..<count {
                    if offset.isMultiple(of: 1024), Task.isCancelled { return nil }
                    edits.append(.same(oldStart + offset, newStart + offset))
                }
            case let .compare(oldRange, newRange):
                var oldStart = oldRange.lowerBound
                var newStart = newRange.lowerBound
                var oldEnd = oldRange.upperBound
                var newEnd = newRange.upperBound
                while oldStart < oldEnd, newStart < newEnd, lhs[oldStart] == rhs[newStart] {
                    if oldStart.isMultiple(of: 1024), Task.isCancelled { return nil }
                    edits.append(.same(oldStart, newStart))
                    oldStart += 1
                    newStart += 1
                }
                var suffix = 0
                while oldStart < oldEnd, newStart < newEnd, lhs[oldEnd - 1] == rhs[newEnd - 1] {
                    if suffix.isMultiple(of: 1024), Task.isCancelled { return nil }
                    oldEnd -= 1
                    newEnd -= 1
                    suffix += 1
                }
                if suffix > 0 { pending.append(.same(oldEnd, newEnd, suffix)) }
                let oldMiddle = oldStart..<oldEnd
                let newMiddle = newStart..<newEnd

                // Avoid spending the search budget on large blocks with no common lines.
                // This is especially useful when comparing unrelated clipboard contents.
                var hasCommonLine = true
                if oldMiddle.count > 512, newMiddle.count > 512,
                   remainingWork >= oldMiddle.count + newMiddle.count {
                    var oldSymbols: Set<Int> = []
                    for index in oldMiddle {
                        if index.isMultiple(of: 1024), Task.isCancelled { return nil }
                        remainingWork -= 1
                        oldSymbols.insert(lhs[index])
                    }
                    hasCommonLine = false
                    for index in newMiddle {
                        if index.isMultiple(of: 1024), Task.isCancelled { return nil }
                        remainingWork -= 1
                        if oldSymbols.contains(rhs[index]) {
                            hasCommonLine = true
                            break
                        }
                    }
                }

                if !oldMiddle.isEmpty, !newMiddle.isEmpty, hasCommonLine,
                   let (oldSplit, newSplit) = bisect(lhs, rhs, oldMiddle, newMiddle, remainingWork: &remainingWork),
                   (oldSplit != oldStart || newSplit != newStart),
                   (oldSplit != oldEnd || newSplit != newEnd) {
                    // An explicit stack avoids recursion overflow on adversarial text.
                    pending.append(.compare(oldSplit..<oldEnd, newSplit..<newEnd))
                    pending.append(.compare(oldStart..<oldSplit, newStart..<newSplit))
                } else {
                    for index in oldMiddle {
                        if index.isMultiple(of: 1024), Task.isCancelled { return nil }
                        edits.append(.delete(index))
                    }
                    for index in newMiddle {
                        if index.isMultiple(of: 1024), Task.isCancelled { return nil }
                        edits.append(.insert(index))
                    }
                }
            }
        }
        return edits
    }

    /// Finds where the shortest edit paths from either end meet. Only the current
    /// forward and reverse frontiers are stored, rather than the complete LCS table.
    private static func bisect(
        _ lhs: [Int], _ rhs: [Int], _ old: Range<Int>, _ new: Range<Int>, remainingWork: inout Int
    ) -> (Int, Int)? {
        guard remainingWork > 0, !Task.isCancelled else { return nil }
        let n = old.count
        let m = new.count
        let maxDistance = (n + m + 1) / 2
        let offset = maxDistance + 1
        let length = 2 * maxDistance + 3
        var forward = Array(repeating: -1, count: length)
        var reverse = Array(repeating: -1, count: length)
        forward[offset + 1] = 0
        reverse[offset + 1] = 0
        let delta = n - m
        let oddDelta = !delta.isMultiple(of: 2)
        var forwardStart = 0
        var forwardEnd = 0
        var reverseStart = 0
        var reverseEnd = 0

        for distance in 0..<maxDistance {
            if Task.isCancelled { return nil }
            for diagonal in stride(from: -distance + forwardStart, through: distance - forwardEnd, by: 2) {
                remainingWork -= 1
                guard remainingWork > 0 else { return nil }
                let slot = offset + diagonal
                var x: Int
                if diagonal == -distance || (diagonal != distance && forward[slot - 1] < forward[slot + 1]) {
                    x = forward[slot + 1]
                } else {
                    x = forward[slot - 1] + 1
                }
                var y = x - diagonal
                while x < n, y < m, lhs[old.lowerBound + x] == rhs[new.lowerBound + y] {
                    remainingWork -= 1
                    guard remainingWork > 0 else { return nil }
                    if remainingWork.isMultiple(of: 1024), Task.isCancelled { return nil }
                    x += 1
                    y += 1
                }
                forward[slot] = x
                if x > n {
                    forwardEnd += 2
                } else if y > m {
                    forwardStart += 2
                } else if oddDelta {
                    let reverseSlot = offset + delta - diagonal
                    if reverseSlot >= 0, reverseSlot < length, reverse[reverseSlot] >= 0,
                       x >= n - reverse[reverseSlot] {
                        return (old.lowerBound + x, new.lowerBound + y)
                    }
                }
            }
            for diagonal in stride(from: -distance + reverseStart, through: distance - reverseEnd, by: 2) {
                remainingWork -= 1
                guard remainingWork > 0 else { return nil }
                let slot = offset + diagonal
                var x: Int
                if diagonal == -distance || (diagonal != distance && reverse[slot - 1] < reverse[slot + 1]) {
                    x = reverse[slot + 1]
                } else {
                    x = reverse[slot - 1] + 1
                }
                var y = x - diagonal
                while x < n, y < m, lhs[old.upperBound - x - 1] == rhs[new.upperBound - y - 1] {
                    remainingWork -= 1
                    guard remainingWork > 0 else { return nil }
                    if remainingWork.isMultiple(of: 1024), Task.isCancelled { return nil }
                    x += 1
                    y += 1
                }
                reverse[slot] = x
                if x > n {
                    reverseEnd += 2
                } else if y > m {
                    reverseStart += 2
                } else if !oddDelta {
                    let forwardSlot = offset + delta - diagonal
                    if forwardSlot >= 0, forwardSlot < length, forward[forwardSlot] >= 0 {
                        let forwardX = forward[forwardSlot]
                        let forwardY = forwardX - (delta - diagonal)
                        if forwardX >= n - x {
                            return (old.lowerBound + forwardX, new.lowerBound + forwardY)
                        }
                    }
                }
            }
        }
        return nil
    }
}
