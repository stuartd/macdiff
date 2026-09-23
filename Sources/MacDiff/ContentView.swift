#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DiffCore

struct ContentView: View {
    @ObservedObject var document: DiffDocument
    @State private var choosingLeft = true
    @State private var showingImporter = false
    @State private var importDirectory = URL.documentsDirectory
    @State private var editorInput: EditorInput?
    @State private var loadedLaunchInputs = false
    @AppStorage("diffFontSize") private var fontSize = 13.0
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sourceHeader(onLeft: true)
                Divider()
                sourceHeader(onLeft: false)
            }
            .frame(height: 74)
            Divider()
            GeometryReader { geometry in
                Group {
                    if document.hasBothInputs {
                        diffView
                    } else {
                        welcome
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, location in
                    loadDroppedFile(urls, onLeft: location.x < geometry.size.width / 2)
                }
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task { loadLaunchInputs() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case let .success(url):
                importDirectory = url.deletingLastPathComponent()
                document.load(url, onLeft: choosingLeft)
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError {
                    document.errorMessage = error.localizedDescription
                }
            }
        }
        .fileDialogDefaultDirectory(importDirectory)
        .alert("Unable to use this input", isPresented: Binding(
            get: { document.errorMessage != nil },
            set: { if !$0 { document.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { document.errorMessage = nil }
        } message: {
            Text(document.errorMessage ?? "")
        }
        .sheet(item: $editorInput) { input in
            TextInputEditor(input: input) { text in
                try document.updateText(text, onLeft: input.onLeft)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Label("MacDiff", systemImage: "square.split.2x1")
                .font(.headline)
            Button { document.clear() } label: {
                Label("New", systemImage: "doc.badge.plus")
            }
            .help("Start a new comparison by clearing both inputs (⌘N)")
            Spacer()
            Button { document.moveChange(-1) } label: {
                Label("Previous change", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("[", modifiers: .command)
            .help("Previous group of changes (⌘[)")
            .disabled(document.changeStarts.isEmpty || document.isComparing)
            Button { document.moveChange(1) } label: {
                Label("Next change", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("]", modifiers: .command)
            .help("Next group of changes (⌘])")
            .disabled(document.changeStarts.isEmpty || document.isComparing)
            Divider().frame(height: 18)
            Menu {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Divider()
                Button("Larger Text") { fontSize = min(fontSize + 1, 22) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { fontSize = max(fontSize - 1, 11) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Default Text Size") { fontSize = 13 }
                    .keyboardShortcut("0", modifiers: .command)
            } label: {
                Label("Appearance", systemImage: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose light or dark appearance and adjust text size")
            Toggle("Ignore spacing", isOn: $document.ignoreWhitespace)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Ignore leading and trailing whitespace and changes in whitespace runs. Line breaks still matter.")
            Button { document.swap() } label: {
                Label("Swap", systemImage: "arrow.left.arrow.right")
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!document.hasLeft && !document.hasRight)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(.bar)
    }

    private func sourceHeader(onLeft: Bool) -> some View {
        let url = onLeft ? document.leftURL : document.rightURL
        let hasInput = onLeft ? document.hasLeft : document.hasRight
        let isLoading = onLeft ? document.isLoadingLeft : document.isLoadingRight
        let title = onLeft ? "Original" : "Changed"
        let otherURL = onLeft ? document.rightURL : document.leftURL
        let filename = Text(url.map { FilePathLabel.title(for: $0, comparedWith: otherURL) } ?? (hasInput ? "" : "No input"))
            .font(.system(size: 16, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(url.map { FilePathLabel.clipboardTitle(for: $0) ?? $0.path } ?? title)
            .frame(maxWidth: .infinity, alignment: onLeft ? .leading : .trailing)
        let loadingIndicator = HStack {
            if onLeft { Spacer(minLength: 0) }
            if isLoading {
                ProgressView().controlSize(.small).accessibilityLabel("Loading \(title.lowercased())")
            }
            if !onLeft { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if onLeft { filename } else { loadingIndicator }
                Text(title.uppercased())
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()
                if onLeft { loadingIndicator } else { filename }
            }
            ZStack {
                HStack(spacing: 14) {
                    Button { paste(onLeft: onLeft) } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                        .keyboardShortcut("v", modifiers: onLeft ? [.command, .shift] : [.command, .option])
                        .help(onLeft ? "Paste original (⇧⌘V)" : "Paste changed (⌥⌘V)")
                    Button { open(onLeft: onLeft) } label: { Label("Open", systemImage: "folder") }
                        .keyboardShortcut("o", modifiers: onLeft ? .command : [.command, .shift])
                        .help("Open a text file, or drop one onto this header or the text below")
                    Button { edit(onLeft: onLeft) } label: { Label("Edit", systemImage: "square.and.pencil") }
                        .help("Type or edit \(title.lowercased()) text")
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 14) {
                    Button { copy(onLeft: onLeft) } label: { Label("Copy \(title.lowercased()) text", systemImage: "doc.on.doc") }
                        .labelStyle(.iconOnly).disabled(!hasInput)
                        .help("Copy the complete \(title.lowercased()) text")
                    Button { document.clear(onLeft: onLeft) } label: { Label("Clear \(title.lowercased())", systemImage: "xmark.circle") }
                        .labelStyle(.iconOnly).disabled(!hasInput && !isLoading)
                        .help("Clear \(title.lowercased()) input")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            loadDroppedFile(urls, onLeft: onLeft)
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Compare two versions").font(.title2.weight(.semibold))
                Text("Add an original and a changed version to see what’s different.")
                    .foregroundStyle(.secondary)
                Text("Open two files, drop them onto either text pane, or paste text from the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 20) {
                inputCard(onLeft: true)
                inputCard(onLeft: false)
            }
            .padding(.horizontal, 36)
            .frame(maxWidth: 1000)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inputCard(onLeft: Bool) -> some View {
        let hasInput = onLeft ? document.hasLeft : document.hasRight
        let text = onLeft ? document.leftText : document.rightText
        return VStack(alignment: .leading, spacing: 12) {
            Label(onLeft ? "Original" : "Changed", systemImage: hasInput ? "checkmark.circle.fill" : "circle.dashed")
                .font(.headline).foregroundStyle(hasInput ? Color.accentColor : .secondary)
            if hasInput {
                Text(text.isEmpty ? "Empty text" : String(text.prefix(1200)))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(7)
                    .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110, alignment: .topLeading)
                Button("Edit text…") { edit(onLeft: onLeft) }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110)
                    .accessibilityHidden(true)
                Button("Paste \(onLeft ? "Original" : "Changed")") { paste(onLeft: onLeft) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var diffView: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, (geometry.size.width - 1) / 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(document.rows) { row in
                            DiffRowView(row: row, paneWidth: paneWidth, fontSize: fontSize, selected: row.id == document.selectedRowID)
                                .id(row.id)
                        }
                    }
                    .frame(width: paneWidth * 2 + 1, alignment: .topLeading)
                }
                .onChange(of: document.selectedRowID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: document.isComparing) { _, comparing in
                    if !comparing, let id = document.selectedRowID { proxy.scrollTo(id, anchor: .center) }
                }
                .overlay {
                    if document.isComparing {
                        ProgressView("Comparing…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    } else if document.rows.isEmpty {
                        ContentUnavailableView("Both inputs are empty", systemImage: "equal.circle", description: Text("Paste or edit either side to compare text."))
                    }
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            if document.hasBothInputs && !document.isComparing {
                Label("\(document.addedCount) added", systemImage: "plus").foregroundStyle(.green)
                Label("\(document.removedCount) removed", systemImage: "minus").foregroundStyle(.red)
                Label("\(document.modifiedCount) changed", systemImage: "pencil").foregroundStyle(.orange)
            }
            Spacer()
            Text(statusText).foregroundStyle(.secondary)
        }
        .font(.caption).padding(.horizontal, 16).frame(height: 30).background(.bar)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if document.isLoadingLeft || document.isLoadingRight { return "Loading text…" }
        if !document.hasLeft && !document.hasRight { return "Add two inputs to begin" }
        if !document.hasLeft { return "Add the original text" }
        if !document.hasRight { return "Add the changed text" }
        if document.isComparing { return "Comparing…" }
        if document.changeStarts.isEmpty {
            return document.ignoreWhitespace ? "No differences ignoring spacing" : "No differences"
        }
        return "Change \((document.selectedChange ?? 0) + 1) of \(document.changeStarts.count)"
    }

    private func loadLaunchInputs() {
        guard !loadedLaunchInputs else { return }
        loadedLaunchInputs = true
        do {
            let request = try LaunchRequest.parse(Array(CommandLine.arguments.dropFirst()), currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            switch request {
            case .empty: break
            case let .compare(original, changed):
                document.replaceComparison(original: original, changed: changed)
            case .help:
                print(LaunchRequest.usage)
                NSApp.terminate(nil)
            }
        } catch {
            document.errorMessage = error.localizedDescription
        }
    }

    private func open(onLeft: Bool) {
        choosingLeft = onLeft
        showingImporter = true
    }

    private func loadDroppedFile(_ urls: [URL], onLeft: Bool) -> Bool {
        guard urls.count == 1, let url = urls.first, url.isFileURL else { return false }
        document.load(url, onLeft: onLeft)
        return true
    }

    private func edit(onLeft: Bool) {
        editorInput = EditorInput(onLeft: onLeft, text: onLeft ? document.leftText : document.rightText)
    }

    private func paste(onLeft: Bool) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            document.errorMessage = "The clipboard doesn’t contain plain text. Copy some text and try again."
            return
        }
        document.setText(text, onLeft: onLeft)
    }

    private func copy(onLeft: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(onLeft ? document.leftText : document.rightText, forType: .string)
    }
}

private struct EditorInput: Identifiable {
    let id = UUID()
    let onLeft: Bool
    let text: String
}

private struct TextInputEditor: View {
    let input: EditorInput
    let onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftText: String
    @State private var validationError: String?

    init(input: EditorInput, onSave: @escaping (String) throws -> Void) {
        self.input = input
        self.onSave = onSave
        _draftText = State(initialValue: input.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(input.onLeft ? "Original" : "Changed") text").font(.title2.weight(.semibold))
            Text("Paste or type plain text. You can also compare an empty input.").foregroundStyle(.secondary)
            TextEditor(text: $draftText)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .border(.quaternary)
                .accessibilityLabel("\(input.onLeft ? "Original" : "Changed") text editor")
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Text") {
                    do {
                        try onSave(draftText)
                        dismiss()
                    } catch {
                        validationError = error.localizedDescription
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 720, height: 480)
    }

}

private struct DiffRowView: View {
    let row: DiffRow
    let paneWidth: CGFloat
    let fontSize: CGFloat
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(number: row.oldNumber, text: row.oldText, onLeft: true)
            Color.clear.frame(width: 1, height: 1)
            side(number: row.newNumber, text: row.newText, onLeft: false)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: fontSize + 12)
        .background {
            HStack(spacing: 0) {
                background(true).frame(width: paneWidth)
                Color(nsColor: .separatorColor).frame(width: 1)
                background(false).frame(width: paneWidth)
            }
        }
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
        .overlay {
            if selected { Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1) }
        }
    }

    private func side(number: Int?, text: String?, onLeft: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: max(52, fontSize * 3.9), alignment: .trailing)
                .padding(.trailing, 10)
            Text(marker(onLeft)).foregroundStyle(markerColor(onLeft)).frame(width: 18)
            Text(DiffTextFormatting.attributed(text ?? " ",
                highlights: onLeft ? row.oldHighlights : row.newHighlights,
                color: markerColor(onLeft)))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .padding(.vertical, 5)
        .padding(.trailing, 8)
        .frame(width: paneWidth, alignment: .topLeading)
    }

    private func marker(_ onLeft: Bool) -> String {
        switch row.kind {
        case .added: return onLeft ? "" : "+"
        case .removed: return onLeft ? "−" : ""
        case .modified: return onLeft ? "−" : "+"
        case .unchanged: return ""
        }
    }

    private func markerColor(_ onLeft: Bool) -> Color { onLeft ? .red : .green }

    private func background(_ onLeft: Bool) -> Color {
        switch row.kind {
        case .added: return onLeft ? .clear : .green.opacity(0.12)
        case .removed: return onLeft ? .red.opacity(0.12) : .clear
        case .modified: return onLeft ? .red.opacity(0.12) : .green.opacity(0.12)
        case .unchanged: return .clear
        }
    }
}
#endif
