#if os(macOS)
import AppKit
import SwiftUI

@MainActor
enum AppAbout {
    private static var panel: NSPanel?

    static func show() {
        if panel == nil {
            let contentView = NSHostingView(rootView: MacDiffAboutView())
            let aboutPanel = NSPanel(
                contentRect: NSRect(origin: .zero, size: contentView.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            aboutPanel.title = "About MacDiff"
            aboutPanel.isReleasedWhenClosed = false
            aboutPanel.contentView = contentView
            aboutPanel.center()
            panel = aboutPanel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func close() {
        panel?.close()
    }
}

private struct MacDiffAboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("MacDiff")
                    .font(.system(size: 26, weight: .semibold))
            }

            VStack(spacing: 4) {
                Text("© Stuart Dunkeld \(BuildMetadata.date.prefix(4))")
                Text("Rose Hill Solutions")
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("version: \(BuildMetadata.version)")
                Link("macdiff", destination: URL(string: "https://github.com/stuartd/macdiff")!)
            }
            .font(.system(size: 14))
            .textSelection(.enabled)
        }
        .padding(24)
        .frame(width: 380)
        .onExitCommand(perform: AppAbout.close)
    }
}
#endif
