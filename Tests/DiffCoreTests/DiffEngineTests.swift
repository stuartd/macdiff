import Testing
@testable import DiffCore

@Test func identicalFiles() {
    let rows = DiffEngine.compare("one\ntwo", "one\ntwo")
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.kind == .unchanged })
}

@Test func alignsModification() {
    let rows = DiffEngine.compare("one\nold\nthree", "one\nnew\nthree")
    #expect(rows.count == 3)
    #expect(rows[1].kind == .modified)
    #expect(rows[1].oldNumber == 2)
    #expect(rows[1].newNumber == 2)
}

@Test func handlesInsertionsAndDeletions() {
    let rows = DiffEngine.compare("keep\nremove", "keep\nadd\nmore")
    #expect(rows.map(\.kind) == [.unchanged, .modified, .added])
    #expect(rows[2].oldNumber == nil)
    #expect(rows[2].newNumber == 3)
}

@Test func optionallyIgnoresWhitespace() {
    let exact = DiffEngine.compare("let x = 1", "let   x = 1")
    let relaxed = DiffEngine.compare("let x = 1", "let   x = 1", ignoringWhitespace: true)
    #expect(exact[0].kind == .modified)
    #expect(relaxed[0].kind == .unchanged)
}

@Test func emptyInputsAndEmptyLines() {
    #expect(DiffEngine.compare("", "").isEmpty)
    let inserted = DiffEngine.compare("", "\n")
    #expect(inserted.map(\.kind) == [.added, .added])
    #expect(inserted.map(\.newText) == ["", ""])
    let removed = DiffEngine.compare("\n", "")
    #expect(removed.map(\.kind) == [.removed, .removed])
    #expect(removed.map(\.oldNumber) == [1, 2])
}

@Test func trailingNewlineIsVisible() {
    let rows = DiffEngine.compare("one", "one\n")
    #expect(rows.map(\.kind) == [.unchanged, .added])
    #expect(rows.last?.newText == "")
    #expect(rows.last?.newNumber == 2)
    let removed = DiffEngine.compare("one\n", "one")
    #expect(removed.map(\.kind) == [.unchanged, .removed])
}

@Test func recognizesWindowsAndLegacyLineEndings() {
    let rows = DiffEngine.compare("one\r\ntwo\r\n", "one\ntwo\n")
    #expect(rows.map(\.kind) == [.unchanged, .unchanged, .unchanged])
    #expect(rows.compactMap(\.oldText) == ["one", "two", ""])
    let mixed = DiffEngine.compare("one\rtwo\r\nthree\nfour", "one\ntwo\nthree\nfour")
    #expect(mixed.count == 4)
    #expect(mixed.allSatisfy { $0.kind == .unchanged })
}

@Test func preservesUnicodeAndOriginalWhitespace() {
    let old = "\t café 👩🏽‍💻 e\u{301}  \r\n\t"
    let new = "café   👩🏽‍💻 e\u{301}\n "
    let rows = DiffEngine.compare(old, new, ignoringWhitespace: true)
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.kind == .unchanged })
    #expect(rows[0].oldText == "\t café 👩🏽‍💻 e\u{301}  ")
    #expect(rows[0].newText == "café   👩🏽‍💻 e\u{301}")
    #expect(rows[1].oldText == "\t")
    #expect(rows[1].newText == " ")
    #expect(DiffEngine.compare("a b", "ab", ignoringWhitespace: true)[0].kind == .modified)
}

@Test func alignsRepeatedLinesAndMovedBlocks() {
    let old = ["start", "same", "a", "same", "b", "same", "end"]
    let new = ["start", "same", "b", "same", "a", "same", "end"]
    let rows = DiffEngine.compare(old.joined(separator: "\n"), new.joined(separator: "\n"))
    #expect(rows.compactMap(\.oldText) == old)
    #expect(rows.compactMap(\.newText) == new)
    #expect(rows.filter { $0.kind == .unchanged }.count == longestCommonSubsequence(old, new))
}

@Test func largeMostlyIdenticalInputs() {
    let old = (0..<20_000).map { "line \($0)" }
    var new = old
    new[100] = "updated early line"
    new[19_000] = "updated late line"
    new.insert("inserted line", at: 10_000)
    let rows = DiffEngine.compare(old.joined(separator: "\n"), new.joined(separator: "\n"))
    #expect(rows.count == 20_001)
    #expect(rows.filter { $0.kind == .modified }.count == 2)
    #expect(rows.filter { $0.kind == .added }.count == 1)
    #expect(rows.filter { $0.kind == .unchanged }.count == 19_998)
    #expect(rows.compactMap(\.oldText) == old)
    #expect(rows.compactMap(\.newText) == new)
}

