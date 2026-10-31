#if os(macOS)
import AppKit

@MainActor
enum AppAbout {
    static func show() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.paragraphSpacing = 4
        let copyright = "© Stuart Dunkeld \(BuildMetadata.date.prefix(4))"
        let details = NSMutableAttributedString(
            string: "\(copyright)\nRose Hill Solutions\nversion: \(BuildMetadata.version)\nmacdiff",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        let text = details.string as NSString
        details.addAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            range: text.range(of: "\(copyright)\nRose Hill Solutions")
        )
        details.addAttribute(
            .link,
            value: URL(string: "https://github.com/stuartd/macdiff")!,
            range: text.range(of: "macdiff", options: .backwards)
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacDiff",
            .applicationVersion: "",
            .version: "",
            .credits: details,
            .init(rawValue: "Copyright"): ""
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#endif
