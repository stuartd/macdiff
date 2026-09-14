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

    public static func compare(_ old: String, _ new: String, ignoringWhitespace: Bool = false) -> [DiffRow] {
        let oldLines = lines(in: old)
        let newLines = lines(in: new)
        let lhs = oldLines.map { normalized($0, ignoringWhitespace: ignoringWhitespace) }
        let rhs = newLines.map { normalized($0, ignoringWhitespace: ignoringWhitespace) }
        let edits = editScript(lhs, rhs)

        var rows: [DiffRow] = []
        var id = 0
        var index = 0
        while index < edits.count {
            switch edits[index] {
            case let .same(i, j):
                rows.append(DiffRow(id: id, oldNumber: i + 1, oldText: oldLines[i], newNumber: j + 1, newText: newLines[j], kind: .unchanged))
                id += 1
                index += 1
            case .delete, .insert:
                var deletes: [Int] = []
                var inserts: [Int] = []
                while index < edits.count {
                    switch edits[index] {
                    case let .delete(i): deletes.append(i)
                    case let .insert(j): inserts.append(j)
                    case .same: break
                    }
                    if case .same = edits[index] { break }
                    index += 1
                }
                let count = max(deletes.count, inserts.count)
                for offset in 0..<count {
                    let left = offset < deletes.count ? deletes[offset] : nil
                    let right = offset < inserts.count ? inserts[offset] : nil
                    let kind: DiffKind = left != nil && right != nil ? .modified : (left != nil ? .removed : .added)
                    rows.append(DiffRow(
                        id: id,
                        oldNumber: left.map { $0 + 1 }, oldText: left.map { oldLines[$0] },
                        newNumber: right.map { $0 + 1 }, newText: right.map { newLines[$0] }, kind: kind
                    ))
                    id += 1
                }
            }
        }
        return rows
    }

    private static func lines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func normalized(_ line: String, ignoringWhitespace: Bool) -> String {
        ignoringWhitespace ? line.split(whereSeparator: \Character.isWhitespace).joined(separator: " ") : line
    }

    private static func editScript(_ lhs: [String], _ rhs: [String]) -> [Edit] {
        var lengths = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        if !lhs.isEmpty && !rhs.isEmpty {
            for i in stride(from: lhs.count - 1, through: 0, by: -1) {
                for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                    lengths[i][j] = lhs[i] == rhs[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }

        var edits: [Edit] = []
        var i = 0
        var j = 0
        while i < lhs.count || j < rhs.count {
            if i < lhs.count, j < rhs.count, lhs[i] == rhs[j] {
                edits.append(.same(i, j)); i += 1; j += 1
            } else if j < rhs.count, i == lhs.count || lengths[i][j + 1] > lengths[i + 1][j] {
                edits.append(.insert(j)); j += 1
            } else {
                edits.append(.delete(i)); i += 1
            }
        }
        return edits
    }
}
