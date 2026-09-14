#if os(macOS)
import Foundation
import Testing
@testable import MacDiff

@MainActor
private func waitForDocument(_ document: DiffDocument) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while document.isComparing || document.isLoadingLeft || document.isLoadingRight {
        try #require(ContinuousClock.now < deadline, "Document did not finish its pending work")
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func distinguishesMissingInputsFromEmptyText() async throws {
    let document = DiffDocument()
    #expect(!document.hasBothInputs)
    #expect(document.selectedChange == nil)
    document.setText("", onLeft: true)
    #expect(document.hasLeft)
    #expect(!document.hasBothInputs)
    #expect(!document.isComparing)
    #expect(document.rows.isEmpty)

    document.setText("one line", onLeft: false)
    try await waitForDocument(document)
    #expect(document.hasBothInputs)
    #expect(document.addedCount == 1)
    #expect(document.rows.first?.oldText == nil)
    #expect(document.rows.first?.newText == "one line")

    document.setText("", onLeft: false)
    try await waitForDocument(document)
    #expect(document.hasBothInputs)
    #expect(document.rows.isEmpty)
    #expect(document.selectedChange == nil)
}

@Test @MainActor func navigatesChangeGroupsAndWrapsInBothDirections() async throws {
    let document = DiffDocument()
    document.setText("start\nold one\nold two\nmiddle\nold three", onLeft: true)
    document.setText("start\nnew one\nnew two\nmiddle\nnew three", onLeft: false)
    try await waitForDocument(document)

    #expect(document.changeStarts == [1, 4])
    #expect(document.modifiedCount == 3)
    #expect(document.addedCount == 0)
    #expect(document.removedCount == 0)
    #expect(document.selectedChange == 0)
    #expect(document.selectedRowID == document.rows[1].id)
    document.moveChange(-1)
    #expect(document.selectedChange == 1)
    #expect(document.selectedRowID == document.rows[4].id)
    document.moveChange(1)
    #expect(document.selectedChange == 0)
    document.moveChange(5)
    #expect(document.selectedChange == 1)
}

@Test @MainActor func changingWhitespaceOptionInvalidatesNavigationAndCounts() async throws {
    let document = DiffDocument()
    document.setText("a b\nseparator\nc d", onLeft: true)
    document.setText("a  b\nseparator\nc   d", onLeft: false)
    try await waitForDocument(document)
    document.moveChange(1)
    #expect(document.selectedChange == 1)

    document.ignoreWhitespace = true
    #expect(document.isComparing)
    #expect(document.selectedChange == nil)
    #expect(document.selectedRowID == nil)
    #expect(document.changeStarts.isEmpty)
    try await waitForDocument(document)
    #expect(document.modifiedCount == 0)
    #expect(document.selectedChange == nil)
    document.moveChange(-1)
    #expect(document.selectedChange == nil)

    document.ignoreWhitespace = false
    try await waitForDocument(document)
    #expect(document.modifiedCount == 2)
    #expect(document.selectedChange == 0)
}

@Test @MainActor func clearingCancelsPendingComparisonAndFileRead() async throws {
    let document = DiffDocument()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("macdiff-clear-\(UUID()).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("file content".utf8).write(to: url)
    document.setText("before", onLeft: true)
    document.setText("after", onLeft: false)
    #expect(document.isComparing)
    document.load(url, onLeft: true)
    #expect(document.isLoadingLeft)
    document.clear()
    // Wait beyond the debounce so a superseded job would have had a chance to publish.
    try await Task.sleep(for: .milliseconds(250))

    #expect(!document.hasLeft && !document.hasRight)
    #expect(document.leftText.isEmpty && document.rightText.isEmpty)
    #expect(document.leftURL == nil && document.rightURL == nil)
    #expect(!document.isComparing && !document.isLoadingLeft)
    #expect(document.rows.isEmpty && document.changeStarts.isEmpty)
    #expect(document.selectedRowID == nil)
    #expect(document.errorMessage == nil)
}

@Test @MainActor func supersededReadsCannotReplaceNewlyEnteredText() async throws {
    let document = DiffDocument()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("macdiff-superseded-\(UUID()).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("stale file content".utf8).write(to: url)
    document.load(url, onLeft: true)
    document.setText("latest input", onLeft: true)
    document.setText("latest input", onLeft: false)
    try await waitForDocument(document)

    #expect(document.leftText == "latest input")
    #expect(document.leftURL == nil)
    #expect(document.hasBothInputs)
    #expect(document.changeStarts.isEmpty)
    #expect(document.errorMessage == nil)
}

@Test @MainActor func failedReadRetainsPreviousInputAndReportsError() async throws {
    let document = DiffDocument()
    let directory = FileManager.default.temporaryDirectory
    let validURL = directory.appendingPathComponent("macdiff-valid-\(UUID()).txt")
    let invalidURL = directory.appendingPathComponent("macdiff-binary-\(UUID()).txt")
    defer {
        try? FileManager.default.removeItem(at: validURL)
        try? FileManager.default.removeItem(at: invalidURL)
    }
    try Data("keep this input".utf8).write(to: validURL)
    try Data([0x01, 0x00, 0x02]).write(to: invalidURL)
    document.load(validURL, onLeft: true)
    try await waitForDocument(document)
    #expect(document.leftURL == validURL)
    #expect(document.leftText == "keep this input")

    document.load(invalidURL, onLeft: true)
    try await waitForDocument(document)
    #expect(document.hasLeft)
    #expect(document.leftURL == validURL)
    #expect(document.leftText == "keep this input")
    #expect(document.errorMessage?.contains(invalidURL.lastPathComponent) == true)
    #expect(document.errorMessage?.contains("binary") == true)
}

@Test @MainActor func swapPreservesExplicitEmptyInputsAndReversesChanges() async throws {
    let document = DiffDocument()
    document.setText("", onLeft: true)
    document.setText("a\tb", onLeft: false)
    try await waitForDocument(document)
    #expect(document.addedCount == 1)
    #expect(document.longestLineCharacterCount == 6)
    document.swap()
    try await waitForDocument(document)
    #expect(document.hasBothInputs)
    #expect(document.removedCount == 1)
    #expect(document.leftText == "a\tb")
    #expect(document.rightText == "")
    document.clear(onLeft: false)
    #expect(document.hasLeft && !document.hasRight)
    #expect(!document.isComparing)
    #expect(document.rows.isEmpty)
}

@Test @MainActor func measuresUnicodeLinesWithoutTruncation() async throws {
    let document = DiffDocument()
    let text = String(repeating: "界🌍", count: 1_000) + "\ta"
    document.setText(text, onLeft: true)
    document.setText(text, onLeft: false)
    try await waitForDocument(document)
    #expect(document.longestLineCharacterCount == 4_005)
    #expect(document.rows.first?.oldText == text)
    #expect(document.changeStarts.isEmpty)
}

@Test @MainActor func invalidPastedInputRetainsPreviousText() {
    let document = DiffDocument()
    document.setText("previous input", onLeft: true)
    document.setText(String(repeating: "\n", count: 100_000), onLeft: true)
    #expect(document.leftText == "previous input")
    #expect(document.errorMessage?.contains("100,000 lines") == true)
    document.setText(String(repeating: "a", count: 100_001), onLeft: true)
    #expect(document.leftText == "previous input")
    #expect(document.errorMessage?.contains("100,000 display columns") == true)
}
#endif
