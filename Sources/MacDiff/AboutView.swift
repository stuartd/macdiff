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

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Developer").foregroundStyle(.secondary)
                    Text("Stuart Dunkeld")
                }
                GridRow {
                    Text("Company").foregroundStyle(.secondary)
                    Text("Rose Hill Solutions")
                }
                GridRow {
                    Text("Commit").foregroundStyle(.secondary)
                    Text(BuildMetadata.commit)
                }
                .padding(.top, 8)
                GridRow {
                    Text("Built").foregroundStyle(.secondary)
                    Text(BuildMetadata.date)
                }
                GridRow {
                    Text("Repository").foregroundStyle(.secondary)
                    Link("stuartd/macdiff", destination: URL(string: "https://github.com/stuartd/macdiff")!)
                }
            }
            .font(.system(size: 14))
            .textSelection(.enabled)

            Text("© \(BuildMetadata.date.prefix(4)) Stuart Dunkeld")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(24)
        .frame(width: 364, height: 364)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}
#endif
