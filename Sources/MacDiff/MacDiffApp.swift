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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { appDelegate.document.clear() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let document = DiffDocument()

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard urls.count == 2, urls.allSatisfy(\.isFileURL) else {
            document.errorMessage = "Open exactly two files to compare."
            return
        }
        document.replaceComparison(original: urls[0], changed: urls[1])
        sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
