#if os(macOS)
import SwiftUI

@main
struct MacDiffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate


    var body: some Scene {
        Window("MacDiff", id: "comparison") {
            ContentView(document: appDelegate.document)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MacDiff") { appDelegate.showAbout() }
            }
            ComparisonCommands(document: appDelegate.document)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let document = DiffDocument()
    private var shouldPresentComparison = false
    private var aboutPanel: NSPanel?

    func showAbout() {
        if aboutPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 364, height: 364),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "About MacDiff"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: AboutView())
            panel.center()
            aboutPanel = panel
        }
        aboutPanel?.makeKeyAndOrderFront(nil)
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard urls.count == 2, urls.allSatisfy(\.isFileURL) else {
            document.errorMessage = "Open exactly two files to compare."
            return
        }
        document.replaceComparison(original: urls[0], changed: urls[1])
        shouldPresentComparison = true
        if sender.isActive {
            presentComparison(in: sender)
        } else {
            // Activation is asynchronous. Ordering the window first can briefly
            // expose it behind the foreground app before activation raises it.
            sender.activate(ignoringOtherApps: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        presentComparison(in: NSApp)
    }

    private func presentComparison(in application: NSApplication) {
        guard shouldPresentComparison, application.isActive,
              let window = application.windows.first(where: { $0.canBecomeMain }) else { return }
        shouldPresentComparison = false
        window.makeKeyAndOrderFront(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        presentComparison(in: NSApp)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#else
@main
enum MacDiffApp {
    static func main() {
        print("MacDiff is a macOS application.")
    }
}
#endif
