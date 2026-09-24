#if os(macOS)
import SwiftUI

/// Window-owned actions keep file importers and editors in the comparison view,
/// while their commands remain available in the menu bar and via shortcuts.
struct ComparisonActions {
    var open: (Bool) -> Void
    var paste: (Bool) -> Void
    var edit: (Bool) -> Void
    var copy: (Bool) -> Void
    var canChangeInputs: Bool
}

private struct ComparisonActionsKey: FocusedValueKey {
    typealias Value = ComparisonActions
}

extension FocusedValues {
    var comparisonActions: ComparisonActions? {
        get { self[ComparisonActionsKey.self] }
        set { self[ComparisonActionsKey.self] = newValue }
    }
}

struct ComparisonCommands: Commands {
    @ObservedObject var document: DiffDocument
    @FocusedValue(\.comparisonActions) private var actions
    @AppStorage("diffFontSize") private var fontSize = 13.0
    @AppStorage("appearance") private var appearance = "system"

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { document.clear() }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Open Original…") { actions?.open(true) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions?.canChangeInputs != true)
            Button("Open Changed…") { actions?.open(false) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions?.canChangeInputs != true)
            Button("Open Repository…") { document.chooseRepository() }
                .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Button("Refresh Repository") { document.refreshRepository() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!document.isRepositoryMode || document.isScanningRepository)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Paste Original") { actions?.paste(true) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(actions?.canChangeInputs != true)
            Button("Paste Changed") { actions?.paste(false) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(actions?.canChangeInputs != true)
            Button("Edit Original…") { actions?.edit(true) }
                .disabled(actions?.canChangeInputs != true)
            Button("Edit Changed…") { actions?.edit(false) }
                .disabled(actions?.canChangeInputs != true)
            Divider()
            Button("Copy Original Text") { actions?.copy(true) }
                .disabled(actions == nil || !document.hasLeft)
            Button("Copy Changed Text") { actions?.copy(false) }
                .disabled(actions == nil || !document.hasRight)
        }
        CommandMenu("Comparison") {
            Button("Previous Change") { document.moveChange(-1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(document.changeStarts.isEmpty || document.isComparing)
            Button("Next Change") { document.moveChange(1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(document.changeStarts.isEmpty || document.isComparing)
            Divider()
            Toggle("Ignore Spacing", isOn: $document.ignoreWhitespace)
            Button("Swap Inputs") { document.swap() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(document.isRepositoryMode || (!document.hasLeft && !document.hasRight))
        }
        CommandGroup(after: .toolbar) {
            Divider()
            Menu("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Button("Larger Text") { fontSize = min(fontSize + 1, 22) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { fontSize = max(fontSize - 1, 11) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Default Text Size") { fontSize = 13 }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
#endif
