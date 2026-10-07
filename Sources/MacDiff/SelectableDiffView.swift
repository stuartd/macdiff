#if os(macOS)
import AppKit
import SwiftUI
import DiffCore

struct SelectableDiffView: NSViewRepresentable {
    let rows: [DiffRow]
    let leftText: String
    let rightText: String
    let fontSize: CGFloat
    let selectedRowID: Int?
    let isComparing: Bool

    func makeNSView(context: Context) -> DiffScrollView { DiffScrollView() }

    func updateNSView(_ view: DiffScrollView, context: Context) {
        // Rows and source text must describe the same completed comparison.
        guard !isComparing else { return }
        view.update(rows: rows, leftText: leftText, rightText: rightText,
                    fontSize: fontSize, selectedRowID: selectedRowID)
    }
}

final class DiffScrollView: NSScrollView {
    let diffContent = DiffCanvasView()
    private var rows: [DiffRow] = []
    private var leftText = ""
    private var rightText = ""
    private var fontSize: CGFloat = 0
    private var selectedRowID: Int?
    private var layoutWidth: CGFloat = 0
    private var needsTextLayout = true
    private var shouldRevealSelection = false

    init() {
        super.init(frame: .zero)
        documentView = diffContent
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(rows: [DiffRow], leftText: String, rightText: String, fontSize: CGFloat, selectedRowID: Int?) {
        let changed = self.rows != rows || !self.leftText.utf8.elementsEqual(leftText.utf8)
            || !self.rightText.utf8.elementsEqual(rightText.utf8)
        if changed || self.fontSize != fontSize {
            self.rows = rows
            self.leftText = leftText
            self.rightText = rightText
            self.fontSize = fontSize
            diffContent.configure(rows: rows, leftText: leftText, rightText: rightText,
                                  fontSize: fontSize, resetSelection: changed)
            needsTextLayout = true
        }
        if changed || self.selectedRowID != selectedRowID {
            self.selectedRowID = selectedRowID
            shouldRevealSelection = selectedRowID != nil
        }
        diffContent.selectRow(selectedRowID)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        guard width > 0 else { return }
        if needsTextLayout || layoutWidth != width {
            needsTextLayout = false
            layoutWidth = width
            diffContent.arrange(width: width, minimumHeight: contentSize.height)
        } else {
            let height = max(contentSize.height, (diffContent.leftPane.rowRects.last?.maxY ?? 0) + 10)
            if diffContent.frame.height != height {
                diffContent.setFrameSize(NSSize(width: width, height: height))
                diffContent.leftPane.setFrameSize(NSSize(width: diffContent.leftPane.frame.width, height: height))
                diffContent.rightPane.setFrameSize(NSSize(width: diffContent.rightPane.frame.width, height: height))
            }
        }
        if shouldRevealSelection {
            shouldRevealSelection = false
            if let id = selectedRowID, let index = rows.firstIndex(where: { $0.id == id }) {
                let row = diffContent.leftPane.rowRects[index]
                let y = max(0, min(row.midY - contentSize.height / 2,
                                   diffContent.frame.height - contentSize.height))
                contentView.scroll(to: NSPoint(x: 0, y: y))
                reflectScrolledClipView(contentView)
            }
        }
    }
}

final class DiffCanvasView: NSView {
    let leftPane = DiffPaneTextView(onLeft: true)
    let rightPane = DiffPaneTextView(onLeft: false)
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(leftPane)
        addSubview(rightPane)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(rows: [DiffRow], leftText: String, rightText: String, fontSize: CGFloat, resetSelection: Bool) {
        leftPane.configure(rows: rows, source: leftText, fontSize: fontSize, resetSelection: resetSelection)
        rightPane.configure(rows: rows, source: rightText, fontSize: fontSize, resetSelection: resetSelection)
    }

    func selectRow(_ id: Int?) {
        leftPane.selectedRowID = id
        rightPane.selectedRowID = id
    }

    func arrange(width: CGFloat, minimumHeight: CGFloat) {
        let paneWidth = max(1, (width - 1) / 2)
        let leftHeights = leftPane.measureRows(width: paneWidth)
        let rightHeights = rightPane.measureRows(width: paneWidth)
        let heights = zip(leftHeights, rightHeights).map { max($0, $1) + 10 }
        leftPane.alignRows(heights: heights, naturalHeights: leftHeights)
        rightPane.alignRows(heights: heights, naturalHeights: rightHeights)
        let height = max(minimumHeight, heights.reduce(0, +) + 10)
        frame.size = NSSize(width: width, height: height)
        leftPane.frame = NSRect(x: 0, y: 0, width: paneWidth, height: height)
        rightPane.frame = NSRect(x: paneWidth + 1, y: 0, width: paneWidth, height: height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: (bounds.width - 1) / 2, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }
}

/// One native text view per side owns the entire selection, including wrapped
/// lines and drags that autoscroll. Line numbers and markers are drawn separately.
final class DiffPaneTextView: NSTextView {
    let onLeft: Bool
    private(set) var content = DiffTextContent(rows: [], source: "", onLeft: true)
    private var rows: [DiffRow] = []
    private var codeFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private var paragraphStyle = NSMutableParagraphStyle()
    private var measurements: [(width: CGFloat, heights: [CGFloat])] = []
    private var alignedHeights: [CGFloat] = []
    private var alignedNaturalHeights: [CGFloat] = []
    private(set) var rowRects: [NSRect] = []
    var selectedRowID: Int? { didSet { if oldValue != selectedRowID { needsDisplay = true } } }
    private var numberWidth: CGFloat { max(52, codeFont.pointSize * 3.9) }
    private var gutterWidth: CGFloat { numberWidth + 28 }
    override var textContainerOrigin: NSPoint { NSPoint(x: gutterWidth, y: 5) }

