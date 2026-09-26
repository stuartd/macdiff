#if os(macOS)
import AppKit
import SwiftUI

struct AboutView: View {
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(spacing: 20) {
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
            .multilineTextAlignment(.center)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Commit").foregroundStyle(.secondary)
                    Text(BuildMetadata.commit)
                }
                GridRow {
                    Text("Built").foregroundStyle(.secondary)
                    Text(BuildMetadata.date)
                }
                GridRow {
                    Text("Repository").foregroundStyle(.secondary)
                    Link("stuartd/MacClipboardDiff", destination: URL(string: "https://github.com/stuartd/MacClipboardDiff")!)
                }
            }
            .font(.system(size: 14))
            .textSelection(.enabled)

        }
        .padding(24)
        .frame(width: 364, height: 324)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}
#endif
