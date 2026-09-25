#if os(macOS)
import SwiftUI

enum AppTypography {
    static let body = Font.system(size: 14)
    static let detail = Font.system(size: 13)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let defaultDiffSize = 15.0
}
#endif
