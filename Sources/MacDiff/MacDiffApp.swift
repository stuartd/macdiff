#if os(macOS)
import SwiftUI

@main
struct MacDiffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var document = DiffDocument()

    var body: some Scene {
        Window("MacDiff", id: "comparison") {
            ContentView(document: document)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { document.clear() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
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
