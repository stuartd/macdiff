import Testing
@testable import DiffCore

private func changedText(_ text: String?, _ ranges: [Range<Int>]) -> [String] {
    let characters = Array(text ?? "")
    return ranges.map { String(characters[$0]) }
}

@Test func highlightsOnlyChangedDigits() throws {
    let row = try #require(DiffEngine.compare("timeout = 30", "timeout = 60").first)
    #expect(row.kind == .modified)
    #expect(changedText(row.oldText, row.oldHighlights) == ["3"])
    #expect(changedText(row.newText, row.newHighlights) == ["6"])
}

@Test func highlightsSeparateEditsWithinOneLine() throws {
    let row = try #require(DiffEngine.compare("x = 12; y = 34", "x = 92; y = 38").first)
    #expect(changedText(row.oldText, row.oldHighlights) == ["1", "4"])
    #expect(changedText(row.newText, row.newHighlights) == ["9", "8"])
}

@Test func highlightsInsertedAndDeletedTextOnOnlyTheAffectedSide() throws {
    let old = "return value;"
    let new = "return new_value;"
    let inserted = try #require(DiffEngine.compare(old, new).first)
    #expect(inserted.oldHighlights.isEmpty)
    #expect(changedText(inserted.newText, inserted.newHighlights) == ["new_"])
    let deleted = try #require(DiffEngine.compare(new, old).first)
    #expect(changedText(deleted.oldText, deleted.oldHighlights) == ["new_"])
    #expect(deleted.newHighlights.isEmpty)
}

@Test func inlineHighlightsPreserveWholeUnicodeGraphemes() throws {
    let row = try #require(DiffEngine.compare("\t café 👩🏽‍💻 e\u{301}", "\t café 👨🏻‍💻 o\u{301}").first)
    #expect(changedText(row.oldText, row.oldHighlights) == ["👩🏽‍💻", "e\u{301}"])
    #expect(changedText(row.newText, row.newHighlights) == ["👨🏻‍💻", "o\u{301}"])
}

@Test func inlineHighlightsRespectIgnoredSpacing() throws {
    let old = "\t let  value = 30  "
    let new = "let value\t= 60"
    let row = try #require(DiffEngine.compare(old, new, ignoringWhitespace: true).first)
    #expect(changedText(row.oldText, row.oldHighlights) == ["3"])
    #expect(changedText(row.newText, row.newHighlights) == ["6"])
    let spacingOnly = try #require(DiffEngine.compare("a\tb", "a  b", ignoringWhitespace: true).first)
    #expect(spacingOnly.oldHighlights.isEmpty && spacingOnly.newHighlights.isEmpty)
    let significantSpace = try #require(DiffEngine.compare("a b", "ab", ignoringWhitespace: true).first)
    #expect(changedText(significantSpace.oldText, significantSpace.oldHighlights) == [" "])
}

@Test func exactSpacingAndEmptyLineChangesAreHighlighted() throws {
    let spacing = try #require(DiffEngine.compare("a\tb", "a b").first)
    #expect(changedText(spacing.oldText, spacing.oldHighlights) == ["\t"])
    #expect(changedText(spacing.newText, spacing.newHighlights) == [" "])
    let empty = DiffEngine.compare("same\n\nend", "same\nnew\nend")
    #expect(empty[1].oldHighlights.isEmpty)
    #expect(changedText(empty[1].newText, empty[1].newHighlights) == ["new"])
    #expect(empty[0].oldHighlights.isEmpty && empty[2].newHighlights.isEmpty)
    #expect(DiffEngine.compare("", "new")[0].newHighlights.isEmpty)
}

@Test func whitespaceRealignmentDoesNotHighlightAnUnchangedWord() throws {
    let row = try #require(DiffEngine.compare("\t let  total = 30  ", "let total\t= 60").first)
    let oldChanged = changedText(row.oldText, row.oldHighlights).joined().filter { !$0.isWhitespace }
    let newChanged = changedText(row.newText, row.newHighlights).joined().filter { !$0.isWhitespace }
    #expect(oldChanged == "3")
    #expect(newChanged == "6")
}

@Test func inlineDiffFallsBackSafelyWithinResourceLimits() {
    let old = "prefix " + String(repeating: "a", count: 1_000) + " suffix"
    let new = "prefix " + String(repeating: "b", count: 1_000) + " suffix"
    var budget = 10_000
    let result = InlineDiff.compare(old, new, ignoringWhitespace: false, remainingWork: &budget)
    #expect(changedText(old, result.old) == [String(repeating: "a", count: 1_000)])
    #expect(changedText(new, result.new) == [String(repeating: "b", count: 1_000)])
    #expect(budget >= 0 && budget < 10_000)
    budget = 0
    let exhausted = InlineDiff.compare("a", "b", ignoringWhitespace: false, remainingWork: &budget)
    #expect(exhausted.old.isEmpty && exhausted.new.isEmpty)
    let longLine = String(repeating: "a", count: 20_000)
    let row = DiffEngine.compare(longLine, longLine + "b")[0]
    #expect(row.kind == .modified)
    #expect(row.oldText == longLine && row.newText == longLine + "b")
    #expect(row.oldHighlights.isEmpty && row.newHighlights.isEmpty)
}

@Test func inlineRangesAreOrderedAndLeaveMatchingText() {
    var seed: UInt64 = 1234
    let alphabet: [Character] = Array("ab _=\t🌍")
    func random(_ upperBound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return Int((seed >> 32) % UInt64(upperBound))
    }
    func remaining(_ text: String, _ ranges: [Range<Int>]) -> String {
        var previousEnd = 0
        for range in ranges {
            #expect(range.lowerBound >= previousEnd && !range.isEmpty && range.upperBound <= text.count)
            previousEnd = range.upperBound
        }
        return String(text.enumerated().filter { offset, _ in !ranges.contains { $0.contains(offset) } }.map(\.element))
    }
    for _ in 0..<300 {
        let old = String((0..<random(30)).map { _ in alphabet[random(alphabet.count)] })
        let new = String((0..<random(30)).map { _ in alphabet[random(alphabet.count)] })
        var budget = 100_000
        let highlights = InlineDiff.compare(old, new, ignoringWhitespace: false, remainingWork: &budget)
        #expect(remaining(old, highlights.old) == remaining(new, highlights.new))
    }
}
