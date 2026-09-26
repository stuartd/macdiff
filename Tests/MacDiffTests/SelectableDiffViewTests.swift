#if os(macOS)
import AppKit
import DiffCore
import Testing
@testable import MacDiff

@Test func selectionCopiesOriginalSourceAcrossAlignmentGaps() {
    let left = "\talpha 👩🏽‍💻\r\nbeta\rgamma\n"
    let right = "inserted\n\talpha 👩🏽‍💻\nbeta\nextra\ngamma\nlast"
    let rows = DiffEngine.compare(left, right)
    for (source, onLeft) in [(left, true), (right, false)] {
        let content = DiffTextContent(rows: rows, source: source, onLeft: onLeft)
        #expect(content.copiedText(in: NSRange(location: 0, length: content.text.utf16.count)) == source)
    }
    let content = DiffTextContent(rows: rows, source: left, onLeft: true)
    let start = (content.text as NSString).range(of: "alpha").location + 2
    let end = (content.text as NSString).range(of: "gamma").location + 3
    #expect(content.copiedText(in: NSRange(location: start, length: end - start)) == "pha 👩🏽‍💻\r\nbeta\rgam")
}

@Test(arguments: ["", "one", "one\n", "\n\n", "a\r\nb\r\n", "a\rb", "e\u{301}\t👩🏽‍💻"])
func selectAllPreservesEmptyLinesTabsUnicodeAndFinalNewlines(source: String) {
    let rows = DiffEngine.compare(source, "before\n" + source + "\nafter")
    let content = DiffTextContent(rows: rows, source: source, onLeft: true)
    #expect(content.copiedText(in: NSRange(location: 0, length: content.text.utf16.count)) == source)
}

@Test @MainActor func wrappedRowsAlignAndNativeSelectionSurvivesResize() throws {
    let left = "first\n" + String(repeating: "long word ", count: 35) + "\nthird\nfourth"
    let right = "first\nshort\ninserted\nthird\nfourth"
    let rows = DiffEngine.compare(left, right)
    let canvas = DiffCanvasView()
    canvas.configure(rows: rows, leftText: left, rightText: right, fontSize: 15, resetSelection: true)
    canvas.arrange(width: 800, minimumHeight: 300)
    let pane = canvas.leftPane
    let start = (pane.string as NSString).range(of: "irst").location
    let end = (pane.string as NSString).range(of: "fourth").location + 3
    let selection = NSRange(location: start, length: end - start)
    pane.setSelectedRange(selection)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(pane.writeSelection(to: pasteboard, type: .string))
    #expect(pasteboard.string(forType: .string) == String(left.dropFirst().dropLast(3)))
    #expect(!pane.isEditable)
    #expect(pane.isSelectable)

    for width: CGFloat in [800, 540, 1100] {
        canvas.arrange(width: width, minimumHeight: 300)
        #expect(pane.selectedRange() == selection)
        for index in rows.indices {
            let expectedY = pane.rowRects[index].minY
            for side in [canvas.leftPane, canvas.rightPane] {
                let manager = try #require(side.layoutManager)
                let glyph = manager.glyphIndexForCharacter(at: side.content.rowRanges[index].location)
                let actualY = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                #expect(abs(actualY - expectedY) < 1, "Row \(index) at width \(width): \(actualY) != \(expectedY)")
            }
        }
    }
}

@Test @MainActor func navigationDoesNotResetTextSelection() {
    let rows = DiffEngine.compare("one\ntwo", "one\nchanged")
    let view = DiffScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
    view.update(rows: rows, leftText: "one\ntwo", rightText: "one\nchanged", fontSize: 15, selectedRowID: nil)
    view.layoutSubtreeIfNeeded()
    let selection = NSRange(location: 1, length: 5)
    view.diffContent.leftPane.setSelectedRange(selection)
    view.update(rows: rows, leftText: "one\ntwo", rightText: "one\nchanged", fontSize: 15, selectedRowID: rows.last?.id)
    view.layoutSubtreeIfNeeded()
    #expect(view.diffContent.leftPane.selectedRange() == selection)
    #expect(view.diffContent.leftPane.selectedRowID == rows.last?.id)
    view.update(rows: rows, leftText: "one\ntwo", rightText: "one\nchanged", fontSize: 18, selectedRowID: rows.last?.id)
    view.layoutSubtreeIfNeeded()
    #expect(view.diffContent.leftPane.selectedRange() == selection)
    for height: CGFloat in [600, 200] {
        view.setFrameSize(NSSize(width: 800, height: height))
        view.layoutSubtreeIfNeeded()
        #expect(view.diffContent.frame.height == view.contentSize.height)
        #expect(view.diffContent.leftPane.frame.height == view.contentSize.height)
        #expect(view.diffContent.leftPane.selectedRange() == selection)
    }
}

@Test @MainActor func largeDocumentSupportsSelectionAndScrollingToLastLine() {
    let source = (1...10_000).map { "line \($0): source text" }.joined(separator: "\n")
    let rows = DiffEngine.compare(source, source)
    let view = DiffScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    view.update(rows: rows, leftText: source, rightText: source, fontSize: 15, selectedRowID: nil)
    view.layoutSubtreeIfNeeded()
    let pane = view.diffContent.leftPane
    let start = (pane.string as NSString).range(of: "line 9999:").location + 5
    let end = (pane.string as NSString).range(of: "line 10000:").location + 10
    let range = NSRange(location: start, length: end - start)
    pane.setSelectedRange(range)
    pane.scrollRangeToVisible(range)
    #expect(view.contentView.bounds.minY > 0)
    #expect(pane.content.copiedText(in: range) == "9999: source text\nline 10000")
    #expect(view.diffContent.leftPane.rowRects == view.diffContent.rightPane.rowRects)
}

@Test func buildMetadataIsCompiledIntoTheExecutable() {
    #expect(BuildMetadata.commit.range(of: "^[0-9a-fA-F]{7,12}$", options: .regularExpression) != nil || BuildMetadata.commit == "Unavailable")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    #expect(formatter.date(from: BuildMetadata.date) != nil)
}
#endif
