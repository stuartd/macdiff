#if os(macOS)
import SwiftUI
import Testing
@testable import MacDiff

@Test func formattingMapsHighlightsAfterTabsAndUnicode() {
    let text = "\t👩🏽‍💻 e\u{301}\t30"
    let formatted = DiffTextFormatting.attributed(text, highlights: [5..<6], color: .red)
    #expect(String(formatted.characters) == "    👩🏽‍💻 e\u{301}    30")
    let highlighted = formatted.runs.filter { $0.backgroundColor != nil }
    #expect(highlighted.count == 1)
    #expect(highlighted.map { String(formatted[$0.range].characters) } == ["3"])
    let tab = DiffTextFormatting.attributed("a\tb", highlights: [1..<2], color: .green)
    #expect(tab.runs.filter { $0.backgroundColor != nil }.map { String(tab[$0.range].characters) } == ["    "])
}
#endif