@Test func largeUnrelatedInputs() {
    let old = (0..<20_000).map { "old \($0)" }
    let new = (0..<20_000).map { "new \($0)" }
    let rows = DiffEngine.compare(old.joined(separator: "\n"), new.joined(separator: "\n"))
    #expect(rows.count == 20_000)
    #expect(rows.allSatisfy { $0.kind == .modified })
    #expect(rows.compactMap(\.oldText) == old)
    #expect(rows.compactMap(\.newText) == new)
}


@Test func veryDifferentLineCountsKeepInteriorMatch() {
    var many = (0..<10_000).map { "line \($0)" }
    many[4_123] = "needle"
    let forward = DiffEngine.compare("needle", many.joined(separator: "\n"))
    let reverse = DiffEngine.compare(many.joined(separator: "\n"), "needle")
    #expect(forward.count == many.count)
    #expect(reverse.count == many.count)
    #expect(forward[4_123].kind == .unchanged)
    #expect(reverse[4_123].kind == .unchanged)
    #expect(forward.compactMap(\.newText) == many)
    #expect(reverse.compactMap(\.oldText) == many)
}

@Test func heavilyChangedInputsPreserveAllLines() {
    // One shared interior line defeats the disjoint fast path; the bounded search
    // must still finish without dropping or reordering either document's contents.
    var old = (0..<6_000).map { "old \($0)" }
    var new = (0..<6_000).map { "new \($0)" }
    old[3_000] = "common"
    new[3_000] = "common"
    let rows = DiffEngine.compare(old.joined(separator: "\n"), new.joined(separator: "\n"))
    #expect(rows.compactMap(\.oldText) == old)
    #expect(rows.compactMap(\.newText) == new)
    #expect(rows.map(\.id) == Array(rows.indices))
}

@Test func smallDiffsHaveOptimalMatchesAndReconstructBothInputs() {
    // Fixed seed keeps failures reproducible, with enough repeated symbols to
    // exercise ambiguous alignments and odd/even edit-path intersections.
    var state: UInt64 = 0xC11FD1FF
    func random(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return Int((state >> 32) % UInt64(upperBound))
    }
    for _ in 0..<600 {
        let old = (0..<random(15)).map { _ in String(random(4)) }
        let new = (0..<random(15)).map { _ in String(random(4)) }
        let rows = DiffEngine.compare(old.joined(separator: "\n"), new.joined(separator: "\n"))
        #expect(rows.compactMap(\.oldText) == old)
        #expect(rows.compactMap(\.newText) == new)
        #expect(rows.compactMap(\.oldNumber) == Array(1..<(old.count + 1)))
        #expect(rows.compactMap(\.newNumber) == Array(1..<(new.count + 1)))
        #expect(rows.map(\.id) == Array(rows.indices))
        #expect(rows.filter { $0.kind == .unchanged }.count == longestCommonSubsequence(old, new))
        #expect(rows.filter { $0.kind == .unchanged }.allSatisfy { $0.oldText == $0.newText })
        #expect(rows.filter { $0.kind == .added }.allSatisfy { $0.oldText == nil && $0.newText != nil })
        #expect(rows.filter { $0.kind == .removed }.allSatisfy { $0.oldText != nil && $0.newText == nil })
        #expect(rows.filter { $0.kind == .modified }.allSatisfy { $0.oldText != nil && $0.newText != nil })
    }
}

@Test func cancelledComparisonsReturnNoRows() async {
    let comparison = Task {
        while !Task.isCancelled { await Task.yield() }
        return DiffEngine.compare("one\ntwo", "one\nthree")
    }
    comparison.cancel()
    #expect(await comparison.value.isEmpty)
}

/// Small independent reference implementation; deliberately restricted to tiny
/// test inputs so production's memory and search bounds do not apply here.
private func longestCommonSubsequence(_ old: [String], _ new: [String]) -> Int {
    var lengths = Array(repeating: 0, count: new.count + 1)
    for oldLine in old {
        var previous = 0
        for (index, newLine) in new.enumerated() {
            let above = lengths[index + 1]
            lengths[index + 1] = oldLine == newLine ? previous + 1 : max(above, lengths[index])
            previous = above
        }
    }
    return lengths[new.count]
}
