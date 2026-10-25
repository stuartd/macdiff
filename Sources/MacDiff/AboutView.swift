#if os(macOS)
import AppKit
import SwiftUI

struct AboutView: View {
    @AppStorage("appearance") private var appearance = "system"
    let onClose: () -> Void

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

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text(BuildMetadata.releaseTag.isEmpty ? "Commit" : "Version")
                        .foregroundStyle(.secondary)
                    Text(BuildMetadata.releaseTag.isEmpty ? BuildMetadata.commit : BuildMetadata.releaseTag)
                }
                GridRow {
                    Text("Repository").foregroundStyle(.secondary)
                    Link("stuartd/macdiff", destination: URL(string: "https://github.com/stuartd/macdiff")!)
                }
            }
            .font(.system(size: 14))
            .textSelection(.enabled)

            Button(action: onClose) {
                Text("OK")
                    .frame(minWidth: 56)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 380)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .onExitCommand(perform: onClose)
    }
}
#endif
