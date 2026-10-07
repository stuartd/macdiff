#if os(macOS)
import AppKit
import DiffCore
import Foundation
import Testing
@testable import MacDiff

/// Opt in locally or through workflow_dispatch; emit measurements without an
/// invented timing threshold across different Mac models and CI machines.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACDIFF_RUN_PERFORMANCE_TESTS"] == "1"))
@MainActor func measureLargeInputValidationAndTextLayout() throws {
    let samples = [
        ("100000 lines", Array(repeating: "line text", count: 100_000).joined(separator: "\n")),
        ("long wrapped lines", Array(repeating: String(repeating: "word ", count: 10_000), count: 80).joined(separator: "\n")),
        ("Unicode input", Array(repeating: String(repeating: "界🌍", count: 500), count: 800).joined(separator: "\n"))
    ]
    for (name, source) in samples {
        let validationStart = ContinuousClock.now
        try TextFileReader.validate(source)
        print("PERFORMANCE \(name) input validation: \(validationStart.duration(to: .now))")
        let rows = DiffEngine.compare(source, source)
        let canvas = DiffCanvasView()
        let initialStart = ContinuousClock.now
        canvas.configure(rows: rows, leftText: source, rightText: source, fontSize: 15, resetSelection: true)
        canvas.arrange(width: 1000, minimumHeight: 400)
        print("PERFORMANCE \(name) initial display: \(initialStart.duration(to: .now))")
        let resizeStart = ContinuousClock.now
        for width: CGFloat in [800, 600, 1000, 800, 1000] {
            canvas.arrange(width: width, minimumHeight: 400)
        }
        print("PERFORMANCE \(name) resize sequence: \(resizeStart.duration(to: .now))")
        let fontStart = ContinuousClock.now
        canvas.configure(rows: rows, leftText: source, rightText: source, fontSize: 18, resetSelection: false)
        canvas.arrange(width: 1000, minimumHeight: 400)
        print("PERFORMANCE \(name) font change: \(fontStart.duration(to: .now))")
        #expect(canvas.leftPane.rowRects.count == rows.count)
        #expect(canvas.leftPane.rowRects == canvas.rightPane.rowRects)
    }
}
#endif
