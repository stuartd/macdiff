#if os(macOS)
import SwiftUI

@main
struct MacDiffApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
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
