#if os(macOS)
import AppKit
import Testing
@testable import MacDiff

@Test func formattingMapsHighlightsAfterTabsAndUnicode() {
    let text = "\t👩🏽‍💻 e\u{301}\t30"
    let formatted = NSMutableAttributedString(string: text)
    DiffTextFormatting.highlight(text, ranges: [5..<6], color: .red, in: formatted)
    #expect(formatted.string == text)
    var highlighted: [String] = []
    formatted.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: formatted.length)) { value, range, _ in
        if value != nil { highlighted.append((formatted.string as NSString).substring(with: range)) }
    }
    #expect(highlighted == ["3"])
    let tab = NSMutableAttributedString(string: "a\tb")
    DiffTextFormatting.highlight(tab.string, ranges: [1..<2], color: .green, in: tab)
    #expect(tab.attribute(.backgroundColor, at: 1, effectiveRange: nil) != nil)
    #expect(tab.string == "a\tb")
}
#endif
