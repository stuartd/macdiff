#if os(macOS)
import AppKit

@MainActor
enum AppAbout {
    static func show() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let repositoryLink = NSAttributedString(
            string: "macdiff",
            attributes: [
                .link: URL(string: "https://github.com/stuartd/macdiff")!,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraphStyle
            ]
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacDiff",
            .applicationVersion: "version: \(BuildMetadata.version)",
            .version: "",
            .credits: repositoryLink,
            .init(rawValue: "Copyright"): "© Stuart Dunkeld \(BuildMetadata.date.prefix(4))\nRose Hill Solutions"
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#endif