    init(onLeft: Bool) {
        self.onLeft = onLeft
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        manager.usesFontLeading = false
        isEditable = false
        isSelectable = true
        isRichText = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        drawsBackground = false
        textContainerInset = .zero
        clipsToBounds = true
        // File drops belong to the surrounding comparison view, including over
        // read-only text and the blank space below it.
        unregisterDraggedTypes()
        setAccessibilityLabel(onLeft ? "Original text" : "Changed text")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(rows: [DiffRow], source: String, fontSize: CGFloat, resetSelection: Bool) {
        let selection = selectedRanges
        self.rows = rows
        measurements = []
        alignedHeights = []
        alignedNaturalHeights = []
        rowRects = []
        content = DiffTextContent(rows: rows, source: source, onLeft: onLeft)
        codeFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.tabStops = []
        paragraphStyle.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: codeFont]).width
        let attributed = NSMutableAttributedString(string: content.text, attributes: [
            .font: codeFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle
        ])
        for (index, row) in rows.enumerated() {
            let text = (onLeft ? row.oldText : row.newText) ?? ""
            DiffTextFormatting.highlight(text, ranges: onLeft ? row.oldHighlights : row.newHighlights,
                                         color: markerColor, in: attributed, offset: content.rowRanges[index].location)
        }
        textStorage?.setAttributedString(attributed)
        if resetSelection { setSelectedRange(NSRange(location: 0, length: 0)) }
        else { selectedRanges = selection }
    }

    func measureRows(width: CGFloat) -> [CGFloat] {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return [] }
        container.containerSize = NSSize(width: max(1, width - gutterWidth - 8), height: .greatestFiniteMagnitude)
        if let cached = measurements.first(where: { $0.width == width }) { return cached.heights }
        alignedHeights = []
        alignedNaturalHeights = []
        storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: storage.length))
        manager.ensureLayout(for: container)
        let heights = content.rowRanges.map { range in
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let first = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = manager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            return ceil(last.maxY - first.minY)
        }
        measurements.append((width, heights))
        // Bound retained measurements while reusing widths during live resizing.
        if measurements.count > 3 { measurements.removeFirst() }
        return heights
    }

    func alignRows(heights: [CGFloat], naturalHeights: [CGFloat]) {
        guard let storage = textStorage else { return }
        if heights == alignedHeights && naturalHeights == alignedNaturalHeights {
            if let container = textContainer { layoutManager?.ensureLayout(for: container) }
            needsDisplay = true
            return
        }
        alignedHeights = heights
        alignedNaturalHeights = naturalHeights
        var y: CGFloat = 0
        rowRects = []
        storage.beginEditing()
        for index in heights.indices {
            let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = heights[index] - naturalHeights[index]
            let range = content.rowRanges[index]
            storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            // A source row may contain U+2029 paragraphs. Add the alignment gap
            // once, after its final paragraph, rather than after every paragraph.
            let lastParagraph = (content.text as NSString).paragraphRange(
                for: NSRange(location: NSMaxRange(range) - 1, length: 0))
            storage.addAttribute(.paragraphStyle, value: style,
                                 range: NSIntersectionRange(range, lastParagraph))
            rowRects.append(NSRect(x: 0, y: y, width: 0, height: heights[index]))
            y += heights[index]
        }
        storage.endEditing()
        if let container = textContainer { layoutManager?.ensureLayout(for: container) }
        needsDisplay = true
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let text = selectedRanges.map { content.copiedText(in: $0.rangeValue) }.joined()
        return pasteboard.setString(text, forType: .string)
    }

    private var markerColor: NSColor { onLeft ? .systemRed : .systemGreen }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        // Binary search the first visible row so scrolling large files does not
        // scan or draw every row in the document.
        var low = 0
        var high = rowRects.count
        while low < high {
            let middle = (low + high) / 2
            if rowRects[middle].maxY < dirtyRect.minY { low = middle + 1 } else { high = middle }
        }
        var visible: [Int] = []
        for index in low..<rowRects.count {
            if rowRects[index].minY > dirtyRect.maxY { break }
            visible.append(index)
            let row = rows[index]
            if row.kind == .modified || (onLeft ? row.kind == .removed : row.kind == .added) {
                markerColor.withAlphaComponent(0.12).setFill()
                NSRect(x: 0, y: rowRects[index].minY, width: bounds.width, height: rowRects[index].height).fill()
            }
        }
        // NSTextView adjusts the drawing origin for its text container. Keep
        // gutter drawing in this view's coordinates, clipped to its own pane.
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        for index in visible {
            let row = rows[index]
            let rect = NSRect(x: 0, y: rowRects[index].minY, width: bounds.width, height: rowRects[index].height)
            if let number = onLeft ? row.oldNumber : row.newNumber {
                let label = String(number) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: codeFont, .foregroundColor: NSColor.secondaryLabelColor]
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: numberWidth - size.width, y: rect.minY + 5), withAttributes: attributes)
            }
            let marker: String
            switch row.kind {
            case .added: marker = onLeft ? "" : "+"
            case .removed: marker = onLeft ? "−" : ""
            case .modified: marker = onLeft ? "−" : "+"
            case .unchanged: marker = ""
            }
            (marker as NSString).draw(at: NSPoint(x: numberWidth + 10, y: rect.minY + 5),
                                     withAttributes: [.font: codeFont, .foregroundColor: markerColor])
            if row.id == selectedRowID {
                NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
                NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
                if onLeft {
                    NSColor.controlAccentColor.setFill()
                    NSRect(x: 0, y: rect.minY, width: 3, height: rect.height).fill()
                }
            }
        }
    }
}
#endif
